#!/usr/bin/env bash
# Copies the compiler fixtures used by SynodCoreTests into Tests/SynodCoreTests/Fixtures/synced.
#   scripts/sync-fixtures.sh [--check] [--compiler <dir>]
# --check copies nothing and exits 1 when the committed fixtures differ from the compiler's.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="$root/../compiler"
check=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=1; shift ;;
    --compiler)
      [[ $# -ge 2 ]] || { echo "sync-fixtures: --compiler needs a directory" >&2; exit 2; }
      compiler="$2"; shift 2 ;;
    *) echo "usage: sync-fixtures.sh [--check] [--compiler <dir>]" >&2; exit 2 ;;
  esac
done

src="$compiler/testdata"
[[ -d "$src" ]] || { echo "sync-fixtures: no $src (use --compiler <dir>)" >&2; exit 2; }
dest="$root/Tests/SynodCoreTests/Fixtures/synced"

# Source (relative to testdata) -> destination (relative to Fixtures/synced).
files=(
  "run/examples/raft/trace.jsonl:examples/raft/trace.jsonl"
  "run/examples/raft/scene.json:examples/raft/scene.json"
  "run/examples/raft/summary.txt:examples/raft/summary.txt"
  "run/examples/tcp/trace.jsonl:examples/tcp/trace.jsonl"
  "run/examples/tcp/scene.json:examples/tcp/scene.json"
  "run/examples/tcp/summary.txt:examples/tcp/summary.txt"
  "run/examples/twopc/trace.jsonl:examples/twopc/trace.jsonl"
  "run/examples/twopc/scene.json:examples/twopc/scene.json"
  "run/examples/twopc/summary.txt:examples/twopc/summary.txt"
  "check/type-mismatch/nodes/expect.json:check/type-mismatch-nodes.json"
  "check/type-mismatch/operators/expect.json:check/type-mismatch-operators.json"
  "check/unknown-phrase/misspelled-head/expect.json:check/unknown-phrase-misspelled-head.json"
  "check/bad-header/missing/expect.json:check/bad-header-missing.json"
  "check/indent/tab/expect.json:check/indent-tab.json"
  "check/non-canonical/names/expect.json:check/non-canonical-names.json"
  "run/errors/time-limit/late-after/expect.txt:errors/time-limit/expect.txt"
  "run/errors/time-limit/late-after/trace.jsonl:errors/time-limit/trace.jsonl"
)

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
for pair in "${files[@]}"; do
  from="${pair%%:*}"
  to="${pair#*:}"
  [[ -f "$src/$from" ]] || { echo "sync-fixtures: missing $src/$from" >&2; exit 2; }
  mkdir -p "$stage/$(dirname "$to")"
  cp "$src/$from" "$stage/$to"
done

if [[ $check -eq 1 ]]; then
  if diff -r "$stage" "$dest" >/dev/null 2>&1; then
    echo "fixtures match $compiler"
    exit 0
  fi
  diff -r "$stage" "$dest" | head -20 || true
  echo "sync-fixtures: fixtures drifted from the compiler; run scripts/sync-fixtures.sh" >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
cp -R "$stage/." "$dest/"
echo "synced ${#files[@]} fixtures from $compiler"
