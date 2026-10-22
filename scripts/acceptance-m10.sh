#!/usr/bin/env bash
# The M10 headless acceptance on the bundled app: phrase completion, the prompt bar against a fake
# `claude`, the editor MCP server and bridge, then the M9 acceptance. No network, no Claude Code login.
# Writes <out>/report-m10.json. Needs a GUI session (a locked screen is fine for everything but M9's video).
#
#   scripts/acceptance-m10.sh [path/to/Synod.app] [out-dir] [--quick]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="${1:-build/Synod.app}"
out="${2:-acc-m10}"
exe="$app/Contents/MacOS/Synod"
[ -x "$exe" ] || { echo "acceptance-m10: $exe not found; run scripts/bundle.sh" >&2; exit 1; }
[ -x "$app/Contents/Helpers/synod-editor-mcp" ] || { echo "acceptance-m10: the bundle has no Contents/Helpers/synod-editor-mcp" >&2; exit 1; }
[ -f "$app/Contents/Resources/agent-skills/skills/synod/SKILL.md" ] || { echo "acceptance-m10: the bundle has no agent-skills" >&2; exit 1; }

# The test-support stand-in for `claude` is never bundled; build it. The app writes its own wrapper
# scripts around it, because the child environment allowlist strips FAKE_CLAUDE_*.
swift build -c release --product fake-claude >&2
fake="$(swift build -c release --product fake-claude --show-bin-path)/fake-claude"
[ -x "$fake" ] || { echo "acceptance-m10: cannot find $fake" >&2; exit 1; }

# A bundled app has no source tree: pass the golden tools/list from the repository.
golden="Tests/SynodCoreTests/Fixtures/mcp/tools.json"
[ -f "$golden" ] || { echo "acceptance-m10: $golden not found" >&2; exit 1; }

# The environment allowlist check needs a variable that must not reach the child.
export SYNOD_SECRET_SENTINEL=acceptance-sentinel

# Static checks on the sources (skipped when there is no source tree, e.g. a copied app).
# The headless claude check plants ANTHROPIC_API_KEY on purpose, so it is excluded from the first grep.
if [ -d Sources ]; then
  if grep -rnE 'SecItem|Keychain|ANTHROPIC' Sources --include='*.swift' --exclude='HeadlessClaude.swift'; then
    echo "acceptance-m10: the sources touch credentials" >&2; exit 1
  fi
  if grep -rnE 'NWListener|AF_INET|URLSession' Sources --include='*.swift'; then
    echo "acceptance-m10: the sources open or use a network socket" >&2; exit 1
  fi
fi

mkdir -p "$out"
status=0
"$exe" --m10 "$app/Contents/Resources/examples" --out "$out" --claude "$fake" --golden "$golden" "${@:3}" || status=$?
[ -f "$out/report-m10.json" ] && cat "$out/report-m10.json"
exit "$status"
