#!/usr/bin/env bash
# The owner's live acceptance for the Claude integration (plan check 11 and addendum A13 items 1 to 3).
# It needs YOUR Claude Code login and network, so it is not part of CI. Run it in a Terminal:
#
#   scripts/acceptance-m10-live.sh [path/to/Synod.app] [out-dir]
#
# What it does, in order (it prints each step):
#   1. records `claude --version` and checks that this Claude Code accepts every flag spelling the app uses;
#   2. in a temporary project, adds `synod mcp` to Claude Code, asks `claude -p` to explain unknown-phrase and
#      to summarize a run of raft, compares both answers with the CLI, checks that no `out/` appeared,
#      records the protocolVersion Claude Code sent (a tee in front of `synod mcp`), then removes the server;
#   3. three times: makes a fresh module, opens it in the app, prints the prompt to type in the prompt bar,
#      waits for you, then checks the result with the compiler (plan check 11's conditions);
#   4. prints the on-screen checks and the external-session steps for you to do by hand.
# It never reads or prints credentials: Claude Code itself uses your login. The report is <out>/report-m10-live.txt.
# Paste the report into the mac-app release PR description.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/build/Synod.app}"
out="${2:-$root/acc-m10-live}"
case "$app" in /*) ;; *) app="$PWD/$app" ;; esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
synod="$app/Contents/Helpers/synod"
exe="$app/Contents/MacOS/Synod"
mkdir -p "$out"
report="$out/report-m10-live.txt"
: > "$report"

step() { printf '\n== %s\n' "$*"; printf '\n== %s\n' "$*" >> "$report"; }
say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$report"; }
die() { echo "acceptance-m10-live: $*" >&2; exit 1; }
fails=0
result() { # result <PASS|FAIL|CHECK> <text>
  say "  [$1] $2"
  [ "$1" = FAIL ] && fails=$((fails + 1))
  return 0
}
ask() { # ask <question>; yes when the owner types y
  local a
  printf '%s [y/n] ' "$1"
  read -r a < /dev/tty || a=n
  printf '%s -> %s\n' "$1" "$a" >> "$report"
  [ "$a" = y ]
}
pause() { printf '%s ' "$1"; read -r _ < /dev/tty || true; }

[ -x "$synod" ] || die "$synod not found; run scripts/bundle.sh first"
[ -x "$exe" ] || die "$exe not found"
command -v claude >/dev/null || die "claude (Claude Code) is not on PATH"
command -v python3 >/dev/null || die "python3 is needed to read traces"
work="$(mktemp -d "${TMPDIR:-/tmp}/synod-m10-live.XXXXXX")"
cleanup() { claude mcp remove synod --scope local >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

step "1. Claude Code version and flag spellings"
cver="$(claude --version 2>&1 | head -1)"
say "claude --version: $cver"
help="$(claude --help 2>&1)"
for flag in -p --output-format --verbose --append-system-prompt --add-dir --mcp-config --strict-mcp-config \
            --allowedTools --disallowedTools --model --resume; do
  if printf '%s' "$help" | grep -q -- "$flag"; then result PASS "claude --help lists $flag"; else result FAIL "claude --help does not list $flag"; fi
done
if printf '%s' "$help" | grep -qi 'stream-json'; then result PASS "stream-json is an output format"; else result CHECK "stream-json not named in --help"; fi

step "2. synod mcp inside Claude Code (A13 item 3)"
# A tee in front of `synod mcp` records what Claude Code sends first (the initialize request).
wrapper="$work/synod-tee"
sent="$work/mcp-sent.jsonl"
cat > "$wrapper" <<WRAP
#!/bin/sh
exec /usr/bin/tee "$sent" | "$synod" "\$@"
WRAP
chmod +x "$wrapper"
proj="$work/examples"
cp -R "$app/Contents/Resources/examples" "$proj"
(cd "$proj" && git init -q . >/dev/null 2>&1; git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=acc commit -qm base >/dev/null 2>&1)
say "temporary project: $proj"
say "running: claude mcp add --scope local synod -- <tee wrapper> mcp --root <project>"
(cd "$proj" && claude mcp add --scope local synod -- "$wrapper" mcp --root "$proj") >> "$report" 2>&1 \
  && result PASS "claude mcp add synod" || result FAIL "claude mcp add synod"

ask_claude() { # ask_claude <prompt> -> prints the answer text
  (cd "$proj" && claude -p "$1" --allowedTools "mcp__synod" --disallowedTools "Write,Edit,Bash" 2>&1)
}
say "asking: explain unknown-phrase (non-interactive claude -p)"
want_explain="$("$synod" explain unknown-phrase)"
got="$(ask_claude "Using only the synod MCP server tools, explain the error code unknown-phrase. Quote the tool's text exactly and add nothing.")"
first="$(printf '%s\n' "$want_explain" | head -1)"
if printf '%s' "$got" | grep -qF -- "$first"; then result PASS "the answer contains: $first"; else result FAIL "the answer lacks the first line of 'synod explain unknown-phrase'"; fi
say "--- answer (first 12 lines)"; printf '%s\n' "$got" | head -12 | tee -a "$report"

say "asking: summarize a run of raft"
want_sum="$("$synod" run "$proj/raft" --summary 2>&1 | head -1)"
got2="$(ask_claude "Using only the synod MCP server tools, summarize a run of the raft program. Quote the tool's text exactly and add nothing.")"
if printf '%s' "$got2" | grep -qF -- "$want_sum"; then result PASS "the answer contains the first line of 'synod run raft --summary'"; else result CHECK "compare by eye; the CLI starts with: $want_sum"; fi
say "--- answer (first 12 lines)"; printf '%s\n' "$got2" | head -12 | tee -a "$report"

if [ -d "$proj/out" ]; then result FAIL "the workspace has a new out/ folder"; else result PASS "no new out/ in the workspace"; fi
if [ -z "$(cd "$proj" && git status --porcelain 2>/dev/null)" ]; then result PASS "git status is clean"; else result FAIL "the project changed: $(cd "$proj" && git status --porcelain | head -5 | tr '\n' ' ')"; fi

pv="$(python3 -I - "$sent" <<'PY'
import json, sys
try:
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("method") == "initialize":
            p = m.get("params", {})
            print(p.get("protocolVersion", "?"), "from", p.get("clientInfo", {}).get("name", "?"), p.get("clientInfo", {}).get("version", ""))
            break
except OSError:
    pass
PY
)"
say "protocolVersion Claude Code sent to synod mcp: ${pv:-not recorded}"
claude mcp remove synod --scope local >> "$report" 2>&1 && result PASS "claude mcp remove synod" || result CHECK "remove it yourself: claude mcp remove synod"

step "3. The prompt bar with your Claude Code (plan check 11 and A13 item 1)"
say "Three fresh modules, one request each, no follow-up. The app uses your normal Claude Code login."
prompt="animate two-phase commit with a coordinator crash"
passed=0
check_run() { # check_run <module dir> <before-dir-listing> <before synod.sum hash> <before vendor hash>
  local m="$1" before="$2" sumhash="$3" vhash="$4" ok=1
  if (cd "$m" && "$synod" check . >/dev/null 2>&1); then result PASS "synod check . exits 0"; else result FAIL "synod check . fails"; ok=0; fi
  local newmains
  newmains="$(cd "$m" && find . -name '*.synod' -not -path './vendor/*' -not -path './out/*' | sort | comm -13 <(printf '%s\n' "$before") - | while read -r f; do grep -lE '^# package main' "$f"; done)"
  local count
  count="$(printf '%s' "$newmains" | grep -c . || true)"
  if [ "$count" = 1 ]; then result PASS "exactly one new main file: $newmains"; else result FAIL "new main files: $count"; ok=0; fi
  if [ "$count" = 1 ]; then
    local dir trace="$work/trace.jsonl"
    dir="$m/$(dirname "$newmains")"
    if "$synod" run "$dir" --trace "$trace" >/dev/null 2>&1; then result PASS "synod run exits 0"; else result FAIL "synod run fails"; ok=0; fi
    local verdict
    verdict="$(python3 -I - "$trace" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
head, events = lines[0], lines[1:]
out = []
out.append(("the trace packages contain github.com/synodlang/examples/twopc", "github.com/synodlang/examples/twopc" in head.get("packages", [])))
state = {}
for e in events:
    if e.get("ev") == "sim.Added":
        state[e["node"]] = dict(e.get("state") or {})
    elif e.get("ev") == "sim.Changed":
        state.setdefault(e["node"], {})[e["field"]] = e.get("new")
crashed = [e["node"] for e in events if e.get("ev") == "sim.Crashed"]
coordinator = any(state.get(n, {}).get("twopc.Participants") for n in crashed)
out.append(("a sim.Crashed node is the coordinator (non-empty twopc.Participants)", coordinator))
for text, ok in out:
    print(("PASS " if ok else "FAIL ") + text)
PY
)"
    while IFS= read -r l; do
      case "$l" in PASS*) result PASS "${l#PASS }" ;; FAIL*) result FAIL "${l#FAIL }"; ok=0 ;; esac
    done <<< "$verdict"
  fi
  if (cd "$m" && find . -name '*.synod' -not -path './vendor/*' | sort | comm -13 <(printf '%s\n' "$before") - | xargs -I{} grep -lE '^# package twopc|^(Prepare|Vote|Decision) has' {} 2>/dev/null | grep -q .); then
    result FAIL "a new file declares package twopc or a Prepare, Vote or Decision record"; ok=0
  else
    result PASS "no new copy of the twopc package or its records"
  fi
  local nowsum nowvendor
  nowsum="$(shasum -a 256 "$m/synod.sum" 2>/dev/null | awk '{print $1}')"
  nowvendor="$(cd "$m" && find vendor -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  if [ "$nowsum" = "$sumhash" ] && [ "$nowvendor" = "$vhash" ]; then result PASS "synod.sum and vendor/ are unchanged (h1 intact)"; else result FAIL "synod.sum or vendor/ changed"; ok=0; fi
  [ "$ok" = 1 ]
}

for run in 1 2 3; do
  say ""
  say "-- run $run of 3"
  m="$work/acc-$run"
  mkdir -p "$m"
  printf 'module example.com/acc\nsynod 0.2\n\nrequire github.com/synodlang/examples v0.2.1\n' > "$m/synod.mod"
  printf 'out/\n' > "$m/.gitignore"
  if ! (cd "$m" && "$synod" get >> "$report" 2>&1); then result FAIL "synod get failed (network?)"; continue; fi
  before="$(cd "$m" && find . -name '*.synod' -not -path './vendor/*' | sort)"
  sumhash="$(shasum -a 256 "$m/synod.sum" 2>/dev/null | awk '{print $1}')"
  vhash="$(cd "$m" && find vendor -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  say "fresh module: $m"
  pause "Quit any running Synod (Cmd-Q), then press Return to open the module in the app."
  open -n "$app" --args "$m"
  say "In the app: Settings > Claude: turn the prompt bar on and confirm it finds Claude Code."
  say "Then press Cmd-K, type this exactly and send it (one request, no follow-up):"
  say ""
  say "    $prompt"
  say ""
  say "While it runs, check the progress lines: they must show mcp__synod-editor__ tool calls and no Write or Edit."
  say "When Claude finishes, the banner shows the changed files and the new program plays."
  pause "Press Return when the request has finished (or failed)."
  if ask "Did the request finish without an error banner?"; then result PASS "the result is not an error"; else result FAIL "the request ended in an error"; fi
  if ask "Did the progress lines show mcp__synod-editor__ calls and no Write or Edit?"; then result PASS "transcript uses the editor tools only"; else result FAIL "transcript shows Write or Edit, or no editor tools"; fi
  if ask "Was the new program saved by Claude (the buffer is not dirty and the file is on disk)?"; then result PASS "saved through save_files"; else result CHECK "unsaved: press Save All, then continue"; fi
  say "Checking the module with the bundled compiler:"
  if check_run "$m" "$before" "$sumhash" "$vhash"; then result PASS "run $run passes"; passed=$((passed + 1)); else result FAIL "run $run fails"; fi
done
say ""
say "passed: $passed, runs: 3"
[ "$passed" = 3 ] || say "3 of 3 must pass. A failure is fixed in SKILL.md (agent-skills), then agent-skills and the app pin are re-released; do not retry."

step "4. Things to do by hand"
cat <<'MANUAL' | tee -a "$report"
External session (A13 item 2):
  1. In Settings > Claude turn on "external Terminal access" (it is off at every launch), read the warning, and use Copy MCP config.
  2. Paste the line in Terminal, then start `claude` in the workspace folder and ask:
       add a lesson.Note saying the coordinator is gone after the crash in twopc demo
  3. In the app the buffer must change unsaved ("Claude Edit"), and Cmd-Z must undo it.
  4. Click Disconnect in the indicator: the same request must now fail in Terminal.
  5. Quit the app: `claude mcp list` must show the server failing. Then run: claude mcp remove synod-editor
On screen (A13 item 4):
  the Settings toggle and its warning, the indicator and Disconnect, live "Claude Edit" changes in a locked editor,
  and the Save All and Revert banner.
MANUAL
say ""
say "claude: $cver"
say "protocolVersion sent to synod mcp: ${pv:-not recorded}"
say "flag spellings: see section 1"
say "fails: $fails"
echo
echo "Report: $report"
[ "$fails" = 0 ] && [ "$passed" = 3 ]
