#!/usr/bin/env bash
# Makes <looks dir>/vendor hold the modules looks requires, so its demos run offline (decision 71, 76).
# Keeps an existing vendor/; otherwise copies <examples dir> to vendor/<module>@<version> for each
# `require <module> <version>` of synod.mod that is the examples module.
#   scripts/vendor-looks.sh <looks dir> <examples dir>
set -euo pipefail
looks="${1:?looks dir}"; examples="${2:?examples dir}"
[ -d "$looks/vendor" ] && { echo "vendor-looks: keeping $looks/vendor"; exit 0; }
req="$(awk '$1=="require" && $2=="github.com/synodlang/examples" {print $3}' "$looks/synod.mod")"
[ -n "$req" ] || { echo "vendor-looks: looks requires no examples; nothing to vendor"; exit 0; }
dest="$looks/vendor/github.com/synodlang/examples@$req"
mkdir -p "$dest"
(cd "$examples" && tar --exclude=.git --exclude=.commit -cf - .) | (cd "$dest" && tar -xf -)
echo "vendor-looks: filled $dest"
