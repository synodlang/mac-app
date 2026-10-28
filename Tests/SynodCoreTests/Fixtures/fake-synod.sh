#!/bin/sh
# A stand-in for the synod binary in tests. Run as: /bin/sh fake-synod.sh <synod args>
# Environment:
#   FAKE_MODE      ok | diag | fail | lookfail | broken | sleep | big | tool-error | no-files
#   FAKE_FIXTURES  the Fixtures folder (for synced/ and own/)
#   FAKE_ARGS_FILE if set, the arguments are appended to this file, one call per line
#   FAKE_CHECK     check fixture under synced/check for FAKE_MODE=diag (default type-mismatch-nodes.json)
#   FAKE_OVERLAY_OUT  if set and check gets --overlay <file>, the overlay's folder is copied to this path
#   FAKE_FMT_EXIT  exit code of fmt (default 0); FAKE_FMT_APPEND text appended to the file fmt is given
mode="${FAKE_MODE:-ok}"
fix="${FAKE_FIXTURES:-.}"
[ -n "${FAKE_ARGS_FILE:-}" ] && echo "$*" >> "$FAKE_ARGS_FILE"

cmd="$1"
shift

trace=""
scene=""
prev=""
tokens=""
for a in "$@"; do
  [ "$a" = "--tokens" ] && tokens=1
  [ "$prev" = "--overlay" ] && [ -n "${FAKE_OVERLAY_OUT:-}" ] && cp -R "$(dirname "$a")" "$FAKE_OVERLAY_OUT"
  [ "$prev" = "--trace" ] && trace="$a"
  [ "$prev" = "--scene" ] && scene="$a"
  prev="$a"
done

case "$mode" in
  sleep) exec sleep 30 ;;
  big)
    i=0
    while [ $i -lt 1024 ]; do
      printf '%01023d\n' 0
      printf '%01023d\n' 0 >&2
      i=$((i + 1))
    done
    exit 0 ;;
  tool-error) echo "synod: usage error" >&2; exit 2 ;;
esac

case "$cmd" in
  version)
    printf 'language 0.3\ncompiler v0.2.4 (fake, 2026-10-22)\nformats synod-check/1 synod-trace/1 synod-scene/1\n'
    exit 0 ;;
  check)
    if [ "$mode" = "diag" ]; then
      cat "$fix/synced/check/${FAKE_CHECK:-type-mismatch-nodes.json}"
      echo
      exit 1
    fi
    if [ -n "$tokens" ]; then
      cat "$fix/own/check-tokens.json"
      echo
      exit 0
    fi
    echo '{"format":"synod-check/1","ok":true,"diagnostics":[]}'
    exit 0 ;;
  fmt)
    [ -n "${FAKE_FMT_APPEND:-}" ] && printf '%s' "$FAKE_FMT_APPEND" >> "$1"
    if [ "${FAKE_FMT_EXIT:-0}" != 0 ]; then
      echo "$1:3:1: error[syntax]: cannot format"
      exit "$FAKE_FMT_EXIT"
    fi
    exit 0 ;;
  run)
    case "$mode" in
      ok|broken)
        cp "$fix/synced/examples/raft/trace.jsonl" "$trace"
        cp "$fix/synced/examples/raft/scene.json" "$scene"
        echo "ok seed 3: stop at 8s, 5 nodes, 2197 events -> $trace"
        [ "$mode" = "broken" ] && echo "broken at 90ms (2 times): raft/raft.synod:54: always LeadersAgree"
        echo "scene 147.98s, 1928 shapes -> $scene"
        exit 0 ;;
      fail)
        cp "$fix/synced/errors/time-limit/trace.jsonl" "$trace"
        cp "$fix/synced/examples/tcp/scene.json" "$scene"
        tail -n 1 "$fix/synced/errors/time-limit/expect.txt"
        echo "scene 0.6s, 1 shape -> $scene"
        exit 1 ;;
      lookfail)
        cp "$fix/synced/examples/tcp/trace.jsonl" "$trace"
        cp "$fix/synced/examples/tcp/scene.json" "$scene"
        cat "$fix/own/look-failed.txt"
        exit 1 ;;
      no-files)
        echo "p/p.synod:3:1: error[missing-main]: no main file in p"
        exit 1 ;;
    esac ;;
esac
echo "fake-synod: unsupported call: $cmd $*" >&2
exit 2
