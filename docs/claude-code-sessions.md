# Reading Claude Code sessions from disk

Findings from a spike run on 2026-09-10 against Claude Code 2.1.266 and 2.1.267, driven
through the VS Code extension. Written so another agent can pick the idea up cold.

## The idea

A native macOS app that lists every running Claude Code session with its **title** and
**state** (working, idle, and so on). The target use case is many concurrent sessions
opened through the VS Code extension; 16–17 were live during the spike.

## Verdict

- **Listing sessions: solved.** A live registry on disk prunes itself and updates in
  milliseconds.
- **Titles: solved, with two gaps.** The title VS Code shows is stored in the transcript,
  but resumed sessions and never-prompted sessions don't have one on disk.
- **State: has to be inferred, and the inference is wrong in one common case.** No state
  field exists anywhere on disk. Inferring it from transcript writes works for genuinely
  idle sessions but reports a session running a long tool call as idle.

**Everything here is undocumented Claude Code internals** except `claude agents --json`.
Formats can change in any release. Design the app to degrade, not crash.

**Check first:** Claude Code ships *agent view* for watching and steering many sessions
from one place (see the cross-session messaging docs). A menu-bar app is a different
surface, not a new capability, so try agent view before building.

## Data sources

| Source | Gives you | Stability |
| --- | --- | --- |
| `~/.claude/sessions/<pid>.json` | The live session list, with no state | Undocumented |
| `claude agents --json` | The same list minus `version`, `entrypoint`, socket path | Supported CLI |
| `~/.claude/projects/<enc-cwd>/<sessionId>.jsonl` | Title, plus write activity to infer state from | Undocumented |
| `/tmp/cc-socks/<pid>.sock` | Authoritative busy/idle (used by `ListAgents`) | Undocumented protocol, not reverse-engineered |

`claude agents` with no flag refuses to run without a TTY; `--json` is the machine-readable
form. `--all` adds completed background sessions.

> **Do not cross-check the two without checking `CLAUDE_CONFIG_DIR` first.** `claude agents
> --json` reports the folder *its own environment* points at, and a GUI app reports the one
> it resolved. On this Mac that is 5 sessions against 19 — **disjoint sets, both correct**,
> because the two config folders share nothing. Half an hour went into "why does the app
> disagree with the CLI" before the answer turned out to be that the terminal had
> `CLAUDE_CONFIG_DIR=~/.claude-skitrust` exported. See
> [limits-accounts-and-terms.md](limits-accounts-and-terms.md#multiple-accounts-on-one-mac).

## The session registry

One file per live session, named by PID:

```json
{
  "pid": 74885,
  "sessionId": "314456f8-311a-4973-a209-8f45d4e35b5b",
  "cwd": "/Users/olivier/Projects/apps/cupertino",
  "startedAt": 1788990958513,
  "procStart": "Wed Sep  9 21:55:58 2026",
  "version": "2.1.266",
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "kind": "interactive",
  "entrypoint": "claude-vscode",
  "pidDomain": "darwin",
  "messagingSocketPath": "/tmp/cc-socks/74885.sock",
  "name": "cupertino-74",
  "nameSource": "derived",
  "nameSince": 1788990958513,
  "bridgeSessionId": "session_015DCFfcBRDpvUYps8QoGJCm"
}
```

- Each file sits next to a `<pid>.<hash>.key` file (mode 0600). The app doesn't need it.
- **It prunes itself.** It held 35 files at one point and 16 an hour later, and every
  remaining PID was alive with a matching socket. Still check liveness defensively
  (`kill(pid, 0) == 0 || errno == EPERM`), since a crashed process may leave its file behind.
- **The file is deleted when shutdown starts**, about 0.5–2s before the process actually
  exits.
- `name` is derived from the project directory plus a short suffix (`bastion-ae`). It is
  not the human title.
- A session resumed in VS Code gets a **new** `sessionId` and a new registry row.

## Transcripts

Path: `~/.claude/projects/<cwd with every "/" replaced by "-">/<sessionId>.jsonl`, e.g.
`/Users/olivier/Projects/apps/bastion` becomes `-Users-olivier-Projects-apps-bastion`.
The encoding is internal, so fall back to searching `projects/*/<sessionId>.jsonl`. Subagent
work lands under `projects/<enc-cwd>/<sessionId>/…`.

Transcripts get large (1–13MB, over 5,000 lines). Never parse a whole one on every change.

Entry `type` values seen: `user`, `assistant`, `attachment`, `ai-title`, `last-prompt`,
`bridge-session`, `queue-operation`, `atis-latch`, `file-history-snapshot`,
`file-history-delta`, `mode`, `permission-mode`, `system`, `cost-state`.

**A session that has never been prompted has no transcript file at all.**

## Titles

The title VS Code displays is an `ai-title` entry:

```json
{"type":"ai-title","aiTitle":"Agent communication and MCP standards","sessionId":"…"}
```

This was confirmed against VS Code for one session: the displayed title matched the entry
exactly.

**Take the newest `ai-title`, not the first.** Titles get rewritten throughout a session.
Across the transcripts active in the prior 3 weeks, most titled ones carried many
`ai-title` entries (up to 267), and 289 had a title that *changed*. The typical pattern:

- a draft title around line 15 ("Bastion menu styling"),
- a refined title one line later ("Bastion menu Cupertino redesign"),
- then the refined title re-appended every ~15–25 lines.

Titles can also change late: "Cut a release" became "Continue" at line 47.

**Cost of reading it:** the newest `ai-title` sits a median **15.3KB** from the end of the
file (p90 29.6KB). A **64KB tail read finds it in 96%** of 553 titled transcripts. The
remaining 4% stopped re-appending titles long ago (p99 is 4MB from the end, max 13MB), so
fall back to a full scan for those, and cache the result by file size or mtime.

> **Correction, 2026-09-11: 96% is the wrong number for an app that watches live
> sessions.** Measured against the 19 sessions live on this Mac while building Armada, the
> tail read found the title in **3 of 19 — 16%**. The full scan is the common path, not the
> rare one.
>
> Not noise, and not a contradiction: the two populations differ. The 553 above were
> transcripts *active in the prior 3 weeks*, which is mostly short recent ones. A session
> that is live **right now** skews long-running — 9 to 16 hours old and 0.6–9.5MB here — and
> has therefore had plenty of time to stop re-appending its title. The measurement was
> right about its population; the population was the wrong one to design against.
>
> Cost of the fallback, on the same 19: **54MB and 141ms**, which is too much to do on the
> main thread at launch and grows with both session count and session age. Armada does the
> tail read inline and the full scan in the background, at most once per session, and shows
> the registry `name` until the title lands.

A new session got its first title **0.8s** after its first prompt was submitted.

### Gaps

- **Resumed sessions have no title on disk.** Resuming creates a new `sessionId` and a new
  transcript containing no `ai-title` and **no link back to the original transcript**:
  `leafUuid` values (in `last-prompt` entries) point into the file itself, and the copied
  history gets fresh message uuids, so they don't match the original. VS Code still shows
  the original title from somewhere. It isn't in plaintext in
  `~/Library/Application Support/Code/User/{globalStorage,workspaceStorage}`, so it may be
  held in memory and not flushed yet. **Open question.**
- **Never-prompted sessions** have no transcript, so no title.
- During the spike, 6 of 17 live sessions had no title: 1 never prompted, 2 confirmed
  resumes, and 3 whose transcripts contained no `ai-title` for reasons not established.
  Those 3 could also be resumes: the uuid check can't detect a resume, because copied
  history gets fresh uuids.

## State

No state field exists in the registry, `claude agents --json`, or the transcript format.
The options:

1. **Transcript-write recency (what the spike uses).** A write marks the session working;
   20s of silence marks it idle. Results:
   - A genuinely finished session went idle 21s after its last write. Correct.
   - **False idle during long tool calls.** Nothing is written while a tool runs, so a
     session busy with a 90-second command read as idle. One session flipped to idle 3
     times in 2.5 minutes this way.
   - Quitting a session produces a spurious *working* blip (a shutdown write) about 50ms
     before the registry file disappears.
2. **Untested mitigation:** if the newest transcript entry is an `assistant` message
   containing a `tool_use` block with no following `tool_result`, report **"running a
   tool"** instead of idle. This is the obvious next thing to verify.
3. **The messaging socket** `/tmp/cc-socks/<pid>.sock` is the authoritative busy/idle
   source (`ListAgents` reports "busy or idle right now" through it). The protocol wasn't
   investigated, and it needs the session's messaging token, so treat it as a last resort.
   The registry's `peerFeatures` includes `notify_idle`, and `SendMessage` has a
   `notify_when_idle` option, which hints at what the protocol carries.

## Measured latencies

From a compiled Swift FSEvents watcher (latency 0.05s, file-level events) on
`~/.claude/sessions` and `~/.claude/projects`:

| Event | Latency |
| --- | --- |
| Cold start: all 17 sessions listed with titles | 86ms |
| Session added, after its registry file is created | 12ms and 102ms (two runs) |
| Working, after a transcript write | 3–17ms |
| Removed, after Ctrl-C | 18ms and 64ms |
| First title, after the first prompt is submitted | 823ms |
| Idle, after the last write | 21s (20s threshold + 1s timer tick) |

Watch the directories. Don't poll. `fs.watch` in Node misses atomic renames on macOS, and
FSEvents with `kFSEventStreamCreateFlagFileEvents` doesn't.

## Suggested app shape

- **Registry:** an FSEvents stream on `~/.claude/sessions`. On any event, rescan the
  directory and decode each file. A file caught mid-write fails to decode and is picked up
  on the next event. A 1s timer sweeps PID liveness.
- **Titles:** an FSEvents stream on `~/.claude/projects`, routed to a session by the path
  component after the encoded cwd. On a transcript change, read the last 64KB for the
  newest `ai-title`; fall back to a full scan, cached by size.
- **State:** recency with hysteresis. Working immediately on a write, idle after ~20s of
  silence, and "running a tool" when the newest entry is an unanswered `tool_use` (once
  verified).
- **Fallback:** if the registry format stops decoding, use `claude agents --json`.
- **Resumed sessions:** show `name` + cwd until a title is found.

Bastion (`../bastion`) is a Swift 6 menu-bar app (`LSUIElement`) by the same author, a
reasonable source for the app shell.

## Context usage

Measured 2026-09-12 against 2.1.267, while building Armada's context panel.

### What the transcript records

Every `assistant` entry carries `message.usage`, and the three input figures sum to the
whole prompt:

```json
{"input_tokens":2,"cache_creation_input_tokens":796,"cache_read_input_tokens":388215,
 "output_tokens":914,"output_tokens_details":{"thinking_tokens":0},
 "cache_creation":{"ephemeral_1h_input_tokens":796,"ephemeral_5m_input_tokens":0}}
```

`input_tokens + cache_creation_input_tokens + cache_read_input_tokens` is the same sum
Claude Code's own status line calls `total_input_tokens`. **All three, always** —
`input_tokens` alone was 2 on that 389k prompt, so reading any one of them as "the context"
reports an empty session.

`apiBlockIndex` repeats the same `usage` object across every block of one `requestId`.
Harmless when taking the newest reading; **counts one request two or three times** when
building a series, which understates a growth rate by roughly two thirds.

### Three reads, three costs

| Figure | Where | Cost |
| --- | --- | --- |
| Context now | newest `assistant` in the tail | free — rides the existing 64KB tail read |
| Loaded before the first prompt | first `assistant` in the file | a head read; see below |
| Compaction | `system` / `compact_boundary` | needs the whole file |

**A 64KB tail can contain no `assistant` entry at all**, and this is not rare. Measured on
a live session on 2026-09-12: a burst of edits appended ~140KB of `file-history-snapshot`
and `file-history-delta` entries after the last turn, so both of the file's two assistant
lines sat at ~140KB in a 283KB file while the tail window began at 217KB. A reader that
clears its figures when the tail yields nothing blanks the panel of a session that is merely
busy. Hold the last reading instead — the next assistant turn is appended at the *end* of
the file, so the tail is guaranteed to carry it.

Related: a tail can also begin part-way through a request and hold only its blocks 1 and 2.
They carry the same `usage` object as block 0, so the current total should take whichever
block it finds; only a *series* needs the block-0 filter.

**The first `assistant` entry sits a median 61.6KB into the file** (p90 98KB, max 193KB
across 30 transcripts over 100KB); the preamble ahead of it is the queued prompt,
attachments and file-history entries. 256KB covered every one sampled.

**Compaction cannot be reached from a tail.** Across 40 transcripts over 500KB, only **4
had compacted at all**, and the newest boundary sat **160KB to 8.7MB from the end**. The
record:

```json
{"type":"system","subtype":"compact_boundary",
 "compactMetadata":{"trigger":"manual","preTokens":497468,"postTokens":17143,
   "cumulativeDroppedTokens":…,"durationMs":…,"preCompactDiscoveredTools":[…]}}
```

A compaction that happens *after* a one-off deep scan is still detectable with no re-read:
it is the only thing that makes the running total **fall** between two consecutive
readings, and both are in the tail.

### The context window size is not recorded

Neither is a model id precise enough to derive it. **`message.model` never carries the
`[1m]` suffix** — every distinct value across every transcript on this Mac was a bare id
(`claude-opus-5`, `claude-sonnet-5`, `claude-fable-5-1`), while the same machine's
`settings.json` held `"opus[1m]"`. Four sources, best first:

1. An `attachment` entry of type `model`, which is structured and exact:
   `{"type":"model","identity":{"modelId":"claude-opus-5[1m]","marketingName":"Opus 5 (1M context)"}}`.
   **Present in only 10 of 60 transcripts sampled**, and absent from the largest file on the
   machine — a bonus, not a mechanism.
2. The account's `settings.json` `.model`. Always inside the config folder, unlike
   `.claude.json`. It is the account default, so a session that ran `/model` has diverged.
3. `message.model` against a table, defaulting to 200k.
4. **The session's own usage, as a floor.** A reading above the resolved limit proves the
   window is larger, whatever the table said.

### What cannot be reconstructed, and the route that could

`/context`'s per-category breakdown is **assembled live and never serialized** — not to the
transcript, not to any file under `~/.claude`, not to any stream event. The system prompt
text and CLAUDE.md contents are never written to disk at all, so those two rows are beyond
any reader of the filesystem.

**But `get_context_usage` exists**, a control-protocol subtype beside `get_usage`:

```text
subtype: "get_context_usage", detail: ["summary","full"]?
  "Requests a breakdown of current context window usage by category."
  'full' counts each category with the token-count API; 'summary' answers from the last
  response's usage and local estimates without the per-category token-count calls.
```

Its response is richer than the TUI draws: `categories`, `totalTokens`/`maxTokens`,
`memoryFiles: [{path, type, tokens}]`, `systemPromptSections`, `skills.skillFrontmatter`,
`mcpTools`, `agents`, and a `messageBreakdown` (tool calls by type, attachments by type,
unattributed). The SDK exposes it as a plain `getContextUsage(…)` with **no**
`EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` warning, unlike `get_usage`.

**It is unreachable from a watcher, and the reason is structural.** `get_usage` answers
standalone because rate limits are account-scoped; context is session-scoped state in
another process's memory, and the subtype takes no session id. The builder has three
callers:

- the **local stream-json handler**, which answers for the session whose stdin and stdout
  the caller owns — VS Code's, not ours;
- the **Remote Control bridge** (`[bridge:repl]`), gated on *"This session is outbound-only.
  Enable Remote Control locally to allow inbound control."*, with the inbound-allowed set
  `{initialize, file_suggestions, read_file, get_workspace_diff, get_context_usage,
  get_usage, mcp_status}`. It blanks `memoryFiles` unconditionally;
- the interactive `/context` TUI, which on a thin client is *itself* implemented as a
  `get_context_usage` control request.

`claude -p '/context'` is real (a headless-only `type:"local"` command, resolved with no
model call) and equally useless here: it reports the fresh process, not the session being
watched.

**So any session Armada launched itself would yield the exact breakdown for free.** That is
a genuine argument for the launching side of a decision `design.md` left open, and it was
not available when that decision was framed.

## Open questions, in priority order

1. Does the unanswered-`tool_use` rule fix false idle? Verify with a session running a
   long command.
2. **Does `/tmp/cc-socks/<pid>.sock` carry `control_request`?** If it does,
   `get_context_usage` becomes reachable locally and the whole disk-reading approach above
   is superseded by an exact one. It needs the session's messaging token and the protocol
   is unreversed, so this is the same last resort as question 3 below — but the prize is
   now much larger than busy/idle.
3. Where does VS Code keep a resumed session's title? That decides whether resumed
   sessions can ever show one.
4. Is the messaging socket protocol simple enough to read busy/idle directly, and is that
   worth coupling to?
5. Which states are worth showing beyond working/idle, such as waiting for a permission
   prompt? Permission waits weren't tested.

## The spike code

`docs/spike/` holds the throwaway prototype the numbers came from:

- `SessionWatch.swift` is the FSEvents watcher, with registry rescan, title read, state
  inference, and benchmark. **Its title read keeps the first `ai-title`, which is wrong**
  (see Titles). Build with
  `swiftc -O -swift-version 5 SessionWatch.swift -o session-watch`; it logs `ADDED`,
  `WORKING`, `TITLED`, `IDLE` and `REMOVED` lines to stdout.
- `drive.sh` launches a real interactive session in a pty, prompts it, then quits it, and
  writes wall-clock marks to `marks.log` for comparing against the watcher's log.

### Gotchas when driving test sessions

- **Send Enter as a separate keystroke.** A trailing `\r` in the same burst as long
  pasted text lands inside the paste and never submits.
- **Unset the child-session environment.** A `claude` launched from inside another Claude
  Code session inherits `CLAUDE_CODE_CHILD_SESSION=1` (and a messaging socket and token)
  and **skips saving its transcript**. `drive.sh` unsets `CLAUDE_CODE_CHILD_SESSION`,
  `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_SESSION_ID`,
  `CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_AGENT_SDK_VERSION` and
  `CLAUDE_CODE_EXECPATH`.
- **The harness refuses a foreground `sleep`**, so a long tool call can't be staged that
  way. Use a genuinely slow command.
- `-p` (non-interactive) runs behave differently from interactive ones. For example,
  channels aren't polled in `-p` mode. Test in a pty.

## Related findings from the same investigation (2026-09-09)

- **Sessions can already message each other.** `ListAgents` and `SendMessage` are built in
  and on by default. They work across local sessions, Remote Control sessions on other
  machines, and cloud sessions. A message arrives as plain text at the receiver's next tool
  round.
- **Channels push external events into a running session.** An MCP server declaring
  `capabilities.experimental["claude/channel"]` and emitting
  `notifications/claude/channel` is delivered live, with no polling. Interactive sessions
  only, research preview. A custom channel needs
  `--dangerously-load-development-channels server:<name>`, and **must not** also be passed
  to `--channels`. **The receiving agent treats channel content as untrusted data**: it
  reads the event but won't follow instructions inside it.
- **Plain MCP `notifications/message` never reaches the model**, in Claude Code or Codex.

## Update from the design work (2026-09-10)

- **Hooks give documented state, so inferring it from write recency becomes a fallback.**
  Hooks live in `settings.json`, which the CLI and the VS Code extension share. Once
  installed, `PermissionRequest` fires the moment approval is requested; `Notification`
  reports `permission_prompt` (after about 6s), `idle_prompt`, `agent_needs_input` and
  `agent_completed`; and `SessionStart`, `UserPromptSubmit`, `Stop` and `SessionEnd` cover
  the lifecycle. Each carries `session_id` and `transcript_path`. That answers how to detect
  permission waits (open question 4) and tells "running a tool" apart from "waiting for
  approval" for sessions with hooks. Transcript inference is still needed for sessions that
  started before the hooks were installed.
- **A snapshot of transcript tails supports the rule in open question 1.** Across 14 live
  sessions, the last user or assistant entry was `stop_reason: end_turn` for sessions idle
  for hours, and an unanswered `tool_use` for sessions that were working. One session had
  sat on an unanswered `tool_use` for 10.5 hours, almost certainly a pending approval.
- **An `asyncRewake` hook can wake an idle session, and Claude acts on what it delivers,**
  unlike channel content. Verified in the terminal and in stream-json mode. See
  [reaching-agents.md](reaching-agents.md).
- The app built on these findings is designed in [design.md](design.md).
