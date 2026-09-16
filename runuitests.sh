#!/bin/bash
# UI smoke tests. Needs /Applications/Navigator.app installed (run ./quickbuild.sh first) and
# Accessibility permission for whatever runs this.
set -e
DIR="$( cd "$( dirname "$0" )" && pwd )"
OUT="$(mktemp -d)/uismoke"
/usr/bin/swiftc -swift-version 5 -target arm64-apple-macos14.4 -O \
  -o "$OUT" "$DIR/UITests/UISmoke.swift" \
  -framework AppKit -framework ApplicationServices
"$OUT"
