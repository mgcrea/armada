#!/bin/bash
# THROWAWAY SPIKE. A Stop hook configured with "asyncRewake": true.
# Waits for msg.txt next to this script. When it appears, prints it to stderr and exits 2,
# which wakes Claude even if the session is idle. Exits 0 (no wake) after ~150s without one.
D="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hook_event_name",""))')
echo "$(date +%T) armed event=$EVENT" >> "$D/hook.log"
for _ in $(seq 1 150); do
  if [ -f "$D/msg.txt" ]; then
    MSG=$(cat "$D/msg.txt")
    rm -f "$D/msg.txt"
    echo "$(date +%T) delivering, exit 2" >> "$D/hook.log"
    echo "Message from agent codex-demo (via hub): $MSG" >&2
    exit 2
  fi
  sleep 1
done
echo "$(date +%T) no message, exit 0" >> "$D/hook.log"
exit 0
