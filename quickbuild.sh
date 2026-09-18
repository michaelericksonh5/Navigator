#!/bin/bash
# Fast rebuild for iterating: compile + install binary + sign, reuse existing icon.
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP="/Applications/Navigator.app"
"$DIR/compile.sh" "$APP/Contents/MacOS/Navigator"
codesign --force --deep -s "Navigator Dev" "$APP" 2>/dev/null
touch "$APP"
echo "quickbuilt + signed"
