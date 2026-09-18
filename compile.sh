#!/bin/bash
# THE compiler invocation for the app. Every build path goes through here.
#
# It exists because the argument list used to be copied into three places, and CI's copy
# went stale: it still compiled main.swift ALONE after NavigatorCore.swift was split out,
# so every push failed with "cannot find 'PathRules' in scope" while the local builds were
# green. That went unnoticed across several releases. One copy cannot drift from itself.
#
# TARGET is overridable so rebuild.sh can produce both slices of the universal binary.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OUT="${1:?usage: compile.sh <output-binary>}"
TARGET="${TARGET:-arm64-apple-macos14.4}"
/usr/bin/swiftc -swift-version 5 -target "$TARGET" -o "$OUT" \
  "$DIR/main.swift" "$DIR/NavigatorCore.swift" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  -framework NetFS -framework Security -framework FinderSync
