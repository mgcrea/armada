#!/bin/bash
# THROWAWAY SPIKE. What does a stdio MCP server know about the Claude Code session that
# started it, and does that survive /clear?
#
# Starts an interactive session with probe.cjs as its only MCP server, snapshots this
# folder's entry in ~/.claude/sessions before and after /clear, and prints what the probe
# logged. Results from 2026-09-10 are in ../../reaching-agents.md ("Sender identity").
set -u
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D" || exit 1
rm -f id.log snap.log pty.txt
printf '{"mcpServers":{"idprobe":{"command":"node","args":["%s/probe.cjs"],"env":{"ID_LOG":"%s/id.log"}}}}\n' "$D" "$D" > mcp.json

snap() {
  python3 - "$D" "$1" <<'PY'
import glob, json, os, sys
folder, label = sys.argv[1], sys.argv[2]
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        entry = json.load(open(f))
    except Exception:
        continue
    if os.path.realpath(entry.get("cwd", "")) == os.path.realpath(folder):
        print(label, "pid", entry["pid"], "sessionId", entry["sessionId"], "name", entry.get("name"))
PY
}

( sleep 11; snap before-clear >> snap.log ) &
( sleep 21; snap after-clear >> snap.log ) &
( sleep 6; printf '\r'; sleep 8; printf '/clear'; sleep 1; printf '\r'; sleep 9; printf '\x03\x03' ) |
  env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT \
      -u CLAUDE_AGENT_SDK_VERSION -u CLAUDE_CODE_EXECPATH \
    timeout 40 script -q /dev/null claude --mcp-config "$D/mcp.json" --strict-mcp-config \
      --dangerously-skip-permissions > pty.txt 2>&1
wait
echo "=== probe MCP server logged ==="
cat id.log
echo "=== session list showed ==="
cat snap.log
