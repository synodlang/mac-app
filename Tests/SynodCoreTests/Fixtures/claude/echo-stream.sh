#!/bin/sh
# A stub for ClaudeProcess tests: it only echoes stream-json. It is not a model of claude.
# Usage: echo-stream.sh <jsonl file> [slow]
# Prints the file line by line, then writes its cwd and the number of environment variables to
# stderr. With "slow" it prints one line, then sleeps until it gets SIGINT (exit 130).
trap 'echo interrupted >&2; exit 130' INT
if [ "$2" = "slow" ]; then
  echo '{"type":"system","subtype":"init","session_id":"slow-1"}'
  while :; do sleep 0.05; done
fi
while IFS= read -r line; do
  printf '%s\n' "$line"
  sleep 0.02
done < "$1"
echo "cwd=$(pwd)" >&2
echo "env=$(env | wc -l | tr -d ' ')" >&2
