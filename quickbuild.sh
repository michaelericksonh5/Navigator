#!/bin/bash
# Fast rebuild for iterating: compile + install binary + sign, reuse existing icon.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP="/Applications/Navigator.app"
"$DIR/compile.sh" "$APP/Contents/MacOS/Navigator"
# Native BG Removal's optimized helper (see rebuild.sh)
/usr/bin/swiftc -swift-version 5 -O -parse-as-library -D NATIVE_BG_TOOL -target arm64-apple-macos14.4 \
  "$DIR/NativeBGRemoval.swift" -o "$APP/Contents/MacOS/NavigatorNativeBG"
codesign --force --deep -s "Navigator Dev" "$APP" 2>/dev/null
touch "$APP"
echo "quickbuilt + signed"
