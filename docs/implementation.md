# What is built

Status on 2026-09-11: **a working macOS app**, covering the first two of v1's three
features. [design.md](design.md) still describes v1 in full and remains the plan; this doc
says what of it exists, what was deliberately left out, and the things a reader would
otherwise have to rediscover.

The app lives in `apps/apple`. `make run` builds and launches it; `make build` and
`make format-swift-check` are what CI runs.

## What it does

- **Sessions**, per account: every live Claude Code session with its title, project, age and
  inferred state, plus a detail inspector.
- **Usage**, per account: the 5-hour and 7-day windows with reset times and a staleness
  badge.
- **Menu bar**: an accessory app (`LSUIElement`) with a popover summarising every account,
  and a template glyph that fills when anything is working.
- **Settings** on `swift-support-kit`'s shared scaffold, with an About pane and the Help
  menu.
- **Codex**, as a spike: a second sidebar section with its own pane, sessions and plan
  limits, read from `~/.codex`. See below — it is real code and shipped behaviour, but it
  was written in one pass to find out what Codex makes possible, and it is the part most
  likely to want revisiting.

Not built, and all of it deliberate: **messaging** (v1's third feature), hooks, `hubctl`,
the Unix socket, the MCP surface, and anything that writes to a vendor's config. This app
only ever reads `~/.claude*` and `~/.codex`.

## The shape

The **account** — one Claude config folder — is the unit everything hangs off, because it is
the unit the data is organised by. Two folders share nothing: separate sessions, separate
transcripts, separate rate limits.

| Type | Holds |
| --- | --- |
| `ClaudeConfigFolder` | the one seam for a folder's paths; `discoverAll()` finds them |
| `Account` | a folder plus its identity, usage and session watcher |
| `Accounts` | every account; one timer and one FSEvents stream for the config files |
| `SessionWatcher` | one per account — FSEvents on its `sessions/` and `projects/` |
| `SessionRegistry` | decodes `sessions/<pid>.json` |
| `TranscriptLocator` | session → transcript path, with the encoding fallbacks |
| `TranscriptTitle` | tail read for the title, and the unanswered-`tool_use` state check |
| `UsageSnapshot` / `AccountIdentity` | the two halves of `.claude.json` |

The Codex half mirrors it, name for name, and shares only the icon lookup (`VendorIcon`)
and the usage views (`CompactMeter`, `UsageBar`, `UsageResetLine`):

| Type | Holds |
| --- | --- |
| `CodexHome` | the one seam for a Codex home's paths; `discoverAll()` finds them |
| `CodexAccount` / `CodexAccounts` | a home plus its watcher; every home |
| `CodexWatcher` | FSEvents on `sessions/` and `thread-writer-locks/`, and the scan |
| `CodexRollout` | bounded head and tail reads of a rollout — meta, state, limits |
| `CodexLocks` / `CodexTitleIndex` | who is live; what things are called |
| `CodexSession` / `CodexSessionState` | one session, and the three states it can be in |

Session watching is per account and config watching is shared, which is not an
inconsistency: each folder has its own directory trees worth a dedicated stream, while the
`.claude.json` files are a handful of documents with no per-folder cadence to justify one.

## Things that will bite the next person

Each of these cost time here, and none is visible from the code that depends on it.

- **`INFOPLIST_KEY_LSUIElement = YES`** is what makes this a menu bar app. Without it there
  is a permanent Dock icon and `DockPresence` is meaningless.
- **Three package products**, each needing *both* a product dependency and a Frameworks
  build file: `SupportKit`, `SupportKitUI`, `SupportKitSettings`. Wrong wiring compiles
  clean until the first `import`. Pinned from **1.1.1** — in 1.1.0 the settings sidebar
  draws and highlights but selects nothing.
- **The pbxproj was generated once and committed as a normal file.** There is no generator
  in the repo on purpose: the fleet's `pbxproj_add_product.py` edits it in place, and a
  regenerating script would clobber those edits. No sibling repo has one either.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** means a type is main-actor-isolated unless
  it says otherwise. `TranscriptTitle`, `UsageSnapshot` and `AccountIdentity` are
  `nonisolated` so their file I/O is real background work; dropping that keyword silently
  puts 54MB of transcript reading back on the thread drawing the window.
- **`resets_at` needs `.withFractionalSeconds`** — see
  [limits-accounts-and-terms.md](limits-accounts-and-terms.md#where-plan-limit-data-is).
- **`sessions/` holds `<pid>.<hash>.key` files** beside the registry JSON. Scan `*.json` or
  the session count roughly doubles.
- **`startedAt` is epoch milliseconds**, an `Int`, not a date string.
- **A persisted id must not carry a trailing slash.** `URL.path` on a URL built with
  `directoryHint: .isDirectory` ends in `/`; that leaked into the remembered sidebar
  selection and made a stored value silently fail to match.
- **The sidebar's stored selection needs a vendor prefix.** Claude account ids and Codex
  home ids are both absolute paths, so `SidebarItem` stores Codex as `codex:<path>`.
  Without it `~/.claude` and `~/.codex` are two rows with one stored form.
- **A Codex subagent's `session_meta.session_id` is its parent's id.** Key on the rollout
  filename instead. This is written up in
  [codex-sessions.md](codex-sessions.md#the-filename-uuid-is-the-session-id--session_metasession_id-is-not);
  it is repeated here because the symptom was three rows in a SwiftUI `List` rendering
  another row's content, which looks like a view bug and is not one.
- **Codex has no session registry and no usage cache.** Liveness is a zero-byte flock in
  `thread-writer-locks/`, and the plan limits exist only inside `token_count` events in
  session logs. Both consequences are visible in the UI on purpose: the Codex list is
  "recent" rather than "live", and its header leads with how old the figures are.

## Verifying it against reality

The app's numbers are checkable, and were checked, against the machine it runs on:

```bash
ls ~/.claude/sessions/*.json | wc -l                       # session count per folder
jq '.cachedUsageUtilization.utilization
    | {five_hour, seven_day}' ~/.claude.json               # the two windows
grep -o '"aiTitle":"[^"]*"' <transcript>.jsonl | tail -1   # the title, last match wins

# Codex. The pane's row count, its ordering, and its figures:
find ~/.codex/sessions -name '*.jsonl' -newermt "$(date -d '12 hours ago' -Iseconds)" | wc -l
for f in ~/.codex/sessions/2026/*/*/*.jsonl; do tail -1 "$f" | jq -r .timestamp; done | sort -r
ls -A ~/.codex/thread-writer-locks/                        # live sessions, minus the
                                                           # .coordination.lock
tail -c 65536 <rollout>.jsonl | grep '"token_count"' | tail -1 \
  | jq .payload.rate_limits                                # the figures the header shows
```

The `date -d` above is GNU; on a stock macOS `date` it is `-v-12H`.

Two traps when doing this. `claude agents --json` reports whatever `CLAUDE_CONFIG_DIR` its
shell has, so it will disagree with the app for a good reason. And `kill(pid, 0)` proves a
pid exists, not that it is Claude — `ps -p <pid> -o comm=` is the honest check.

To exercise the degraded paths without touching real data, point the app at a fixture:

```bash
CLAUDE_CONFIG_DIR=/tmp/fake open apps/apple/.build/Build/Products/Debug/Armada.app
```

A truncated registry file is skipped, a `.claude.json` with no `cachedUsageUtilization`
shows an empty usage strip, and neither crashes.

## Known gaps

- **`armada.mgcrea.io` does not resolve**, so the Help menu's Support and Feedback items are
  dead links until the site ships. One line in `Support.swift`.
- **No tests**, and so no `make test`. A target that ran nothing would be worse than none.
- **Folder discovery is not watched**: a config folder created while Armada is running does
  not appear until relaunch.
- **State is inference, not truth.** Write-recency plus the unanswered-`tool_use` rule, which
  `claude-code-sessions.md` still files as unverified and which cannot tell a running tool
  from one waiting for approval. The UI marks it best-effort. Hooks would settle it, and
  hooks are out of scope.

### Where the Codex spike is thin

Everything here is known, none of it is hidden by the UI, and all of it is a judgement call
someone may want to make differently.

- **A locked session with no rollout file is invisible.** Found on 2026-09-11, after the
  pane was built: a lock can exist for a session that has been opened and never prompted,
  and `CodexWatcher.scan` discovers sessions by walking `sessions/` — so that session
  appears nowhere, even though it is the most live thing on the machine. The Claude side
  handles the same case (`Session.untitledReason` says "Never prompted") because its
  registry, not its transcripts, is what it enumerates. The fix is to seed the scan from
  `CodexLocks.liveSessionIDs` as well as from the day directories, and to let a
  `CodexSession` exist with no `CodexSessionMeta` — perhaps 15 lines in `scan` and `apply`,
  plus a row that says "Not started yet". Not done here: the file was being edited
  concurrently, and this is worth doing deliberately rather than racing it.
- **The 12-hour recency window is a guess**, and it decides what the pane is. A Codex
  session that ended is still listed; one that ended 13 hours ago is not. There is nothing
  behind the number but "a working morning".
- ~~**"Waiting for input" may be unreachable.**~~ Settled the same day: the lock is held for
  the whole session, so the state is real. The code comments in `CodexLocks` and
  `CodexSessionState` still hedge on this and should be tightened.
- **Codex homes are not discovered by convention.** `~/.codex` plus `CODEX_HOME`, and
  nothing else: unlike Claude Code, Codex documents no `~/.codex-<name>` pattern, so
  scanning for one would be inventing a convention rather than following one. Someone with
  two Codex accounts in custom homes sees only the one this process was told about.
- **No forecast on Codex meters.** `UsageForecast` projects from a reading that tracks the
  window, which Codex does not provide.
- **The scan re-lists day directories on every event.** Bounded (≤8 directories, only files
  inside the window, only re-reading a file whose size changed) and never measured under a
  Codex session that is actually running.
- **`~/.codex/state_5.sqlite` is left alone.** It would give exact titles, archived state
  and git branches, at the cost of depending on a versioned private schema. That trade is
  worth revisiting only if the plain files stop being enough.
