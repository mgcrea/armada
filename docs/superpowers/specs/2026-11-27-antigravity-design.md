# Antigravity CLI support: design

Approved 2026-11-27. Findings behind it: [docs/antigravity-sessions.md](../../antigravity-sessions.md).

## Intent

Armada watches every coding-agent session on the Mac. Google's Antigravity CLI (`agy`) is now
installed here, and its sessions should show beside Claude Code, Codex and Grok Build: in the
sidebar, the menu bar panel and the MCP fleet tools, and be startable and resumable from saved
Projects.

## Goals (this round)

1. **Watch.** `AntigravityHome`, `AntigravityFiles`, `AntigravityWatcher`, `AntigravitySession`,
   `AntigravityAccount(s)`, `AntigravityPane`, beside the Grok files. Each vendor keeps its own
   types and vocabulary, as the app already does. States are Codex's and Grok's: `working`,
   `awaitingInput`, `ended`.
   - Live = some running `agy` process holds `presence/<id>.lock` open, found by listing the open
     files of `agy` processes (which yields the pid). Armada never takes the lock.
   - Run state, title, preview, folder and timestamps from `conversation_summaries.db`, opened
     read-only as `CodexQueue` opens Codex's database.
   - Tokens and the last activity from `transcript.jsonl`'s tail.
   - Listed while live, or for 12 hours after the last write, as Grok's are.
   - A home counts when it has `antigravity-cli/conversation_summaries.db` (Gemini CLI shares
     `~/.gemini`).
2. **Surfaces.** An Antigravity sidebar section and pane, the menu bar panel and its counts, the
   Settings account list. One home only, `~/.gemini/antigravity-cli`.
3. **Launch.** New session and resume from saved Projects, in the terminal or VS Code:
   `agy` in the project folder (no `--cwd` exists), `agy --conversation=<id>` to resume,
   `--model` when one is picked. No fork: `agy` has none.
4. **MCP.** Antigravity sessions in `armada_get_fleet`, `armada_get_session`,
   `armada_needs_attention` (which leaves `awaitingInput` out, as for Codex and Grok),
   `armada_read_transcript`; `armada_close_session` and `armada_focus_session` through the pid.
   `armada_start_session` can start one in a saved project. `armada_send_message` refuses.
5. **Docs and checks.** `docs/antigravity-sessions.md`; unit checks over fixture files (summary
   rows, transcript tails, presence matching); `DemoSeed` entries so screenshot captures keep
   working.

## Non-goals (later rounds)

- Plan limits: not on disk; needs its own research (`/quota`, the language server).
- Headless turns Armada runs, and messages to open sessions.
- Website copy and re-accepted screenshot goldens.
- The Antigravity desktop app's `~/.gemini/antigravity/` (not installed here).
- Add Account: `agy` has no measured home override (`ANTIGRAVITY_EXECUTABLE_DATA_DIR` is in the
  binary, untested), so a second account cannot be created yet.
- A `waiting` state: no permission prompt has been observed (the TUI defaults to `auto`).

## Anti-goals

- Taking `flock` on a presence lock, writing anything under `~/.gemini`, or opening the encrypted
  `.pb` files or the per-conversation `.db`.
- Merging the vendors behind a shared abstraction in this round.

## Approaches considered

- **Liveness from the summaries `status` alone.** Simple, but a killed `agy` may leave
  `RUNNING` behind and there is no pid for focus or close. Rejected as the only signal; kept as
  the working/idle signal for a live session.
- **`flock(LOCK_SH | LOCK_NB)` probe on the presence lock.** Exact, but contends with `agy`'s own
  lock at startup. Rejected, as for Codex.
- **Open-file scan of `agy` processes (chosen).** Read-only, exact, and gives the pid.

## Calls made for the builder

- Icon: an SF Symbol placeholder until a PNG asset is supplied, as `GrokIcon` came later.
- A session's display name: `title`, else `preview` trimmed, else the folder name.
- The transcript's `<USER_REQUEST>` wrapper is stripped and the metadata blocks dropped.
- A live session whose row reads `RUNNING` is `working`; any other live session is
  `awaitingInput`; anything not live is `ended`, whatever the row says.
