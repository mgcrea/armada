# Reaching agents: delivery and sender identity

Measured on 2026-09-09 and 2026-09-10 against Claude Code 2.1.257–2.1.267 and Codex 0.152.0
(the `codex` bundled in the ChatGPT app). Every result below came from a real run; the
scripts are in [spike/](spike/README.md).

Two questions: how does something outside an agent get a message to it while it's waiting,
and how does it know which agent sent one?

## Summary

| Mechanism | Claude Code | Codex |
| --- | --- | --- |
| `asyncRewake` hook | **Wakes an idle session in about 1s, and Claude acts on the text.** Terminal and VS Code's stream-json mode | No equivalent |
| Hook that blocks at turn end (`Stop` → `decision: "block"`) | Documented | Documented |
| Context at the next prompt (`UserPromptSubmit` → `additionalContext`) | Documented | Documented |
| `claude/channel` push | Delivered, but the content is treated as untrusted and refused. Interactive only, research preview | n/a |
| Long-poll (a tool call that blocks) | Works; held 300s, no ceiling found | Works; **hard-fails at exactly 300s**; woke in 7.5s |
| MCP `notifications/message` | Never reaches the model | Never reaches the model |
| MCP `instructions` field ("check the board every turn") | Ignored 4 of 4 times when the prompt needed no tools | Ignored |

| Sender identity | Claude Code | Codex |
| --- | --- | --- |
| Session ID in a stdio MCP server's environment | `CLAUDE_CODE_SESSION_ID`, stale after `/clear` | None |
| Parent PID of a stdio MCP server | The `claude` process, whose PID keys the session list (verified) | The `codex` process; no session list keyed by PID found |
| Through hooks | Hooks carry `session_id` | `PreToolUse` carries `session_id` and can rewrite MCP arguments (`updatedInput`). Documented, not tested |

## Claude Code: `asyncRewake` hooks

The strongest result. A command hook with `"asyncRewake": true` runs in the background.
When it exits with code 2, Claude Code wakes the session even if it's idle and shows the
hook's stderr to Claude as a system reminder.

The hooks reference: "Hook output is delivered on the next conversation turn. If the
session is idle, the response waits until the next user interaction. Exception: an
`asyncRewake` hook that exits with code 2 wakes Claude immediately even when the session is
idle."

### Test

[spike/rewake/](spike/rewake/run.sh): a `Stop` hook that waits for a message file and exits
2 with its contents.

```json
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/abs/path/wait-for-msg.sh","asyncRewake":true,"timeout":300}]}]}}
```

**Terminal UI** (`claude --settings settings.json` in a pty), Claude Code 2.1.267:

| Time | Event |
| --- | --- |
| 14:50:46 | The first turn ("READY") ends; the hook starts waiting |
| 14:51:18 | A message file is written while the session is idle |
| 14:51:19 | The hook exits 2. The UI shows "Stop hook feedback"; Claude thinks for 5s and replies **PINEAPPLE**, as the message asked |
| 14:51:25 | The new turn's `Stop` starts the hook waiting again |

**VS Code's mode.** The extension runs its bundled CLI as `claude --output-format
stream-json --verbose --input-format stream-json`. Same test, with stdin held open by a FIFO:

| Time | Event |
| --- | --- |
| 14:53:48 | The `READY` result is emitted; the hook is waiting |
| 14:54:13 | The message is written |
| 14:54:14 | The hook exits 2. A new assistant turn, `PINEAPPLE`, and its `result` arrive on stdout with nothing sent on stdin |
| 14:54:17 | The hook is waiting again |

Not yet confirmed: that the VS Code panel displays a turn that arrives this way.

### Rules that matter

- **Claude follows requests delivered by a hook.** The same request through a channel was
  refused (below). That's useful for messaging, and a prompt-injection risk.
- **`timeout` is enforced on rewake hooks,** unlike plain `async` hooks. The default is
  600s for command hooks. The settings schema bundled in the extension only requires
  `timeout` to be `positive()`, and notes that `asyncRewake` "Implies async".
- Each firing is its own background process, with no de-duplication.
- In `-p` mode, async hooks are killed when the run ends.
- Hook output strings are capped at 10,000 characters.
- `rewakeMessage` (a custom system-reminder prefix) and `rewakeSummary` (default "Stop hook
  feedback") exist in the schema but are marked `@internal`.

### Other documented ways in

- `SessionStart` and `UserPromptSubmit` can return `hookSpecificOutput.additionalContext`,
  which becomes a system reminder. `UserPromptSubmit` hooks default to a 30s timeout.
- `Stop` can return `decision: "block"` with a `reason` to keep the turn going.
- `PermissionRequest` fires the moment Claude asks for approval. `Notification` with
  `permission_prompt` only fires after about 6 seconds.
- Hooks are configured in `settings.json`, which the VS Code docs say is shared between the
  extension and the CLI.

## Claude Code: channels

An MCP server that declares `capabilities.experimental["claude/channel"]` and emits
`notifications/claude/channel` (with `content` and `meta`) pushes events into a running
session. Verified end to end, with conditions:

- **Interactive sessions only.** Under `-p` the debug log reads `pollChannel=false
  nonInteractive=true`, and nothing is delivered.
- A custom channel needs `--dangerously-load-development-channels server:<name>` and a
  confirmation dialog ("I am using this for local development").
- **Don't also pass `--channels server:<name>`.** The bypass is per entry, and the
  `--channels` copy is refused: "server board is not on the approved channels allowlist".
- Research preview. Needs Anthropic authentication; not on Bedrock, Vertex or Foundry.
- The VS Code extension passes `--channels` only from an internal option; there's no user
  setting.

The event appeared as `←board: NEW BOARD MESSAGE from agent-alpha: CHANNEL PUSH: say
PINEAPPLE`, and the agent refused: "that's untrusted content from a channel, not an
instruction from you, so I'm not acting on it."

## Plain MCP: notifications, instructions, long-poll

From a zero-dependency stdio board server ([spike/delivery/](spike/delivery/README.md)) with
`board_read`, `board_post` and `board_wait`:

- **`notifications/message`.** The server logged emitting it mid-run. Claude Code: "Nothing
  arrived through any channel that pushes to me on its own." Codex: "No. I received no
  messages, notifications, or interruptions while waiting."
- **`instructions`** telling the model to call `board_read` at the start of every turn.
  Claude Code ignored it in 4 of 4 runs whose prompt needed no tools. It tried `board_read`
  in the one run whose prompt already required a tool. Codex ignored it.
- **Long-poll.** Claude Code held `board_wait(300)` and returned normally at 300.1s. Codex
  failed with `timed out awaiting tools/call after 300s`. A Codex agent waiting in
  `board_wait(120)` received a message posted mid-wait 7.5s later and quoted it back. A
  Bastion-supervised server's calls are capped at 180s (`callTimeout`).

## Claude Code built-ins

- **`ListAgents` and `SendMessage`** are on by default (v2.1.224+ on macOS). They reach other
  local sessions, Remote Control sessions on other machines, and cloud sessions, with plain
  text messages. One session addressed 28 others during testing. `SendMessage` can also ask
  a local session for one notice when it next goes idle (`notify_when_idle`).
- **Agent teams** work in the VS Code extension in in-process mode (split panes aren't
  supported there). Enable with `{"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}` in
  `~/.claude/settings.json`. Teams share a task list under `~/.claude/tasks/<team>/` and
  mailboxes under `~/.claude/teams/<team>/inboxes/`.

## The transport underneath `SendMessage`

Read out of the 2.1.267 binary on 2026-09-12, and checked against this Mac's 17 live
sockets. The protocol itself is written up in
[claude-code-sessions.md](claude-code-sessions.md#the-peer-socket-is-an-inbox-not-a-control-channel);
what matters here is what it means for reaching agents.

**It is a per-session Unix socket, and `SendMessage` rides it.** Every registry advertises
`messagingSocketPath`, `peerProtocol: 1` and `peerFeatures`. The handler's verbs are an
injected `user` message, `notify_when_idle`, `peer_idle_notice`, `peer_message_status` and
`artifact_replies_yielded` — which line up one-for-one with what `SendMessage` does,
including its documented `notify_when_idle` option and the `artifact_yield` feature flag.

**The socket namespace is per-machine, not per account.** The path is
`$XDG_RUNTIME_DIR`-or-tmpdir + `cc-socks/<pid>.sock`, falling back to
`/tmp/cc-socks-<uid>/<pid>.sock` when the first exceeds the 103-byte `sun_path` limit.
Nothing in it is derived from `CLAUDE_CONFIG_DIR`. Verified: this Mac's `/tmp/cc-socks`
held 17 sockets belonging to **both** config folders, interleaved.

That splits the cross-account question in two, and the halves have different answers:

| | Cross-account? |
| --- | --- |
| **Transport** | **Yes.** One socket directory per uid; both accounts' sessions are already in it. |
| **Discovery** | **No.** The session registry lives *inside* each config folder, and `claude agents --json` reports only the folder its own environment points at. |

**So cross-account messaging is blocked by discovery, not by transport** — which is worth
weighing against the plan in [design.md](design.md#1-architecture-decided) to build a
second socket and a `hubctl` around it. Armada already enumerates every config folder
(`ClaudeConfigFolder.discoverAll()`), so it already holds the half that is missing.
Whether to drive the existing transport or run its own is a live design decision, not a
foregone one; the arguments for its own socket — a router that decides delivery, an audit
log, cross-*vendor* reach to Codex, which this protocol has no notion of — are unaffected
by this and are still the reason the plan exists.

`reply_across_default_dirs` is narrower than it sounds: it permits replying to a socket in
a *different recognised socket directory* (the XDG path versus the `/tmp` fallback), gated
on the peer's credentials being verified (`verifiedPeerPid`, `ownerUids`). It is not about
config folders.

**A non-session process cannot send on it. Tested 2026-09-13.** The inbox authenticates
the *connecting process*, not the bearer of a token: the server reads the peer pid off the
socket and looks it up against that pid's own session key, and drops a connection from a
pid with no registered session. Measured against a session started for the test — a
`SendMessage` from a sibling session landed twice in its output, while a direct connection
from a plain Python process, carrying that session's correct `peerToken` and the right
frames (`{"type":"auth","token":…}` then `{"type":"user","message":{"content":…}}`),
landed nothing. Same socket, same session, same minute.

That closes the route for anything that is not itself a Claude Code session — Armada
included — and is why [design.md](design.md#delivering-to-claude-code) keeps its own hook
path rather than riding this one. The key file is necessary but not sufficient; the pid is
the credential.

**Discovery is the boundary, not reach.** Also measured that day: `ListAgents` from a
session in `~/.claude-skitrust` listed 15 peers and none of the eight live sessions in
`~/.claude`, while `/tmp/cc-socks` held both folders' sockets side by side.

**Caution, and it is not theoretical.** This is a write channel into running agents: the
delivery verb injects a user message, and this document already records that Claude *acts*
on text delivered that way. A stray frame to a live session is an unintended instruction,
not a failed query. Probe a session's own socket with its own
`CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN`, both of which are in its
own environment, or read the binary instead.

**It is not where `ListAgents` gets busy/idle**, which this repo believed until
2026-09-12. The handler has no query verb, and the tool does not need one: it reads the
registry's `status` field, reports `statusUpdatedAt` as each agent's `lastActive`, and
takes `sock` from the same row only as an address to send to. `notify_when_idle` is a
subscription for the next transition, not a question about now.
[claude-code-sessions.md](claude-code-sessions.md#state) is corrected accordingly.

## Sender identity

### Claude Code (verified)

The env-vars docs: `CLAUDE_CODE_SESSION_ID` is "set automatically to the current session ID
in … stdio MCP server subprocesses … An MCP server subprocess retains the ID it was spawned
with." Hooks get the new ID after `/clear`; MCP servers don't.

Probe ([spike/identity/](spike/identity/run.sh)): an interactive session with one stdio MCP
server that logs its parent PID and environment, then `/clear`:

| | Before `/clear` | After `/clear` |
| --- | --- | --- |
| Probe MCP server | parent PID 90087, `CLAUDE_CODE_SESSION_ID` b0464368… | same process, unchanged |
| Session-list entry for PID 90087 | `sessionId` b0464368…, `name` `idprobe-7b` | `sessionId` 30db2809…, `name` `idprobe-7b` |

**Identify an MCP caller by its parent PID, looked up in the session list.** The
environment variable goes stale; the name stays the same.

### Codex

- `CODEX_SESSION_ID` and `CODEX_THREAD_ID` are only injected into shell commands'
  environments (`codex-rs/core/src/exec_env.rs`: "Exposes the shared root-session identity
  and harness version to shell commands").
- Stdio MCP servers get a restricted environment without them
  (`codex-rs/rmcp-client/src/utils.rs`, `create_env_for_mcp_server`).
- The MCP tool handler has a `call_id` (`codex-rs/core/src/tools/handlers/mcp.rs`), but
  nothing showed it reaching the server.
- **`PreToolUse` fires for MCP tools** (matchers like `mcp__filesystem__read_file`), with
  `session_id`, `turn_id`, `tool_name`, `tool_use_id` and `tool_input`. It can return
  `permissionDecision: "allow"` with `updatedInput`; "for MCP and other local function
  tools, `updatedInput` is the replacement arguments object". So a hook can add a one-time
  token that the MCP server forwards. **Not tested.**

## The VS Code extension

Checked in `~/.vscode/extensions/anthropic.claude-code-2.1.267-darwin-arm64/`:

- It bundles its own CLI at `resources/native-binary/claude`.
- It launches it with `--output-format stream-json --verbose --input-format stream-json`.
- It reads `CLAUDE_CONFIG_DIR` from its environment.
- `statusLine` appears in its code only in the settings schema.
- User settings include `claudeCode.environmentVariables` (environment for the Claude
  process) and `claudeCode.claudeProcessWrapper`.

## Gotchas when testing

- **Drive interactive sessions in a pty** (`script -q /dev/null claude …`). `-p` behaves
  differently for channels and async hooks.
- **Unset the child-session environment** before starting `claude` from inside another
  session. The full list is in
  [claude-code-sessions.md](claude-code-sessions.md#gotchas-when-driving-test-sessions).
- Dialogs (folder trust, development channels) need an Enter keystroke before the prompt.
  Send Enter on its own, not in the same burst as the prompt text.
- **`codex exec` waits on stdin** unless given `< /dev/null`.
- Don't write test servers into `~/.codex/config.toml`; pass `-c mcp_servers.<name>={…}`
  instead. The ChatGPT app rewrites that file on launch.
- Kill leftover hook processes after a test. Each rewake firing is its own process.
