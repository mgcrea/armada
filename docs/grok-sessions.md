# Grok Build: sessions, limits and hooks

Findings from 2026-09-17 against Grok Build 1.0.34 (`grok`, xAI's coding CLI, open source at
github.com/xai-org/grok-build). They come from two headless turns and a resume run in a scratch
repository, a probe hook logging every event, and the user guide Grok installs in
`~/.grok/docs/user-guide/`. Less complete than [codex-sessions.md](codex-sessions.md): nothing
here has been measured against the interactive TUI yet, and the gaps are listed at the end.

**What 2026-09-17 settled:**

| Question | Answer |
| --- | --- |
| Does Armada's Claude Code hook run inside Grok? | **Yes, and it held every turn open** until the fix below |
| Where are the transcripts? | `sessions/<url-encoded cwd>/<session id>/updates.jsonl` |
| Are turn boundaries explicit? | Yes: a `turn_completed` update, with that turn's usage |
| Where are tokens and cost? | `usage.json` in the session directory, the same JSON `grok usage <id>` prints |
| Where is the context window? | `signals.json`: `contextTokensUsed`, `contextWindowTokens` (500000 on grok-4.6) |
| Which sessions are live? | `active_sessions.json` lists TUI sessions with a pid. **Headless sessions never appear** |
| Where are the plan limits? | Nowhere on disk. `grok agent stdio` answers `_x.ai/billing` with the weekly allowance |
| Can a hook wake an idle session? | No. There is no `asyncRewake`; a Stop hook is a synchronous gate |

## The binary

- `~/.local/bin/grok` → `~/.grok/bin/grok` → `~/.grok/downloads/grok-macos-aarch64`. Installed by
  `curl -fsSL https://x.ai/cli/install.sh | bash`.
- Home is `~/.grok`, or `GROK_HOME`.
- **A different tool uses the same names.** The community `superagent-ai/grok-cli` also installs a
  `grok` binary and also uses `~/.grok`, with `user-settings.json` in it. The official home
  has `version.json` and `config.toml`.
- Launching: `grok "prompt"` (TUI), `grok -p "prompt"` (headless), `-r/--resume <id or title>`,
  `-c/--continue`, `--fork-session` (with `-r`/`-c`), `-s/--session-id <uuid>` (new sessions only),
  `--cwd`, `--trust`.

## Armada's delivery hook inside Grok

Grok reads hooks from `~/.claude/settings.json` by default (`[compat.claude] hooks`, or
`GROK_CLAUDE_HOOKS_ENABLED`), so the `asyncRewake` Stop hook that Settings > Supervisor >
Deliver messages installs runs in every Grok session. Grok has no `asyncRewake`, so the hook
runs as a blocking Stop gate. Grok's input also carries Claude's snake_case keys next to its own:

```
{"hookEventName":"stop","sessionId":"01a0af59-…","hook_event_name":"Stop","session_id":"01a0af59-…",
 "reason":"end_turn","stopHookActive":false,"lastAssistantMessage":"…","promptId":"…", …}
```

The script found a session id, waited on an inbox no message would reach, and kept waiting while
its parent `grok` lived, for up to the 86400-second timeout. Measured: a one-word headless turn
finished its inference in 7 seconds and was still running 240 seconds later, with
`deliver-message.zsh` a child of `grok`. The same turn with `GROK_CLAUDE_HOOKS_ENABLED=false` took
8 seconds. A second Stop fires at session end (`reason: "shutdown"`), so exiting would have hung
too.

**The fix:** the script exits 0 at once when `GROK_HOOK_EVENT` is set or its input contains
`hookEventName`, which Claude Code never sends. With the new script installed and Claude hooks
left on, the same turn took 3 seconds.

## Files

```
~/.grok/
  active_sessions.json        [{session_id, pid, cwd, opened_at}]   TUI sessions only
  models_cache.json           models and context_window, from cli-chat-proxy.grok.com
  auth.json                   OAuth tokens and API keys. Armada never opens it
  logs/unified.jsonl          {ts, lvl, msg, pid, sid, ctx}; hook runs are not logged here
  sessions/<url-encoded cwd>/<session id>/
    summary.json              index entry
    updates.jsonl             the conversation, authoritative
    usage.json                session and per-turn tokens and cost
    signals.json              counters, context usage
    chat_history.jsonl        what was sent to the model, rebuilt from updates.jsonl
    events.jsonl, rewind_points.jsonl, system_prompt.txt, tool_definitions.json, …
    *.lock                    zero-byte lock files beside updates, summary and chat_history
```

A cwd whose encoded name is over 255 bytes becomes a slug plus a hash, with the real path in a
`.cwd` file. The session id is a UUIDv7, so ids sort by creation time.

### `summary.json`

```
{"info": {"id", "cwd"}, "created_at", "updated_at", "last_active_at", "num_messages",
 "num_chat_messages", "current_model_id": "grok-4.6", "session_kind": "headless",
 "git_root_dir", "grok_home", "agent_name", "reasoning_effort", "session_summary": "", …}
```

`generated_title` and `parent_session_id` are documented. Neither was written for a two-turn
headless session. `session_kind` was `headless`; the TUI's value is not measured yet.

### `updates.jsonl`

One `{"timestamp": <unix seconds>, "method": …, "params": {…}}` per line. `params.update` holds
ACP's `sessionUpdate` for `method: "session/update"`, and xAI's own for `"_x.ai/session/update"`.
One turn with a file read, in order:

| method | `sessionUpdate` | Holds |
| --- | --- | --- |
| `_x.ai/…` | `hook_execution` | `event_name: user_prompt_submit`, `prompt_id` |
| `session/update` | `user_message_chunk` | `content.text`, `_meta.modelId`, `_meta.promptIndex` |
| `session/update` | `agent_thought_chunk` | reasoning text |
| `session/update` | `tool_call` | `toolCallId`, `title: "read_file"`, `rawInput`, `_meta["x.ai/tool"].read_only` |
| `session/update` | `tool_call_update` | the same `toolCallId`, then `status: "completed"` with `rawOutput` |
| `session/update` | `agent_message_chunk` | the answer |
| `_x.ai/…` | `turn_completed` | `prompt_id`, `stop_reason: "end_turn"`, `usage` |
| `_x.ai/…` | `hook_execution` | `session_end`, then `stop` |
| `_x.ai/…` | `background_tasks` | `tasks: []` |

`turn_completed.usage` has `inputTokens`, `outputTokens`, `totalTokens`, `cachedReadTokens`,
`cacheCreationTokens`, `reasoningTokens`, `modelCalls`, `apiDurationMs` and `costUsdTicks`
(1e10 ticks to the dollar). A resumed session appends to the same file.

### `usage.json` and `signals.json`

`usage.json` is `{sessionId, updatedAt, session: {…totals, turnCount, primaryModelId, modelUsage},
turns: [{turnNumber, endedAt, …}]}`, byte for byte what `grok usage <id>` prints. The model name
here is `grok-4.6-build`, while `summary.json` says `grok-4.6`.

`signals.json` is one flat object: `turnCount`, `toolCallCount`, `contextTokensUsed: 11790`,
`contextWindowTokens: 500000`, `contextWindowUsage: 2` (percent), `modelsUsed`,
`sessionDurationSeconds`, and many more counters.

## Which sessions are live

`active_sessions.json` listed the one open TUI session, `{session_id, pid, cwd, opened_at}`,
before, during and after both headless runs, and never the headless sessions. A headless session
is live only while its `grok -p` process runs, and nothing on disk names that process. Not
measured yet: whether an entry goes away on `/exit`, and whether one survives `kill -9`.

## Hooks

Events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionDenied`, `Stop`, `StopFailure`, `StopCancelled`, `Notification`
(`idle_prompt`, `permission_prompt`, `task_complete`), `SubagentStart`, `SubagentStop`,
`PreCompact`, `PostCompact`. They are read from `~/.grok/hooks/*.json` (always trusted),
`config.toml`, `~/.claude/settings.json`, `~/.cursor/hooks.json`, and a trusted project's
`.grok/hooks/`, `.claude/settings.json` and `.cursor/hooks.json`. The environment has
`GROK_HOOK_EVENT` (snake_case, e.g. `stop`), `GROK_SESSION_ID`, `GROK_WORKSPACE_ROOT` and
`CLAUDE_PROJECT_DIR`.

Measured order for one turn: `session_start`, `user_prompt_submit`, `pre_tool_use`,
`post_tool_use`, `stop` (`reason: end_turn`), `session_end` (`reason: shutdown`), then a second
`stop` (`reason: shutdown`).

**What this means for delivering a message.** A Stop hook that blocks makes the agent run another
round of the same turn, up to 8 times, and then the turn ends regardless. Nothing wakes a session
that has already gone idle. The route left to measure is leader mode (`grok agent --leader`),
which accepts ACP `session/prompt` from clients, but only for sessions started in it.

## Limits

Nothing on disk holds the allowance, and the status-line payload has no rate-limit field. The TUI's
`/usage` fetches it from `cli-chat-proxy.grok.com/billing?format=credits` with the signed-in token
(`crates/codegen/xai-grok-shell/src/extensions/billing.rs`), and the same code answers the Agent
Client Protocol extension method `x.ai/billing` in `grok agent stdio`. On the wire it takes a
leading underscore. Measured 2026-09-17:

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}
→ {"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}
← {"id":2,"result":{"config":{"creditUsagePercent":13.0,
     "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-15T21:25:12.584887+00:00",
                      "end":"2026-09-22T21:25:12.584887+00:00"},
     "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},
     "isUnifiedBillingUser":true,"billingPeriodStart":"…","billingPeriodEnd":"…"},
   "subscription_tier":"X Premium"}}
```

`initialize` answered in 0.25s and the billing request in 0.13s. No session directory and no
`active_sessions.json` entry appeared, and no prompt is sent. This is `GrokControl`, run the way
`UsageProbe` runs `claude`: the person's own binary, so Armada never handles the token. One
allowance covers every model; a monthly period (`USAGE_PERIOD_TYPE_MONTHLY`) exists in the source
and has not been seen. `StopFailure` with `error: "rate_limit"` is the hook-side signal of hitting it.

## Open questions

- The TUI: what a pending permission prompt writes to `updates.jsonl`, the `session_kind` value,
  and when `generated_title` appears.
- Whether `active_sessions.json` drops an entry on `/exit` and on `kill -9`.
- Whether leader mode can deliver a message to a TUI session Armada did not start.
- Whether Grok accepts an MCP config, a tool allowlist and an appended system prompt from the
  command line, which a supervisor session needs.
