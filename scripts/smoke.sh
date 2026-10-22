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
