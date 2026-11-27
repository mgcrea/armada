# Antigravity CLI: sessions, state and hooks

Findings from 2026-11-27 against the Antigravity CLI 1.5.18 (`agy`, Google's coding CLI), from
two headless turns and one interactive turn driven in a background pty in a scratch repository,
a probe hook logging every event, and the guides `agy` installs under
`~/.gemini/antigravity-cli/builtin/skills/`. Less complete than [codex-sessions.md](codex-sessions.md):
the gaps are listed at the end.

**What 2026-11-27 settled:**

| Question | Answer |
| --- | --- |
| Where is the home? | `~/.gemini/antigravity-cli/`. `~/.gemini` is shared with Gemini CLI |
| Where are the transcripts? | `brain/<conversation id>/.system_generated/logs/transcript.jsonl`, plain JSONL |
| Which sessions are live? | The one whose `presence/<id>.lock` an `agy` process holds open, TUI **and** headless |
| Is the run state explicit? | Yes: `conversation_summaries.db`, `status` = `CASCADE_RUN_STATUS_RUNNING` / `_IDLE` |
| Where are titles? | The same row's `title`, written for TUI sessions; `preview` is the first prompt |
| Where are tokens? | Per model step in the transcript (`input_tokens`, `cache_read_tokens`, `output_tokens`) |
| Does Armada's Claude Code hook run inside `agy`? | **No.** It reads its own `hooks.json` files only |
| Where are the plan limits? | Nowhere on disk. The TUI has `/quota`; not reachable by Armada yet |

## The binary

- `~/.local/bin/agy`, a single 230 MB Go binary that runs its own language server per process
  (gRPC and HTTP on random localhost ports, with a CSRF token only its own agent shells get).
- Launching: `agy` (TUI), `agy -i "prompt"` (TUI with a first prompt), `agy -p "prompt"`
  (headless; `--output-format stream-json` streams steps), `--conversation=<id>` (alias
  `--resume`, `-r`), `-c/--continue`, `--model`, `--mode accept-edits|auto|plan`, `--effort`,
  `--dangerously-skip-permissions`, `--add-dir`. **No `--cwd` and no fork flag**: the session's
  folder is the process's working directory.
- The TUI's default mode is `auto` (the footer reads `auto ·`): the measured `run_command`
  ran without a prompt. A folder seen for the first time shows "Do you trust the contents of
  this project?" first; trusted folders are kept in `settings.json`'s `trustedWorkspaces`.
- On exit the TUI prints `Resume with -c (or command below): agy --conversation=<id>`.

## Files

```
~/.gemini/
  config/                         config.json (plugins), mcp_config.json, projects/*.json
  antigravity-cli/
    settings.json                 {"trustedWorkspaces": [...]}
    conversation_summaries.db     SQLite (WAL), one row per conversation: the index
    conversations/<id>.db         SQLite per conversation, protobuf blobs in `steps`
    brain/<id>/.system_generated/logs/
      transcript.jsonl            one JSON object per step, the readable transcript
      transcript_full.jsonl       the same, tool arguments unquoted
      chunks/…                    the same split in chunks
    presence/<id>.lock            zero bytes; held open while a process owns the conversation
    annotations/<id>.pbtxt        title:"…", for conversations that got one
    cache/last_conversations.json {"<cwd>": "<id>"}, the last conversation per folder (for -c)
    implicit/*.pb, *.pb           encrypted protobuf; Armada never opens them
    cli.log, log/cli-*.log        glog-format logs
```

A conversation id is a lowercase UUIDv4.

### `conversation_summaries.db`

```
conversation_summaries(conversation_id, title, preview, step_count, last_modified_time,
  workspace_uris, status, source, project_id, agent_name, parent_conversation_id,
  nesting_depth, not_fully_idle, killed, last_user_input_time, app_data_dir, raw_summary, …)
```

- `workspace_uris` is a JSON array of `file://` URLs, the session's folder first, for both
  headless runs. For the TUI conversation (`7bde737a-…`) it was the empty string, not even `[]`:
  the row names no folder. See "A conversation's folder" below.
- `status` is `CASCADE_RUN_STATUS_RUNNING` during a turn and `CASCADE_RUN_STATUS_IDLE` after it.
  The binary also knows `_BUSY`, `_CANCELING` and `_UNSPECIFIED`, not seen yet.
- `not_fully_idle` was 1 while running, 0 after.
- `title` was empty for both headless runs and `Run Command Probe Ok` for the TUI run.
  `preview` holds the first prompt's text.
- Times are text, `2026-11-27 07:56:39.575551+00:00`.
- `source` was empty for both kinds; headless and TUI rows look alike.

The database is in WAL mode and written by every `agy` process; Armada opens it read-only, the
way `CodexQueue` opens Codex's. Once the last `agy` has closed it, its `-wal` and `-shm` are gone,
and then a read-only open with Apple's SQLite succeeds but the first `prepare` fails with
`SQLITE_CANTOPEN` (14): a WAL read needs the shared-memory file, and a read-only connection may
not create it. With no `-wal` beside it Armada therefore opens `file:<path>?immutable=1`, which
read every row of a copy of the real file and created no file next to it; with a `-wal` there,
some `agy` may be writing, and the ordinary read-only open sees its writes. A read that fails
anyway (busy, or the file changing under an immutable read) keeps the previous scan's rows
rather than emptying the list.

### A conversation's folder

`agy` has no `--cwd`: a conversation's folder is the working directory of the process that ran
it. Armada takes the first of these that names one:

1. the row's `workspace_uris` (set for headless runs);
2. while a process holds the conversation, that process's working directory, read with
   `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO)` (`pvi_cdir`), resolved by the kernel
   (`/private/tmp`, not `/tmp`). Checked 2026-11-27 on a headless `agy -p` started in a scratch
   folder: the holder's directory was that folder;
3. `cache/last_conversations.json`, which names only each folder's **newest** conversation, so
   an earlier TUI conversation in the same folder is not in it;
4. the folder an earlier scan found, so one read off a live process outlives it (in memory:
   an Armada started after the TUI exited has only 1 and 3).

### `transcript.jsonl`

One step per line, with `step_index`, `source` (`USER_EXPLICIT`, `MODEL`), `type`, `status`
(`DONE`, `ERROR`, …), `created_at` (RFC 3339, UTC):

| `type` | Holds |
| --- | --- |
| `USER_INPUT` | `content`: the prompt inside `<USER_REQUEST>…</USER_REQUEST>`, then `<ADDITIONAL_METADATA>` and sometimes `<USER_SETTINGS_CHANGE>` blocks |
| `PLANNER_RESPONSE` | `model`, `input_tokens`, `cache_read_tokens`, `output_tokens`, `content` (the answer), `thinking`, `tool_calls: [{name, args}]` |
| `GENERIC` | a tool's result as text in `content`, or `error` when `status` is `ERROR` |

In `transcript.jsonl` each tool argument is a JSON-encoded string (`"\"echo probe-ok\""`);
`transcript_full.jsonl` has the raw value. A turn ends with a `PLANNER_RESPONSE` that has no
`tool_calls`.

## Which sessions are live

`presence/<id>.lock` appears when a conversation starts and stays after the process exits, so its
existence says nothing. While a process owns the conversation, `lsof` shows it open
(`agy 26944 … 76u REG … presence/33a760cd-….lock`) and an `flock(LOCK_SH | LOCK_NB)` fails; after
exit the same flock succeeds. That held for `agy -p` and for the TUI, also while the TUI sat
idle after its turn.

Armada does **not** take the flock to ask, for `CodexLocks`' reason: the lock exists to keep a
second process off a conversation, and Armada holding it at the wrong moment could stop a real
session from opening. It lists the open files of the running `agy` processes instead, which also
yields the pid.

## Hooks

`agy` reads `hooks.json` from a customization root (`.agents/hooks.json` in a workspace was
picked up; `~/.claude/settings.json` was not: the first launch logged `loaded 0 named hooks from
0 hooks.json file(s)`). Events: `SessionStart`, `PreToolUse`, `PostToolUse`, `PreInvocation`,
`PostInvocation`, `Stop`. Payloads are camelCase:

```
{"conversationId":"657374e8-…","hookEventName":"Stop","cwd":"…","workspacePaths":["…"],
 "modelName":"gemini-4-hydrogen-high","lastUserInput":"…","terminationReason":"NO_TOOL_CALL",
 "fullyIdle":true,"continuationActive":false,"executionNum":0,
 "transcriptPath":"~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript_full.jsonl",
 "artifactDirectoryPath":"~/.gemini/antigravity-cli/brain/<id>"}
```

The environment carries `ANTIGRAVITY_CONVERSATION_ID`. A `PreToolUse` hook that prints `{}`
**denies** the tool (`tool call denied by pre-tool hook`); it must print `{"decision": "allow"}`
(or `ask`) to let it through. Armada's delivery hook never runs here, and would exit at once if
it did, since the input carries `hookEventName`.

## Limits

Nothing on disk holds the allowance. The binary has a `/quota` slash command and
`RetrieveUserQuotaSummary` / `FetchQuotaStatus` calls with `quota_remaining` and
`quota_reset_time` per model, served by the per-process language server. `agy acp`'s
`initialize` advertises `_meta.antigravity.tier` and no quota method. Not reached yet.

## Open questions

- What a pending permission prompt writes (only reachable outside `auto` mode), and whether
  `status` then reads `_BUSY` or something else.
- Where the plan limits can be read from without being `agy`.
- Whether a `kill -9` leaves `status` at `RUNNING` (the lock goes with the process; the row
  may not).
- Subagent and swarm conversations: `parent_conversation_id` and `nesting_depth` exist, not
  measured.
