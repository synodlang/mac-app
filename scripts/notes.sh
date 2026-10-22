#!/usr/bin/env bash
# Prints the CHANGELOG.md section of a release, for use as GitHub release notes.
# Port of player/scripts/notes.ts.
#
#   scripts/notes.sh --tag v0.2.0 [--changelog CHANGELOG.md]
set -euo pipefail

tag=""
changelog="CHANGELOG.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag="${2:-}"; shift 2 ;;
    --changelog) changelog="${2:-}"; shift 2 ;;
    *) echo "notes: unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -n "$tag" ] || { echo "notes: need --tag" >&2; exit 1; }
[ -f "$changelog" ] || { echo "notes: cannot read $changelog" >&2; exit 1; }

found="$(tr -d '\r' < "$changelog" | awk -v tag="$tag" '
  function trimr(s) { sub(/[ \t]+$/, "", s); return s }
  BEGIN { prefix = "## " tag; state = 0; n = 0 }
  {
    if (state == 0) {
      t = trimr($0)
      if (substr(t, 1, length(prefix)) == prefix) {
        rest = substr(t, length(prefix) + 1)
        if (rest == "" || substr(rest, 1, 1) == " " || substr(rest, 1, 1) == "\t") { state = 1; print "FOUND" }
      }
      next
    }
    if (substr($0, 1, 3) == "## ") { exit }
    print
  }')"

case "$found" in
  FOUND*) ;;
  *) echo "notes: no section \"## $tag\" in changelog" >&2; exit 1 ;;
esac

body="$(printf '%s\n' "$found" | tail -n +2 | awk '
  { lines[NR] = $0 }
  END {
    s = 1; e = NR
    while (s <= e && lines[s] ~ /^[ \t]*$/) s++
    while (e >= s && lines[e] ~ /^[ \t]*$/) e--
    for (i = s; i <= e; i++) print lines[i]
  }')"
if [ -z "$body" ]; then
  echo "notes: section \"## $tag\" in changelog is empty" >&2
  exit 1
fi
printf '%s\n' "$body"
