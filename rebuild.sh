#!/bin/bash
# Rebuilds Navigator.app from main.swift in this folder and installs to /Applications.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP="/Applications/Navigator.app"
echo "Compiling (universal: arm64 + x86_64)..."
SWIFT_ARGS=(-swift-version 5 "$DIR/main.swift" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -framework NetFS -framework Security)
/usr/bin/swiftc "${SWIFT_ARGS[@]}" -target arm64-apple-macos14.0  -o "$DIR/Navigator-arm64"
/usr/bin/swiftc "${SWIFT_ARGS[@]}" -target x86_64-apple-macos14.0 -o "$DIR/Navigator-x86_64"
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
for jsx in NavigatorRemoveBG NavigatorBatchRemoveBG NavigatorChromaKeyStill NavigatorChromaKeyFolder; do
  [ -f "$DIR/$jsx.jsx" ] && cp "$DIR/$jsx.jsx" "$APP/Contents/Resources/$jsx.jsx"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Navigator</string>
<key>CFBundleDisplayName</key><string>Navigator</string>
<key>CFBundleIdentifier</key><string>com.merickson.navigator</string>
<key>CFBundleExecutable</key><string>Navigator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4.70</string>
<key>CFBundleVersion</key><string>86</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
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
# Sign with the stable "Navigator Dev" self-signed identity if it exists, so the
# app's designated requirement stays constant across rebuilds and macOS keeps
# your Full Disk Access / Local Network grants. Falls back to ad-hoc if absent.
SIGN_ID="Navigator Dev"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --deep -s "$SIGN_ID" "$APP"
  echo "Signed with '$SIGN_ID' (stable identity)."
else
  codesign --force --deep -s - "$APP"
  echo "Signed ad-hoc (no '$SIGN_ID' identity found)."
fi
touch "$APP"
echo "Installed $APP"
