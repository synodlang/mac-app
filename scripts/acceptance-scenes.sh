#!/usr/bin/env bash
# Export acceptance (PSNR of decoded video frames against the stage player) for handmade Synod 0.3 scenes of
# the player repository: vignette, shadow, glow, sketch, effects, camera, drift, trail, icons, counters, fonts.
#
#   scripts/acceptance-scenes.sh [path/to/Synod.app] [out-dir] [scene.json ...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="${1:-build/Synod.app}"
out="${2:-acc-scenes}"
exe="$app/Contents/MacOS/Synod"
[ -x "$exe" ] || { echo "acceptance-scenes: $exe not found; run scripts/bundle.sh" >&2; exit 1; }
dir="${SYNOD_PLAYER_SCENES:-$root/../player/test/scenes/handmade}"
if [ $# -gt 2 ]; then
  scenes=("${@:3}")
else
  scenes=()
  for n in style-vignette style-shadow style-glow style-sketch style-sketch-half style-type style-drift effect-flash effect-group \
           effect-circumscribe camera-zoom trail icon-morph counter role-face group-draw-halo; do
    scenes+=("$dir/$n.json")
  done
fi
mkdir -p "$out"
"$exe" --scene-acceptance "${scenes[@]}" --out "$out" --quick
