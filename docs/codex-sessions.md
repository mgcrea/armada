# Codex: sessions, limits and hooks

Findings from 2026-09-09 and 2026-09-10 against Codex 0.152.0. Less complete than
[claude-code-sessions.md](claude-code-sessions.md): enough to design from, with the gaps
listed at the end.

## The binary

- `/Applications/ChatGPT.app/Contents/Resources/codex` (`codex-cli 0.152.0`). Not on `PATH`.
- `codex exec` runs non-interactively. It **waits on stdin** unless given `< /dev/null`.
- `-c key=value` overrides config for one run without touching `config.toml`, for example
  `-c 'mcp_servers.board={command="node",args=["/abs/board-server.mjs"],env={BOARD_FILE="/abs/board.json"}}'`.
- Other useful flags: `--skip-git-repo-check`, `--sandbox read-only|workspace-write`.
- **Don't edit `~/.codex/config.toml` for tests.** The ChatGPT app rewrites it on launch.

## Files

- `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`: one log per session.
- Also present, not studied: `session_index.jsonl`, `state_5.sqlite`, `thread-writer-locks/`,
  `archived_sessions/`.
- `auth.json` holds credentials when the file store is used. Armada must never read it.

### Session log entries

Types seen in one run: `session_meta`, `turn_context`, `world_state`,
`event_msg/task_started`, `response_item/message`, `response_item/reasoning`,
`response_item/custom_tool_call`, `response_item/custom_tool_call_output`,
`event_msg/item_completed`, `event_msg/token_count`, `event_msg/task_complete`.

`task_started` and `task_complete` make "working" and "waiting for input" explicit, unlike
Claude Code's transcripts.

## Limits

Every `token_count` event carries the plan windows:

```json
{
  "type": "token_count",
  "info": { "total_token_usage": {}, "last_token_usage": {}, "model_context_window": 258400 },
  "rate_limits": {
    "limit_id": "codex",
    "primary":   { "used_percent": 1.0, "window_minutes": 300,   "resets_at": 1789006360 },
    "secondary": { "used_percent": 0.0, "window_minutes": 10080, "resets_at": 1789593160 },
    "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
    "plan_type": null
  }
}
```

`primary` is the 5-hour window and `secondary` the 7-day one. No credentials involved.

## As an MCP client

- Sends `initialize` as `codex-mcp-client`, protocol `2025-06-18`.
- **Tool calls hard-fail at exactly 300 seconds** (`timed out awaiting tools/call after 300s`).
- `notifications/message` never reaches the model, and the `instructions` field was ignored.
- Stdio MCP servers get a restricted environment (`codex-rs/rmcp-client/src/utils.rs`)
  without `CODEX_SESSION_ID` or `CODEX_THREAD_ID`; those only go to shell commands.

## Hooks

Docs: https://developers.openai.com/codex/hooks. Generated JSON schemas for every event's
input and output: `codex-rs/hooks/schema/generated/`.

- **Configured** in `hooks.json` or inline `[hooks]` tables in `config.toml`, next to the
  active config layers. The `hooks` key turns them on or off (`codex_hooks` is a deprecated
  alias).
- **Events.** During a turn: `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`,
  `PostCompact`, `UserPromptSubmit`, `SubagentStop`, `Stop`. When a turn is interrupted:
  `Interrupt`. At the start: `SessionStart`, `SubagentStart`. At the end: `SessionEnd`.
- **Common input:** `session_id`, `cwd`, `model`, `permission_mode`, `hook_event_name`, and
  `transcript_path`, which can be null (find the session log by session ID instead). Turn
  events add `turn_id`; `SessionStart` adds `source`; `Stop` adds `stop_hook_active` and
  `last_assistant_message`.
- **Continuing a turn:** `Stop` returns `decision: "block"` with a `reason`, or exits 2 with
  the reason on stderr. `stop_hook_active` says the turn was already continued, to prevent
  loops.
- **Adding context:** `SessionStart`, `UserPromptSubmit` and others return
  `hookSpecificOutput.additionalContext`. `additionalContextLimit` sets when oversized
  context is saved to disk and shown as a preview.
- **`PreToolUse`:** matchers work on MCP tool names (`mcp__filesystem__read_file`,
  `mcp__filesystem__.*`). The input adds `tool_name`, `tool_use_id` and `tool_input`. The
  output can block, add context, or rewrite the call: `permissionDecision: "allow"` with
  `updatedInput`, which for MCP tools is the replacement arguments object.
- **Background hooks** (`async: true`) can't block, approve, rewrite or continue anything.
  Up to eight run at once per session. **Nothing wakes an idle session.**
- **Timeouts:** 600s by default for most hooks. `SessionEnd` and `Interrupt` default to 1s
  and allow up to 3s.
- **`notify`** in `config.toml` runs a single program when a turn ends. On this Mac it's
  already used by Codex Computer Use (`SkyComputerUseClient turn-ended`), so chain to it
  rather than replace it, or use hooks instead.

Reported upstream, not verified: [repo-local hooks not firing in interactive
sessions](https://github.com/openai/codex/issues/17532), and [SessionStart and
UserPromptSubmit failing under one backend](https://github.com/anthony-chaudhary/dos-kernel/issues/237).

## Multiple accounts

`CODEX_HOME` (default `~/.codex`) holds config, logs and, with
`cli_auth_credentials_store = "file"`, `auth.json`. Config profiles sit beside it as
`$CODEX_HOME/<profile>.config.toml`. With the `keyring` store, separate homes may share
credentials. Unverified.

## Open questions

- Where does Codex keep a session's title, if anywhere?
- Does one Codex process (the ChatGPT app, the IDE extension) host several conversations?
- Does an `updatedInput` rewrite from `PreToolUse` reach the MCP server?
- Do `Stop` blocks and `UserPromptSubmit` context deliver reliably in an interactive Codex
  session?
