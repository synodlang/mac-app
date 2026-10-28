#!/usr/bin/env bash
# Builds the sibling checkouts into .deps/ for local development, before their releases exist:
#   ../compiler  -> .deps/synod/synod            (go build ./cmd/synod, the host architecture)
#   ../player    -> .deps/player/synod-player.iife.js  (esbuild into .deps; player/dist is not touched)
#   ../player/dist/synod-player-fonts.tar.gz -> .deps/fonts  (the four fonts; `npm run build` in ../player makes it)
#   ../looks     -> .deps/looks                   (a copy without .git; vendor/ kept, else filled from ../examples)
#   ../examples  -> .deps/examples               (a copy without .git)
#   ../agent-skills -> .deps/agent-skills         (a copy without .git, when the checkout exists)
# and writes .deps/.local. fetch-deps.sh refuses to run over that marker unless given --force.
#   scripts/local-deps.sh [--compiler <dir>] [--player <dir>] [--examples <dir>] [--looks <dir>] [--agent-skills <dir>] [--skip-player]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="$root/../compiler"
player="$root/../player"
examples="$root/../examples"
looks="$root/../looks"
skills="$root/../agent-skills"
skip_player=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compiler) compiler="$2"; shift 2 ;;
    --player) player="$2"; shift 2 ;;
    --examples) examples="$2"; shift 2 ;;
    --looks) looks="$2"; shift 2 ;;
    --agent-skills) skills="$2"; shift 2 ;;
    --skip-player) skip_player=1; shift ;;
    *) echo "usage: local-deps.sh [--compiler <dir>] [--player <dir>] [--examples <dir>] [--looks <dir>] [--agent-skills <dir>] [--skip-player]" >&2; exit 2 ;;
  esac
done

die() { echo "local-deps: $*" >&2; exit 1; }
[[ -d "$compiler/cmd/synod" ]] || die "no compiler at $compiler"
[[ -d "$examples" ]] || die "no examples at $examples"

deps="$root/.deps"
mkdir -p "$deps/synod" "$deps/player"

# compiler
rm -f "$deps/synod/synod"
(cd "$compiler" && go build -o "$deps/synod/synod" ./cmd/synod)
"$deps/synod/synod" version | head -2 | sed 's/^/local-deps: /'

# player: bundle the IIFE straight into .deps so the player checkout (and its dist/) stays untouched.
if [[ $skip_player -eq 0 ]]; then
  [[ -d "$player/node_modules/.bin" ]] || die "no node_modules in $player; run npm ci there (or pass --skip-player)"
  version="$(node -p "require('$player/package.json').version")-local"
  (cd "$player" && ./node_modules/.bin/esbuild src/iife.ts --bundle --minify --target=es2022 --format=iife --global-name=SynodPlayer \
    --legal-comments=none --log-level=warning --define:__VERSION__="\"$version\"" \
    --outfile="$deps/player/synod-player.iife.js")
  echo "local-deps: player $version"
fi

# examples
rm -rf "$deps/examples"
mkdir -p "$deps/examples"
(cd "$examples" && tar --exclude=.git -cf - .) | (cd "$deps/examples" && tar -xf -)
echo "local-deps: examples copied from $examples"

# fonts: the player's release asset, unpacked
fonts_tar="$player/dist/synod-player-fonts.tar.gz"
if [[ $skip_player -eq 0 ]]; then
  [[ -f "$fonts_tar" ]] || die "no $fonts_tar; run npm run build in $player"
  rm -rf "$deps/fonts" "$deps/fonts.tmp"
  mkdir -p "$deps/fonts.tmp"
  tar -xzf "$fonts_tar" -C "$deps/fonts.tmp"
  mv "$deps/fonts.tmp/fonts" "$deps/fonts"
  rm -rf "$deps/fonts.tmp"
  echo "local-deps: fonts unpacked from $fonts_tar"
fi

# looks
if [[ -f "$looks/synod.mod" ]]; then
  rm -rf "$deps/looks"
  mkdir -p "$deps/looks"
  (cd "$looks" && tar --exclude=.git --exclude=out -cf - .) | (cd "$deps/looks" && tar -xf -)
  "$root/scripts/vendor-looks.sh" "$deps/looks" "$deps/examples"
  echo "local-deps: looks copied from $looks"
else
  echo "local-deps: no looks at $looks; skipped" >&2
fi

# agent-skills
if [[ -f "$skills/skills/synod/SKILL.md" ]]; then
  rm -rf "$deps/agent-skills"
  mkdir -p "$deps/agent-skills"
  (cd "$skills" && tar --exclude=.git -cf - .) | (cd "$deps/agent-skills" && tar -xf -)
  echo "local-deps: agent-skills copied from $skills"
else
  echo "local-deps: no agent-skills at $skills; skipped" >&2
fi

echo "compiler $(git -C "$compiler" rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$deps/.local"
echo "local-deps: ok (.deps/.local written; scripts/fetch-deps.sh --force restores the pinned releases)"
