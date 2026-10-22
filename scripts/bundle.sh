#!/usr/bin/env bash
# Builds build/Synod.app from the Swift package and the pinned dependencies.
#
#   scripts/bundle.sh [--version 0.2.0] [--config release] [--arch universal|native]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck source=../deps.env
source deps.env

version="0.2.0-dev"
config="release"
arch="universal"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:?}"; shift 2 ;;
    --config) config="${2:?}"; shift 2 ;;
    --arch) arch="${2:?}"; shift 2 ;;
    *) echo "bundle: unknown argument $1" >&2; exit 1 ;;
  esac
done

for f in .deps/synod/synod .deps/player/synod-player.iife.js .deps/examples; do
  [ -e "$f" ] || { echo "bundle: missing $f; run scripts/fetch-deps.sh" >&2; exit 1; }
done

archflags=()
if [ "$arch" = "universal" ]; then archflags=(--arch arm64 --arch x86_64); fi
if ! swift build -c "$config" ${archflags[@]+"${archflags[@]}"}; then
  if [ "$arch" = "universal" ]; then
    echo "bundle: universal build failed; falling back to arm64 only" >&2
    archflags=(--arch arm64)
    swift build -c "$config" "${archflags[@]}"
  else
    exit 1
  fi
fi
bindir="$(swift build -c "$config" ${archflags[@]+"${archflags[@]}"} --show-bin-path)"
exe="$bindir/Synod"
[ -f "$exe" ] || { echo "bundle: cannot find $exe" >&2; exit 1; }

app="build/Synod.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/player" "$app/Contents/Resources/web"

cp "$exe" "$app/Contents/MacOS/Synod"
cp .deps/synod/synod "$app/Contents/Helpers/synod"
cp .deps/player/synod-player.iife.js "$app/Contents/Resources/player/synod-player.iife.js"
for f in stage.html stage.js export.html export.js; do
  if [ -f "Web/$f" ]; then
    cp "Web/$f" "$app/Contents/Resources/web/$f"
  else
    echo "bundle: warning: Web/$f not present yet" >&2
  fi
done
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R .deps/examples "$app/Contents/Resources/examples"
rm -rf "$app/Contents/Resources/examples/.commit" "$app/Contents/Resources/examples/.github" "$app/Contents/Resources/examples/.gitignore"

cat > "$app/Contents/Resources/NOTICE-versions.txt" <<NOTICE
Synod $version
synod (compiler) $SYNOD_VERSION
player $PLAYER_VERSION
examples $EXAMPLES_VERSION ($EXAMPLES_COMMIT)
NOTICE

build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build/" Support/Info.plist.in > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign --force --deep -s - "$app"
codesign --verify --deep --strict "$app"
echo "bundle: built $app ($version, build $build)"
