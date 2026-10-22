#!/usr/bin/env bash
# Runs the Raft 1080p60 export acceptance check headlessly. Needs a GUI session.
#
#   scripts/acceptance.sh [path/to/Synod.app] [out-dir] [--quick] [--program name]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="${1:-build/Synod.app}"
out="${2:-acc}"
exe="$app/Contents/MacOS/Synod"
[ -x "$exe" ] || { echo "acceptance: $exe not found; run scripts/bundle.sh" >&2; exit 1; }

mkdir -p "$out"
"$exe" --acceptance "$app/Contents/Resources/examples" --out "$out" "${@:3}"
