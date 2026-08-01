#!/bin/bash
# Rebuilds Navigator.app from main.swift in this folder and installs to /Applications.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP="/Applications/Navigator.app"
echo "Compiling (universal: arm64 + x86_64)..."
SWIFT_ARGS=(-swift-version 5 "$DIR/main.swift" "$DIR/NavigatorCore.swift" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -framework NetFS -framework Security -framework FinderSync)
/usr/bin/swiftc "${SWIFT_ARGS[@]}" -target arm64-apple-macos14.4  -o "$DIR/Navigator-arm64"
/usr/bin/swiftc "${SWIFT_ARGS[@]}" -target x86_64-apple-macos14.4 -o "$DIR/Navigator-x86_64"
lipo -create "$DIR/Navigator-arm64" "$DIR/Navigator-x86_64" -output "$DIR/Navigator.bin"
rm -f "$DIR/Navigator-arm64" "$DIR/Navigator-x86_64"

# (Re)generate the icon: prefer AppIcon.png (sips), then the SVG, then the Swift generator
if [ -f "$DIR/AppIcon.png" ]; then
  rm -rf "$DIR/Navigator.iconset"; mkdir "$DIR/Navigator.iconset"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
              "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$DIR/AppIcon.png" --out "$DIR/Navigator.iconset/icon_$2.png" >/dev/null 2>&1
  done
  iconutil -c icns -o "$DIR/Navigator.icns" "$DIR/Navigator.iconset"
elif command -v rsvg-convert >/dev/null 2>&1 && [ -f "$DIR/Navigator.svg" ]; then
  rm -rf "$DIR/Navigator.iconset"; mkdir "$DIR/Navigator.iconset"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
              "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    rsvg-convert -w "$1" -h "$1" "$DIR/Navigator.svg" -o "$DIR/Navigator.iconset/icon_$2.png"
  done
  iconutil -c icns -o "$DIR/Navigator.icns" "$DIR/Navigator.iconset"
elif [ -f "$DIR/makeicon.swift" ]; then
  /usr/bin/swiftc -o "$DIR/makeicon" "$DIR/makeicon.swift" -framework AppKit
  rm -rf "$DIR/Navigator.iconset"
  "$DIR/makeicon" "$DIR/Navigator.iconset"
  iconutil -c icns -o "$DIR/Navigator.icns" "$DIR/Navigator.iconset"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Navigator.bin" "$APP/Contents/MacOS/Navigator"
[ -f "$DIR/Navigator.icns" ] && cp "$DIR/Navigator.icns" "$APP/Contents/Resources/Navigator.icns"
# Bundle the Photoshop Remove-BG scripts so they ship inside the app — no one
# needs a copy saved anywhere; Navigator points Photoshop at these.
for jsx in NavigatorRemoveBG NavigatorChromaKeyStill NavigatorExportPNG; do
  [ -f "$DIR/$jsx.jsx" ] && cp "$DIR/$jsx.jsx" "$APP/Contents/Resources/$jsx.jsx"
done
# Menu icons for services with no installed app to borrow an icon from (Vertex AI,
# fal). Photoshop/After Effects icons are read from the installed apps instead, so
# they are never copied here. Drop a 64x64 PNG in Assets/ and it ships; a missing
# one falls back to an SF Symbol in code.
if [ -d "$DIR/Assets" ]; then
  for png in "$DIR/Assets"/*.png; do
    [ -f "$png" ] && cp "$png" "$APP/Contents/Resources/$(basename "$png")"
  done
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Navigator</string>
<key>CFBundleDisplayName</key><string>Navigator</string>
<key>CFBundleIdentifier</key><string>com.merickson.navigator</string>
<key>CFBundleExecutable</key><string>Navigator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.00</string>
<key>CFBundleVersion</key><string>124</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Navigator</string>
<key>NSHumanReadableCopyright</key><string>Michael Erickson</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Navigator discovers file servers on your local network so they appear in the sidebar.</string>
<key>NSBonjourServices</key><array><string>_smb._tcp</string></array>
<key>NSDesktopFolderUsageDescription</key><string>Navigator shows and manages the files in your Desktop folder.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Navigator shows and manages the files in your Documents folder.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Navigator shows and manages the files in your Downloads folder.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Navigator shows and manages files on USB and external drives you connect.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Navigator shows and manages files on network drives you connect to.</string>
<key>NSFileProviderPresenceUsageDescription</key><string>Navigator shows files stored in cloud providers like iCloud Drive and Google Drive.</string>
<key>NSAppleEventsUsageDescription</key><string>Navigator asks Adobe Photoshop and After Effects to remove image backgrounds for you.</string>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict>
  <dict>
    <key>CFBundleTypeName</key><string>Image</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.image</string></array>
  </dict>
</array>
<key>NSServices</key>
<array>
  <dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Open in Navigator</string></dict>
    <key>NSMessage</key><string>openInNavigator</string>
    <key>NSPortName</key><string>Navigator</string>
    <key>NSSendFileTypes</key><array><string>public.item</string></array>
  </dict>
</array>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key><string>Navigator Action</string>
    <key>CFBundleURLSchemes</key><array><string>navigatoraction</string></array>
  </dict>
</array>
</dict></plist>
PLIST
# ── Finder Sync extension ────────────────────────────────────────────────────
# Puts Navigator's own submenu in Finder's MAIN right-click menu. Built here as a
# plain .appex rather than via an Xcode project, so the single-file workflow
# stays intact. App extensions enter at _NSExtensionMain, not main().
if [ -f "$DIR/FinderExt.swift" ]; then
  EXT="$APP/Contents/PlugIns/NavigatorFinder.appex"
  mkdir -p "$EXT/Contents/MacOS"
  for arch in arm64 x86_64; do
    /usr/bin/swiftc -swift-version 5 "$DIR/FinderExt.swift" \
      -target ${arch}-apple-macos14.0 \
      -framework FinderSync -framework Cocoa \
      -Xlinker -e -Xlinker _NSExtensionMain \
      -o "$DIR/ext-$arch" || { echo "Finder extension failed to build"; exit 1; }
  done
  lipo -create "$DIR/ext-arm64" "$DIR/ext-x86_64" -output "$EXT/Contents/MacOS/NavigatorFinder"
  rm -f "$DIR/ext-arm64" "$DIR/ext-x86_64"
  # The extension's Bundle.main is the appex, not the app, so it needs its own copy
  # of the menu icons.
  if [ -d "$DIR/Assets" ]; then
    mkdir -p "$EXT/Contents/Resources"
    for png in "$DIR/Assets"/*.png; do
      [ -f "$png" ] && cp "$png" "$EXT/Contents/Resources/$(basename "$png")"
    done
  fi
  cat > "$EXT/Contents/Info.plist" <<'EXTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NavigatorFinder</string>
<key>CFBundleDisplayName</key><string>Navigator</string>
<key>CFBundleIdentifier</key><string>com.merickson.navigator.findersync</string>
<key>CFBundleExecutable</key><string>NavigatorFinder</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
  <key>NSExtensionPrincipalClass</key><string>NavigatorFinderSync</string>
</dict>
</dict></plist>
EXTPLIST
  # macOS REQUIRES Finder Sync plug-ins to be sandboxed — pkd rejects them outright
  # otherwise ("plug-ins must be sandboxed"). The host app stays unsandboxed; only
  # this bundle gets the entitlement. It needs no file access of its own: Finder
  # hands it the selected URLs and it passes the paths to Navigator over the
  # navigatoraction:// scheme, so the sandbox costs us nothing.
  cat > "$DIR/ext.entitlements" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict></plist>
ENTS
  echo "Built Finder Sync extension."
fi

# Sign with the stable "Navigator Dev" self-signed identity if it exists, so the
# app's designated requirement stays constant across rebuilds and macOS keeps
# your Full Disk Access / Local Network grants. Falls back to ad-hoc if absent.
SIGN_ID="Navigator Dev"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  # Sign the extension FIRST, then the app: a nested bundle must already be
  # sealed when the outer signature is computed, or the app's seal is invalid.
  [ -d "$APP/Contents/PlugIns/NavigatorFinder.appex" ] && \
    codesign --force -s "$SIGN_ID" --entitlements "$DIR/ext.entitlements" \
      "$APP/Contents/PlugIns/NavigatorFinder.appex"
  codesign --force -s "$SIGN_ID" "$APP"   # no --deep: it would re-sign the appex and strip its entitlements
  echo "Signed with '$SIGN_ID' (stable identity)."
else
  [ -d "$APP/Contents/PlugIns/NavigatorFinder.appex" ] && \
    codesign --force -s - --entitlements "$DIR/ext.entitlements" \
      "$APP/Contents/PlugIns/NavigatorFinder.appex"
  codesign --force -s - "$APP"   # no --deep (see above)
  echo "Signed ad-hoc (no '$SIGN_ID' identity found)."
fi
touch "$APP"
echo "Installed $APP"
