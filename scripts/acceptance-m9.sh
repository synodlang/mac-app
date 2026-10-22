#!/usr/bin/env bash
# Runs the whole M9 acceptance headlessly on the bundled examples: editor, Predict choices, hit tests,
# Break it (Cassandra hinted handoff), Compare, GIF export, then the M8 smoke test and Raft video.
# Writes <out>/report-m9.json, <out>/tcp.gif and <out>/m8/*.mp4. Needs a GUI session.
#
#   scripts/acceptance-m9.sh [path/to/Synod.app] [out-dir] [--quick]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="${1:-build/Synod.app}"
out="${2:-acc-m9}"
exe="$app/Contents/MacOS/Synod"
[ -x "$exe" ] || { echo "acceptance-m9: $exe not found; run scripts/bundle.sh" >&2; exit 1; }

mkdir -p "$out"
status=0
"$exe" --m9 "$app/Contents/Resources/examples" --out "$out" "${@:3}" || status=$?
[ -f "$out/report-m9.json" ] && cat "$out/report-m9.json"
exit "$status"
