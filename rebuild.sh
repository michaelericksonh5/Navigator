#!/bin/bash
# Rebuilds Navigator.app from main.swift in this folder and installs to /Applications.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP="/Applications/Navigator.app"
echo "Compiling..."
/usr/bin/swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -o "$DIR/Navigator.bin" "$DIR/main.swift" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers

# (Re)generate the icon if the generator is present
if [ -f "$DIR/makeicon.swift" ]; then
  /usr/bin/swiftc -o "$DIR/makeicon" "$DIR/makeicon.swift" -framework AppKit
  rm -rf "$DIR/Navigator.iconset"
  "$DIR/makeicon" "$DIR/Navigator.iconset"
  iconutil -c icns -o "$DIR/Navigator.icns" "$DIR/Navigator.iconset"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Navigator.bin" "$APP/Contents/MacOS/Navigator"
[ -f "$DIR/Navigator.icns" ] && cp "$DIR/Navigator.icns" "$APP/Contents/Resources/Navigator.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Navigator</string>
<key>CFBundleDisplayName</key><string>Navigator</string>
<key>CFBundleIdentifier</key><string>com.merickson.navigator</string>
<key>CFBundleExecutable</key><string>Navigator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Navigator</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
touch "$APP"
echo "Installed $APP"
