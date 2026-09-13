# Codex: sessions, limits and hooks

Findings from 2026-09-09 and 2026-09-10 against Codex 0.152.0, extended 2026-09-11 against
0.153.4 while building Armada's Codex pane. Less complete than
[claude-code-sessions.md](claude-code-sessions.md): enough to design from, with the gaps
listed at the end.

**What 2026-09-11 settled**, all of it measured on this Mac and all of it now load-bearing
in the app — the detail is in the sections below:

| Question | Answer |
| --- | --- |
| Where are the titles? | `session_index.jsonl`, `thread_name`. Absent for subagents. |
| Which sessions are live? | `thread-writer-locks/<id>.lock` — a zero-byte flock held for the whole session |
| Where are the limits? | inside every rollout's `token_count`; no cache file exists |
| What identifies a session? | the filename uuid. `session_meta.session_id` **lies on a subagent** |

## The binary

- `/Applications/ChatGPT.app/Contents/Resources/codex` (`codex-cli 0.152.0`). Not on `PATH`.
- `codex exec` runs non-interactively. It **waits on stdin** unless given `< /dev/null`.
- `-c key=value` overrides config for one run without touching `config.toml`, for example
  `-c 'mcp_servers.board={command="node",args=["/abs/board-server.mjs"],env={BOARD_FILE="/abs/board.json"}}'`.
- Other useful flags: `--skip-git-repo-check`, `--sandbox read-only|workspace-write`.
- **Don't edit `~/.codex/config.toml` for tests.** The ChatGPT app rewrites it on launch.

### Forking a session (`codex-cli` 0.153.4, measured 2026-09-13)

`fork` is a **top-level subcommand**, not a flag: `codex fork [SESSION_ID] [PROMPT]`, described
as "Fork a previous interactive session (picker by default; use `--last` to fork the most
recent)". `codex resume` is its sibling and continues the original thread instead. There is
also a `/fork` command inside the TUI.

It needs a terminal, as the TUI always does:

```
$ codex fork 00000000-0000-4000-8000-000000000000 < /dev/null
Error: stdin is not a terminal
```

**Unlike Claude Code, Codex records where a fork came from.** The new rollout's `session_meta`
payload carries `forked_from_id` and `forked_from_ordinal_exclusive` — both confirmed in the
binary's serialized field names alongside `session_id`, `parent_thread_id` and `thread_source`.
So a fork's provenance is readable from disk here, and an app showing "forked from X" would be
reading a fact rather than guessing. Armada does not read it yet.

`--fork-turns` also exists ("Defaults to `all`. Use `none`, `all`, or a positive integer string
such as `3` to fork only the most recent turns"), which would allow forking a long session at a
point rather than at its end. Untested.

## Files

- `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`: one log per session.
  **The day directory is the local date**, not UTC: a session whose first event is
  `05:01:34Z` is filed under `2026/09/11` on a UTC+2 machine, matching the `T07-01-34` in
  its own filename. 418 of them here across six months; nothing prunes them.
- `session_index.jsonl`: `{"id", "thread_name", "updated_at"}` per line. The titles.
- `thread-writer-locks/<sessionId>.lock`: liveness. See below.
- `state_5.sqlite`, `thread_history_1.sqlite`: the ChatGPT app's own stores. Richer and
  deliberately unused — see below.
- `archived_sessions/`: 401 rollouts moved out of `sessions/`. An archived session is by
  definition not one to watch.
- `auth.json` holds credentials when the file store is used. Armada must never read it, and
  does not need to: `plan_type` arrives with the rate limits.

### The filename uuid is the session id — `session_meta.session_id` is not

Every rollout's `session_meta` carries both `id` and `session_id`. They are the same string
on an ordinary thread and **different on a spawned one**: all four `guardian_review`
rollouts on 2026-09-11 carry their own uuid in `id` and their *parent's* uuid in
`session_id`, identical to `parent_thread_id`.

So `session_id` gives a subagent the identity of the thread that spawned it. This is not
cosmetic — it cost three wrong rows in Armada, because SwiftUI's `List` keys on identity and
a subagent sharing its parent's id made the parent render the child's project and lose its
title. The filename uuid is `id`, and so is the lock file's name; that is what to key on.

`parent_thread_id` is the honest test for "is this a subagent": set on exactly those four,
null on every top-level thread. `thread_source` (`user` / `automation` / `guardian_review`)
says what started it. **`source` is not a string** — it is `"vscode"` on a normal thread and
the object `{"subagent":{"other":"guardian"}}` on a spawned one, so code reading it as a
string gets nil exactly where the interesting case is.

### Reading one cheaply

- **Head, 64KB.** The first line alone is ~22KB, because `session_meta` embeds the whole
  system prompt in `base_instructions.text` (18KB). `turn_context` — which carries `model`,
  `effort` and `approval_policy` — is around line 6, so 64KB reaches it.
- **Tail, 64KB.** Contained between 1 and 6 `token_count` events in every rollout measured,
  so one bounded read answers both "what is the state" and "what are the limits". No
  full-scan fallback is needed, unlike the Claude side's 64KB tail, which finds the title it
  wants only 16% of the time: Codex emits `token_count` after every turn rather than once
  early on.

## Which sessions are live

**There is no registry.** Claude Code writes `sessions/<pid>.json` per live session and
liveness is `kill(pid, 0)`. Codex writes nothing of the kind, and its processes are the
wrong shape for one anyway: the three `codex … app-server` processes running here are hosts
for the VS Code extension, each able to hold several threads, so "is a codex process alive"
answers nothing about any particular session.

What it does write is `~/.codex/thread-writer-locks/<sessionId>.lock`. Measured on
2026-09-11 by running `codex exec` and watching the directory:

- the file appears when the session starts writing its rollout and is **gone** about two
  seconds after `task_complete`;
- it is **zero bytes** — the liveness is the flock, not the contents. `lsof` showed
  `codex … 32u REG` holding it open, so there is no pid to read out of it;
- its name is the *session* id, matching the uuid in the rollout filename, so a lock maps to
  a session with no file read at all;
- `.coordination.lock` sits beside them and is not a session.

**Settled the same evening: the lock spans the session, not the turn.** `codex exec` could
not answer it — it exits with its turn, so the turn's end and the process's end always
coincide — but simply looking at the directory while the ChatGPT VS Code panel had a thread
open did: one interactive `codex` process held two locks, and the rollout for one of them
had ended its turn with `task_complete` **7 hours 20 minutes earlier**. The lock was still
held.

So the three states Armada shows are all real: lock + unfinished turn is working, lock +
`task_complete` is a session sitting open waiting for input, no lock is ended.

**A lock can exist with no rollout file at all.** The second of those two locks had none —
an open session that has never been prompted, the exact analogue of a Claude Code session
with a registry entry and no transcript. It follows that **walking `sessions/` does not
enumerate open sessions**: the locks directory is the only place a never-prompted session
exists, and anything that discovers sessions from rollout files alone will silently miss it.

Neither of these needed a probe script or a turn of quota. Both were sitting in
`ls -A thread-writer-locks/` the whole time, which is worth remembering before writing
another probe: this directory is a live registry, and reading it costs nothing.

A crashed process leaves its lock behind and nothing can tell that from a live one. With no
pid in the file there is no `kill(pid, 0)` equivalent. The honest alternative is
`flock(LOCK_SH | LOCK_NB)`, which Armada does **not** do: taking even a shared lock on a
file Codex expects to hold exclusively could make a real session fail to start.

### Turn boundaries are explicit

`task_started` and `task_complete` bracket every turn, so "working" needs no inference —
the opposite of the Claude side, where an unanswered `tool_use` is a guess the UI has to
hedge. The two vendors answer opposite halves of the same question: Claude Code says the
*session* is alive and leaves the turn to be inferred; Codex says the *turn* is over and
leaves the session to be inferred.

## Titles

`session_index.jsonl`, one `{"id", "thread_name", "updated_at"}` per line, 104KB and 747
lines here. A nicer answer than the Claude side's, which needs a tail-scan of every
multi-megabyte transcript.

**It is not complete, and the gap is not random.** 9 of the 13 rollouts written on
2026-09-11 have an entry; the 4 without are all `guardian_review` subagents, which are
spawned rather than started by a person and never get a generated name. A missing title
means "never named", not "the index is behind".

**`state_5.sqlite` is richer and deliberately unused.** Its `threads` table has 819 rows
with `rollout_path`, `cwd`, `archived`, `git_branch`, `tokens_used`, `preview` and more, and
it reads fine read-only (`file:…?mode=ro`) while the ChatGPT app holds it open in WAL mode.
Two reasons against depending on it: the filename carries a schema version that has already
been bumped to 5, and its `title` column is not a title — empty for every named automation
thread, and the *entire prompt* for the subagent ones, over 100KB in a single row.

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

Four things measured while building against it on 2026-09-11, each of which the Claude side
does differently:

- **`resets_at` is epoch seconds, an integer.** Claude's field of the same name and meaning
  is an ISO 8601 string with six fractional digits that needs `.withFractionalSeconds` to
  parse at all ([limits-accounts-and-terms.md](limits-accounts-and-terms.md#where-plan-limit-data-is)).
  Sharing a parser between the two is a bug waiting for whichever vendor changes first.
- **`used_percent` is a `Double`** (`61.0`), where Claude's `utilization` is an `Int`. A
  cast to `Int` quietly produces nil against `JSONSerialization`.
- **`plan_type`** (`"plus"`) is the only account identity available without opening
  `auth.json`. `limit_name`, `individual_limit`, `spend_control_reached` and
  `rate_limit_reached_type` sit beside it and are worth ignoring: read narrowly, as with
  Claude's cache, so an unrelated key changing shape cannot break anything.
- **There is no cache file, and that is the real difference.** Claude Code maintains
  `cachedUsageUtilization` as a document any reader can consult at any time. Codex states
  its limits only as a side effect of a turn, so the newest figures are exactly as old as
  the last turn anyone ran — and the 5-hour window they describe has often already rolled
  over by the time you look. Anything showing these must show their age, and say when the
  window they belong to no longer exists. Observed the same afternoon: a 61% reading from
  07:06 whose window reset at 12:00, sitting beside a 1% reading from 12:30.

To find the current figures: take the newest `token_count` across recent rollouts, tracked
by the event's own timestamp rather than the file's mtime.

## Context window

Measured 2026-09-12, while porting the Claude pane's context panel across. **Codex states
what Claude Code only implies.** Every `token_count` event carries `model_context_window`
beside the usage, so there is no equivalent of `ContextWindow`'s four-source resolution and
nothing to hedge: the number is recorded.

```json
"info": {
  "total_token_usage": { "input_tokens": 342314, "cached_input_tokens": 316544,
                         "output_tokens": 1029, "total_tokens": 343343 },
  "last_token_usage":  { "input_tokens": 43060,  "cached_input_tokens": 42752,
                         "output_tokens": 59,    "total_tokens": 43119 },
  "model_context_window": 258400
}
```

- **`total_token_usage` is cumulative, and it is the trap.** It adds up every request since
  the session began — 343,343 on a session whose window is 258,400. Read as "the context",
  it puts a session comfortably inside its window at 133% of it. `last_token_usage` is the
  one that describes the current prompt.
- **`input_tokens` includes `cached_input_tokens`**, the opposite of Claude's `usage`, where
  `input_tokens` excludes both cache figures and the three must be summed. So the fresh
  input is `input − cached − cache_write`. Getting this backwards double-counts the cached
  prefix, which on a warm turn is almost the whole prompt (42,752 of 43,060 here).
- **The first `token_count` is a long way in**: byte 332,171 of a 13.7MB rollout. So the
  opening figure — the analogue of `/context`'s fixed prefix, 29,120 tokens on that session
  — costs a much deeper read than the head parse, which is why Armada does it once per
  session and off the main actor.
- The last 64KB held 1–6 `token_count` events in every rollout measured, so one bounded tail
  read yields both the current occupancy and a growth series.
- **No compaction record.** Nothing in a rollout marks one; the only occurrences of the word
  on this Mac are inside system-prompt text. Claude's `compact_boundary` has no counterpart.

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

Answered on 2026-09-11, kept here so the change is visible: **where the titles are**
(`session_index.jsonl`, above) and **whether one process hosts several conversations** —
yes, `codex … app-server` is a host for the VS Code extension and three were running here,
which is why liveness is per-lock and never per-process.

Also answered, later the same day: **an idle interactive session does keep its writer
lock** (7h20m past `task_complete`), and **a `codex` process does hold locks for the threads
open in the VS Code panel** — an earlier `lsof` on three `app-server` processes showed none
only because no thread was open at the time.

Still open:

- **Is a lock ever left behind by a crash?** Nothing observed, and nothing could distinguish
  it from a live session if it were: the file is empty, so there is no pid to test. This is
  the one remaining soft spot under "live".
- Does an `updatedInput` rewrite from `PreToolUse` reach the MCP server?
- Do `Stop` blocks and `UserPromptSubmit` context deliver reliably in an interactive Codex
  session?
- Does anything prune `sessions/`, or does it grow forever? Six months and 418 files here
  with no sign of a sweep.
