# Delivery spike

`board-server.mjs` is a zero-dependency stdio MCP server with `board_read`, `board_post` and
`board_wait(seconds)`, backed by a JSON file so separately started copies share one board.
On every new post it emits `notifications/message`, or `notifications/claude/channel` when
`BOARD_CHANNEL=1`. Its `instructions` tell the model to call `board_read` at the start of
every turn. Results are in [../../reaching-agents.md](../../reaching-agents.md).

Environment: `BOARD_FILE` (shared state), `BOARD_LOG` (server log), `BOARD_TAG` (log
prefix), `BOARD_CHANNEL=1` (channel mode).

Run everything from this folder. To post to the board from outside while a test runs:

```bash
python3 -c "import json;p='board.json';d=json.load(open(p));d['messages'].append({'from':'agent-alpha','text':'say PINEAPPLE','at':'now'});json.dump(d,open(p,'w'))"
```

## Claude Code

```bash
S="$(pwd)"
printf '{"mcpServers":{"board":{"command":"node","args":["%s/board-server.mjs"],"env":{"BOARD_FILE":"%s/board.json","BOARD_LOG":"%s/board.log"}}}}\n' "$S" "$S" "$S" > mcp.json
echo '{"messages":[]}' > board.json

# Does a notification reach a busy agent? Post to the board (above) about 12s in.
claude -p "Run 'sleep 6' three times, one at a time. Then say whether you received any message or notification while waiting." \
  --mcp-config mcp.json --strict-mcp-config --allowedTools "Bash" < /dev/null

# Does a long-poll survive? No post needed.
claude -p "Call board_wait with seconds=300. Report exactly what it returned." \
  --mcp-config mcp.json --strict-mcp-config --allowedTools "mcp__board__board_wait" < /dev/null
```

**Channels only work in an interactive session.** Add `"BOARD_CHANNEL":"1"` to the server's
`env` in `mcp.json`, then drive `claude --mcp-config mcp.json --strict-mcp-config
--dangerously-load-development-channels server:board` in a pty, the way
[../rewake/run.sh](../rewake/run.sh) does, pressing Enter to accept the development-channels
dialog. Don't also pass `--channels server:board`.

## Codex

```bash
CODEX=/Applications/ChatGPT.app/Contents/Resources/codex
"$CODEX" exec \
  -c "mcp_servers.board={command=\"node\",args=[\"$S/board-server.mjs\"],env={BOARD_FILE=\"$S/board.json\",BOARD_LOG=\"$S/board.log\"}}" \
  --skip-git-repo-check --sandbox read-only \
  "Call board_wait with seconds=120. Then tell me exactly what it returned." < /dev/null
```

Keep `< /dev/null`: without it, `codex exec` waits on stdin.
