#!/bin/bash
# THROWAWAY SPIKE driver: walk one real interactive Claude Code session through
# launch -> prompt -> long silent tool call -> reply -> quiet -> exit, marking wall-clock
# times so the watcher's log can be checked against what actually happened.
set -u
S="$(cd "$(dirname "$0")" && pwd)"
mark() { echo "$(date +%H:%M:%S.%3N)  MARK     $*" >> "$S/marks.log"; }
: > "$S/marks.log"
mkdir -p "$S/child-proj"
echo '{"mcpServers":{}}' > "$S/empty-mcp.json"
cd "$S/child-proj"

mark "launch child session"
(
  sleep 6; printf '\r'   # accepts a folder-trust dialog if one appears; a no-op otherwise
  sleep 4
  printf 'Run this bash command in the foreground, not in the background: sleep 40. When it finishes, reply with only the word done.'
  sleep 1; printf '\r'; mark "prompt submitted"   # Enter on its own: sent with the text it lands inside the paste
  sleep 95; mark "ctrl-c sent"
  printf '\x03\x03'
) | env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT \
      -u CLAUDE_AGENT_SDK_VERSION -u CLAUDE_CODE_EXECPATH \
    timeout 140 script -q /dev/null claude --mcp-config "$S/empty-mcp.json" --strict-mcp-config \
      --dangerously-skip-permissions > "$S/child-pty.txt" 2>&1
mark "child process exited rc=$?"
