#!/bin/bash
# The two Navigator .jsx scripts each carry a copy of the shared open/cleanup core. They cannot
# #include a common file: "Layerize Selection (AI).jsx" is handed to other people on its own, and an
# include would arrive broken. So the copies are marked and compared here instead.
#
# This exists because the duplication already caused a real bug: the orphaned-document fix was
# applied to one script and missed in the other, leaving the very failure it fixed in the copy being
# distributed.
set -euo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
A="$DIR/NavigatorAssembleLayers.jsx"
B="$DIR/NavigatorLayerizeSelection.jsx"
extract() { awk '/===== SHARED WITH/{f=1;next} /===== END SHARED/{f=0} f' "$1"; }
if ! diff <(extract "$A") <(extract "$B") > /tmp/nav-shared-drift.txt; then
  echo "ERROR: the shared JSX core has drifted between the two scripts:"
  sed 's/^/    /' /tmp/nav-shared-drift.txt
  echo "    -> make the marked block identical in both files."
  exit 1
fi
LINES=$(extract "$A" | grep -c . || true)
[ "$LINES" -gt 5 ] || { echo "ERROR: shared JSX block missing or empty (found $LINES lines)"; exit 1; }
echo "shared jsx core: identical in both scripts ($LINES lines)"
