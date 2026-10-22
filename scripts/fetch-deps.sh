#!/usr/bin/env bash
# Downloads and verifies the pinned dependencies from deps.env into .deps/.
# Idempotent: a second run verifies again and re-extracts nothing that is current.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck source=../deps.env
source deps.env

deps=".deps"
base="https://github.com/synodlang"

die() { echo "fetch-deps: $*" >&2; exit 1; }

# scripts/local-deps.sh marks .deps/.local; never silently replace local builds with the pins.
force=0
case "${1:-}" in
  "") ;;
  --force) force=1 ;;
  *) die "usage: fetch-deps.sh [--force]" ;;
esac
if [ -f "$deps/.local" ]; then
  [ "$force" = 1 ] || die ".deps holds local builds (.deps/.local); run with --force to replace them with the pinned releases"
  rm -rf "$deps/synod" "$deps/player" "$deps/examples" "$deps/agent-skills" "$deps/.local"
  echo "fetch-deps: removed local builds"
fi
mkdir -p "$deps"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# download <repo> <tag> <asset> <pinned sha> -> verifies into $deps/dl/<asset>
download() {
  local repo="$1" tag="$2" asset="$3" pin="$4"
  local dir="$deps/dl/$repo-$tag"
  mkdir -p "$dir"
  local url="$base/$repo/releases/download/$tag"
  if [ ! -f "$dir/$asset" ] || [ "$(sha "$dir/$asset")" != "$pin" ]; then
    echo "fetch-deps: downloading $repo $tag $asset"
    curl -fsSL -o "$dir/$asset" "$url/$asset" || die "download failed: $url/$asset"
  fi
  curl -fsSL -o "$dir/SHA256SUMS" "$url/SHA256SUMS" || die "download failed: $url/SHA256SUMS"
  (cd "$dir" && grep -F " $asset" SHA256SUMS | shasum -a 256 -c -) \
    || die "$asset does not match the release SHA256SUMS"
  local got
  got="$(sha "$dir/$asset")"
  [ "$got" = "$pin" ] || die "$asset hash $got does not match the pin in deps.env ($pin)"
  echo "fetch-deps: verified $asset"
}

# compiler
archive="synod-$SYNOD_VERSION-darwin-universal.tar.gz"
download compiler "$SYNOD_VERSION" "$archive" "$SYNOD_ARCHIVE_SHA256"
tmp="$deps/synod.tmp"
rm -rf "$tmp"
mkdir -p "$tmp"
tar -xzf "$deps/dl/compiler-$SYNOD_VERSION/$archive" -C "$tmp"
[ -f "$tmp/synod" ] || die "archive has no synod binary"
chmod +x "$tmp/synod"
archs="$(lipo -info "$tmp/synod")"
case "$archs" in *x86_64*) ;; *) die "synod is not universal: $archs" ;; esac
case "$archs" in *arm64*) ;; *) die "synod is not universal: $archs" ;; esac
"$tmp/synod" version | grep -q '^language 0\.2' || die "synod version does not report language 0.2"
mkdir -p "$deps/synod"
cp "$tmp/synod" "$deps/synod/synod"
for f in LICENSE README.md; do [ -f "$tmp/$f" ] && cp "$tmp/$f" "$deps/synod/$f"; done
rm -rf "$tmp"
echo "fetch-deps: synod $SYNOD_VERSION ($archs)"

# player
iife="synod-player-$PLAYER_VERSION.iife.js"
download player "$PLAYER_VERSION" "$iife" "$PLAYER_IIFE_SHA256"
mkdir -p "$deps/player"
cp "$deps/dl/player-$PLAYER_VERSION/$iife" "$deps/player/synod-player.iife.js"

# examples
if [ -d "$deps/examples" ] && [ -f "$deps/examples/.commit" ] \
  && [ "$(cat "$deps/examples/.commit")" = "$EXAMPLES_COMMIT" ]; then
  echo "fetch-deps: examples $EXAMPLES_COMMIT (cached)"
else
  work="$deps/examples.git"
  rm -rf "$work" "$deps/examples"
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" fetch -q --depth 1 "$base/examples.git" "$EXAMPLES_COMMIT" \
    || die "cannot fetch examples $EXAMPLES_COMMIT"
  git -C "$work" checkout -q FETCH_HEAD
  head="$(git -C "$work" rev-parse HEAD)"
  [ "$head" = "$EXAMPLES_COMMIT" ] || die "examples HEAD $head does not match the pin $EXAMPLES_COMMIT"
  mkdir -p "$deps/examples"
  (cd "$work" && tar --exclude=.git -cf - .) | (cd "$deps/examples" && tar -xf -)
  echo "$EXAMPLES_COMMIT" > "$deps/examples/.commit"
  rm -rf "$work"
  echo "fetch-deps: examples $EXAMPLES_COMMIT"
fi
# agent-skills
skills_archive="agent-skills-$AGENT_SKILLS_VERSION.tar.gz"
download agent-skills "$AGENT_SKILLS_VERSION" "$skills_archive" "$AGENT_SKILLS_SHA256"
if [ -f "$deps/agent-skills/.version" ] && [ "$(cat "$deps/agent-skills/.version")" = "$AGENT_SKILLS_VERSION $AGENT_SKILLS_SHA256" ] \
  && [ -f "$deps/agent-skills/skills/synod/SKILL.md" ]; then
  echo "fetch-deps: agent-skills $AGENT_SKILLS_VERSION (cached)"
else
  tmp="$deps/agent-skills.tmp"
  rm -rf "$tmp" "$deps/agent-skills"
  mkdir -p "$tmp"
  tar -xzf "$deps/dl/agent-skills-$AGENT_SKILLS_VERSION/$skills_archive" -C "$tmp" --strip-components 1
  [ -f "$tmp/skills/synod/SKILL.md" ] || die "agent-skills archive has no skills/synod/SKILL.md"
  echo "$AGENT_SKILLS_VERSION $AGENT_SKILLS_SHA256" > "$tmp/.version"
  mv "$tmp" "$deps/agent-skills"
  echo "fetch-deps: agent-skills $AGENT_SKILLS_VERSION"
fi
echo "fetch-deps: ok"
