#!/bin/bash
# Install the layer-assembly script into Photoshop's own Scripts folder, for every installed version.
#
# Photoshop populates File > Scripts from Presets/Scripts INSIDE the application bundle, which is
# owned by root — hence sudo. Copies are also placed in the per-user
# ~/Library/Application Support/Adobe/<version>/Presets/Scripts by Navigator's build, but whether
# Photoshop scans that location for the Scripts menu was never confirmed, so this is the reliable one.
#
# Usage:  ./install-photoshop-script.sh
# Then quit and reopen Photoshop — the menu is built at launch.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# script source -> menu name
SCRIPTS=(
  "$HERE/NavigatorAssembleLayers.jsx|Assemble Layerize Folder.jsx"
  "$HERE/NavigatorLayerizeSelection.jsx|Layerize Selection (AI).jsx"
)
for entry in "${SCRIPTS[@]}"; do
  [ -f "${entry%%|*}" ] || { echo "missing ${entry%%|*}"; exit 1; }
done

found=0
for app in /Applications/Adobe\ Photoshop*; do
  dir="$app/Presets/Scripts"
  [ -d "$dir" ] || continue
  found=1
  echo "installing into: $dir"
  for entry in "${SCRIPTS[@]}"; do
    src="${entry%%|*}"; nm="${entry##*|}"
    sudo cp "$src" "$dir/$nm"
    sudo chmod 644 "$dir/$nm"
    echo "   $nm"
  done
done

[ "$found" = 1 ] || { echo "no Photoshop installations found under /Applications"; exit 1; }

echo
echo "Done. Quit and reopen Photoshop, then use:"
echo "   File > Scripts > Layerize Selection (AI)     — split a selection into layers, in place"
echo "   File > Scripts > Assemble Layerize Folder     — rebuild a _Layers folder into a PSD"
