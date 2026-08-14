#!/bin/bash
# Install the layer-assembly script into Photoshop's own Scripts folder, for every installed version.
#
# Photoshop populates File > Scripts from Presets/Scripts INSIDE the application bundle, which is
# owned by root — hence sudo.
#
# THIS IS THE ONLY THING THAT PUTS THE SCRIPTS IN PHOTOSHOP'S MENU. Installing Navigator does not:
# rebuild.sh copies a different set of .jsx files into Navigator.app/Contents/Resources, which
# Navigator hands to Photoshop by path for its own right-click actions, and they never appear in the
# menu. A previous version of this comment claimed the build also seeded a per-user
# ~/Library/Application Support/Adobe/<version>/Presets/Scripts — it does not, and that folder does
# not exist. So after every change to either script, run this again.
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
