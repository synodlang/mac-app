#!/usr/bin/env bash
# Plays every bundled example headlessly ("every example plays"). Needs a GUI session.
#
#   scripts/smoke.sh [path/to/Synod.app] [report.json]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="${1:-build/Synod.app}"
report="${2:-smoke.json}"
exe="$app/Contents/MacOS/Synod"
[ -x "$exe" ] || { echo "smoke: $exe not found; run scripts/bundle.sh" >&2; exit 1; }

if ! "$exe" --help 2>&1 | grep -q -- '--smoke'; then
  echo "smoke: --smoke is not implemented in this build yet" >&2
  exit 3
fi
"$exe" --smoke "$app/Contents/Resources/examples" --report "$report"
cat "$report"

# Stage regressions: a loaded scene is drawn while paused; Predict stops at the first pause marker.
"$exe" --stage-check "$app/Contents/Resources/examples" --report "${report%.json}-stage.json"
cat "${report%.json}-stage.json"

# Editor: tokens, live diagnostics, quick fix, save with fmt, go to definition on a temporary copy.
"$exe" --editor-check "$app/Contents/Resources/examples" --report "${report%.json}-editor.json"
cat "${report%.json}-editor.json"

# Learning modes (M9): Predict choices, stage hit tests and clicks, Break it by clicks, Compare, GIF export.
ex="$app/Contents/Resources/examples"
"$exe" --predict-check "$ex" --report "${report%.json}-predict.json"
"$exe" --hit-check "$ex" --report "${report%.json}-hit.json"
"$exe" --breakit-check "$ex" --script Tests/Acceptance/cassandra-handoff.json --report "${report%.json}-breakit.json"
"$exe" --compare-check "$ex" raft --seeds 3,4 --report "${report%.json}-compare.json"
gifdir="$(mktemp -d)"
"$exe" --export "$ex" tcp --out "$gifdir/tcp.gif" --width 640 --fps 20 --rate 1
"$exe" --gif-check "$gifdir/tcp.gif" --module "$ex" --program tcp --samples 10 --report "${report%.json}-gif.json"
rm -rf "$gifdir"
