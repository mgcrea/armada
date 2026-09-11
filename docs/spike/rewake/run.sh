#!/bin/bash
# THROWAWAY SPIKE. Does an asyncRewake Stop hook wake an idle Claude Code session?
#
#   bash run.sh terminal      the interactive UI, in a pty
#   bash run.sh stream-json   the mode the VS Code extension runs the CLI in
#
# Asks for READY, lets the session go idle, drops a message that asks for PINEAPPLE, then
# prints the hook log. Results from 2026-09-10 are in ../../reaching-agents.md.
set -u
MODE="${1:-terminal}"
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D" || exit 1
rm -f msg.txt hook.log out.jsonl err.txt pty.txt in.fifo
chmod +x "$D/wait-for-msg.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/wait-for-msg.sh","asyncRewake":true,"timeout":300}]}]}}\n' "$D" > settings.json

MESSAGE="the API schema migration on main just finished. If you received this, acknowledge with the word PINEAPPLE."
UNSET=(-u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN
       -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT
       -u CLAUDE_AGENT_SDK_VERSION -u CLAUDE_CODE_EXECPATH)

if [ "$MODE" = "stream-json" ]; then
  mkfifo in.fifo
  # Hold stdin open like a live editor tab; closing it ends the session.
  ( exec 3>in.fifo
    echo '{"type":"user","message":{"role":"user","content":"Reply with just the word READY."}}' >&3
    sleep 80
    exec 3>&- ) &
  ( sleep 30; echo "$MESSAGE" > msg.txt; echo "$(date +%T) message file written" >> hook.log ) &
  env "${UNSET[@]}" timeout 110 claude -p --output-format stream-json --verbose --input-format stream-json \
    --settings "$D/settings.json" --dangerously-skip-permissions < in.fifo > out.jsonl 2> err.txt
  echo "=== results on stdout ==="
  grep -o '"result":"[^"]*"' out.jsonl
else
  ( sleep 45; echo "$MESSAGE" > msg.txt; echo "$(date +%T) message file written" >> hook.log ) &
  # Enter first for any folder-trust dialog; Enter on its own after the prompt text.
  ( sleep 6; printf '\r'; sleep 6; printf 'Reply with just the word READY.'; sleep 1; printf '\r'
    sleep 85; printf '\x03\x03' ) |
    env "${UNSET[@]}" timeout 110 script -q /dev/null claude --settings "$D/settings.json" \
      --dangerously-skip-permissions > pty.txt 2>&1
  echo "PINEAPPLE found in transcript: $(grep -a -c PINEAPPLE pty.txt) line(s)"
fi
wait
echo "=== hook log ==="
cat hook.log
pkill -f "$D/wait-for-msg.sh" 2>/dev/null
