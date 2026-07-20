#!/bin/bash
# Fast rebuild for iterating: compile + install binary + sign, reuse existing icon.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP="/Applications/Navigator.app"
/usr/bin/swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Navigator" "$DIR/main.swift" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers
codesign --force --deep -s "Navigator Dev" "$APP" 2>/dev/null
touch "$APP"
echo "quickbuilt + signed"
