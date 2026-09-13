# What is built

Status on 2026-09-11: **a working macOS app**, covering the first two of v1's three
features. [design.md](design.md) still describes v1 in full and remains the plan; this doc
says what of it exists, what was deliberately left out, and the things a reader would
otherwise have to rediscover.

The app lives in `apps/apple`. `make run` builds and launches it; `make build` and
`make format-swift-check` are what CI runs.

## What it does

- **Sessions**, per account: every live Claude Code session with its title, project, age and
  inferred state, beside a detail pane that includes how full its context window is.
- **Usage**, per account: the 5-hour and 7-day windows with reset times, asked of the
  account directly through a headless `claude` and falling back to the cache on disk, with
  a badge saying which answered and how old it is.
- **Menu bar**: an accessory app (`LSUIElement`) with a popover summarising every account,
  and a template glyph that fills when anything is working.
- **New sessions**, per account: a New Session menu in each pane's header, listing the ten
  folders that account ran in last, and "New Session in <project>" on a session's
  right-click. It opens a terminal window with `claude` or `codex` running in that folder
  on that account. Armada writes a startup script and hands it to Terminal; it never owns
  the process, and the new session arrives through the watchers like any other.
- **Settings** on `swift-support-kit`'s shared scaffold, with an About pane and the Help
  menu.
- **Codex**, as a spike: a second sidebar section with its own pane, sessions and plan
  limits, read from `~/.codex`, a card in the global Usage pane beside the Claude accounts,
  and the same context panel in its detail pane. See below — it is real code and shipped
  behaviour, but it was written in one pass to find out what Codex makes possible, and it is
  the part most likely to want revisiting.

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
| `TranscriptTitle` | tail and head reads, the title, and the unanswered-`tool_use` state check |
| `TranscriptContext` | context totals, the growth series, the baseline and the compaction record |
| `ContextWindow` | how big the window is, and which of four sources said so |
| `UsageSnapshot` / `AccountIdentity` | the two halves of `.claude.json` |
| `ClaudeControl` | one control request to a headless `claude`, and its answer |
| `UsageProbe` | `get_usage` — the live figures, the way the VS Code extension gets them |
| `ContextProbe` | `get_context_usage` — the prefix breakdown a transcript cannot give |
| `ContextCompositions` | those breakdowns per project, cached for the life of the process |
| `ProcessAncestry` | what the kernel says about a pid: parents, start time, tty, exe path |
| `SessionHost` / `SessionHostLookup` | which app a session's process belongs to, cached |
| `FocusSession` | brings that app forward — see [focusing-sessions.md](focusing-sessions.md) |
| `HostWindow` | picks the app's window by title, when Accessibility is allowed |
| `SessionOrder` | how the session list is sorted and grouped — shared by both panes |
| `SessionSortMenu` | that choice as one menu, and the grouped list's section header |
| `NewSession` | writes a session's startup script and hands it to a terminal |
| `TerminalApp` | which terminals can be handed one, and which of them is chosen |
| `NewSessionLauncher` / `NewSessionMenu` | the click, its failure alert, and the menu |
| `RecentProject` | the folders an account has run in, for that menu |

The Codex half mirrors it, name for name, and shares the icon lookup (`VendorIcon`), the
usage views (`CompactMeter`, `UsageBar`, `UsageResetLine`), the list's sort and grouping
(`SessionOrder`, `SessionSortMenu`), and the context panel — `ContextPanel` takes figures
rather than a session, so `ContextSection` and `CodexContextSection` are two short adapters
over one renderer and cannot drift:

| Type | Holds |
| --- | --- |
| `CodexHome` | the one seam for a Codex home's paths; `discoverAll()` finds them |
| `CodexAccount` / `CodexAccounts` | a home plus its watcher; every home |
| `CodexWatcher` | FSEvents on `sessions/` and `thread-writer-locks/`, and the scan |
| `CodexRollout` | bounded head and tail reads of a rollout — meta, state, limits |
| `CodexLocks` / `CodexTitleIndex` | who is live; what things are called |
| `CodexSession` / `CodexSessionState` | one session, and the three states it can be in |
| `CodexContext` | `token_count` → `ContextReading`, the growth series, the opening figure |
| `CodexCLI` | where `codex` is — including inside the Codex app and the VS Code extension |

Session watching is per account and config watching is shared, which is not an
inconsistency: each folder has its own directory trees worth a dedicated stream, while the
`.claude.json` files are a handful of documents with no per-folder cadence to justify one.

## Things that will bite the next person

Each of these cost time here, and none is visible from the code that depends on it.

- **`Session.registry` is replaced on every rescan, not held from adoption.** Claude Code
  rewrites the registry file in place — `status`, `waitingFor` and `updatedAt` all move
  inside it — so a cached copy silently freezes the session's state and its last-activity
  time at the moment the row first appeared. `SessionWatcher.rescan` assigns the fresh
  one onto the surviving `Session`.
- **`SessionRegistry.waitingFor` is display text, not an enum.** Claude Code builds it
  from a per-dialog table and the set grows with each release. Render it; never branch on
  it. `status` is the closed vocabulary — see `SessionState.init(registryStatus:)`.
- **A session list group's id is the folder's `cwd`, never its name.** Two checkouts can
  both be called `api`, and a `ForEach` keyed on the title then runs two sections under
  one id — which renders as sections showing each other's rows and looks like a SwiftUI
  bug. `SessionGroup.id` is the path; the name is only the title.
- **`.tag` and `.id` on a session row are two different jobs.** `.tag` is what the list's
  selection and `.contextMenu(forSelectionType:)` read; `.id` is what
  `ScrollViewReader.scrollTo` matches, which is how the menu bar panel reaches a row a
  long way down. `List(_:selection:)` supplied the second for free out of `Identifiable`;
  the builder `List` the grouped list needs does not, so both are written out.
- **`SessionWatcher.rescan`'s sort is the baseline order, not the presented one.** It
  exists because `next` is a dictionary with no order, and it is also what the menu bar
  panel reads through `Accounts.allSessions` — the panel shows three of nineteen, so its
  three have to stay the newest three whatever the window is sorted by. The window layers
  `SessionOrder` on top rather than changing it.
- **A launched terminal window inherits nothing from Armada.** Measured 2026-09-13, with
  `CLAUDE_CONFIG_DIR` exported in the process that ran `open` and empty in the shell that
  came up: LaunchServices hands the request to Terminal, whose windows carry *its*
  environment. So every account decision has to be written into the script, and the user's
  own `.zshrc` runs before it. That is why `NewSession` emits `unset CLAUDE_CONFIG_DIR`
  for the default folder rather than leaving the variable alone — a profile that exports
  it for a second account would otherwise start every "Default" session on that account.
  The same asymmetry `ClaudeConfigFolder.usageJSON` records: exporting the default
  folder's own path is not a no-op, it makes the session look signed out.
- **A terminal only qualifies if opening a `.command` file *runs* it.** Terminal.app does,
  measured; the file must also be `chmod 700` or it opens in an editor instead. That is
  the whole of `TerminalApp.known`, and why Ghostty, WezTerm, kitty and Alacritty are not
  in it — they take a command as an argument (`-e`) rather than as a document, which is a
  second launch mechanism nobody here can test against. Adding one is a row plus a branch.
- **`codex` is not on `PATH` on a Mac that runs Codex.** It ships inside the Codex app
  (`ChatGPT.app/Contents/Resources/codex`, `codex-cli 0.153.4` here) and inside the VS
  Code extension (`~/.vscode/extensions/openai.chatgpt-<version>/bin/<arch>/codex`).
  `CodexCLI` looks in both, which is what keeps the New Session button real on a Mac with
  only one of them — `CodexIcon` already documents that either can be the only one.
- **The newest entries in Claude Code's `projects` map are scratchpads.** Four of the five
  newest here on 2026-09-13 were `/private/tmp/claude-501/…/scratchpad` directories: the
  per-session working space agents are handed. They exist, they sort first, and they are
  the last folder anyone wants a session in. `RecentProject` drops anything under the
  temporary directories — on location, not on the word "scratchpad", which is a
  convention and not Armada's to rely on.
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
- **Codex's `total_token_usage` is cumulative and its `input_tokens` includes the cached
  part** — both the reverse of Claude's `usage`, and both silent when confused. Reading
  `total_token_usage` as occupancy puts a session at 133% of a window it is inside; summing
  Codex's input and cached figures double-counts a prefix that is 99% of a warm prompt. See
  [codex-sessions.md](codex-sessions.md#context-window).
- **Occupancy and spend are different numbers, and only one vendor reports both.**
  *Occupancy* is `Session.context?.total` and `CodexSession.context?.total` — the size of the
  current prompt, which falls on compaction and re-counts the cached prefix every turn. That
  is what both panes show. *Cumulative spend* is `CodexSession.totalTokens`, and it is
  **Codex-only**: Claude Code records no equivalent anywhere on disk, and the spawned probe
  cannot supply it either. Do not put them in one column — a figure meaning occupancy in one
  pane and lifetime spend in the other is worse than a figure missing from one of them.
  Building a Claude cumulative would mean accumulating `TranscriptContext.series(…)` per
  request, which needs the formula settled first: excluding `cacheRead` measures new work,
  including it matches what the API bills, and Codex's own formula is known to match
  neither.
- **The three token figures must be summed.** `input_tokens` was **2** on a 389k prompt,
  because everything else was a cache read. Any one of them read as "the context" reports an
  empty session.
- **State is read, not inferred — since 2026-09-12.** The registry's `status`
  (`busy` / `waiting` / `idle`) is the authority, with `waitingFor` naming what a waiting
  session wants; write-recency and the unanswered-`tool_use` rule survive only as the
  fallback for a folder on a build older than 2.1.269. The field is right where the
  inference was most wrong, because it is written on the *transition*: a session ninety
  seconds into a tool call still reads `busy` instead of flipping to idle.
- **The messaging socket was never a state source**, whatever this repo said before
  2026-09-12: it has no query verb, and `ListAgents` reads `status` from the registry like
  everything else. Nothing in the app depended on the wrong belief, but it shaped the
  design discussion for two days.
- **A 64KB tail can hold no `assistant` entry at all.** A session writing file-history
  entries during a long edit burst pushed its last turn 140KB out of range. Context figures
  are held, never cleared, for the same reason `quotaHit` is.
- **`apiBlockIndex` repeats a request's `usage` object** across its blocks. Harmless for the
  newest reading, and it triples the sample count in a growth series — which is why
  `TranscriptContext.series` filters to block 0 and `newestReading` deliberately does not.
- **`message.model` never carries the `[1m]` suffix**, so it cannot tell a 1M session from a
  200k one. `settings.json` `.model` can (`"opus[1m]"`), and is the account default rather
  than the session's truth. See `ContextWindow`.
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
- **Plan limits are not a property of the sessions on screen.** They belong to the account,
  and the newest figures on disk are usually in a rollout the session scan has no reason to
  open — it is scoped to recent and locked sessions. Getting this wrong is silent: on
  2026-09-12, with nothing run for 17 hours, the pane showed figures a further day older
  than the newest that existed, because the only rollout in scope belonged to an idle
  session. `CodexWatcher.scan` now always tails the newest rollout in the tree.
  `UsageSnapshot.Source.sessionLog` is the other half of the same point: those figures do
  not decay the way a cache does, so they get their age shown and no staleness warning —
  only a rolled-over window voids them.

## Verifying it against reality

The app's numbers are checkable, and were checked, against the machine it runs on:

```bash
ls ~/.claude/sessions/*.json | wc -l                       # session count per folder
jq '.cachedUsageUtilization.utilization
    | {five_hour, seven_day}' ~/.claude.json               # the two windows
grep -o '"aiTitle":"[^"]*"' <transcript>.jsonl | tail -1   # the title, last match wins

# The context panel's figures, against the session it describes:
tail -c 65536 <transcript>.jsonl | grep '"type":"assistant"' | tail -1 \
  | jq '.message.usage | .input_tokens + .cache_creation_input_tokens
        + .cache_read_input_tokens'                        # "x / y tokens"
head -c 262144 <transcript>.jsonl | grep -m1 '"type":"assistant"' \
  | jq '.message.usage | .input_tokens + .cache_creation_input_tokens
        + .cache_read_input_tokens'                        # "Loaded at start"
grep -o '"compactMetadata":{[^}]*}' <transcript>.jsonl | tail -1

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
- **The prefix breakdown describes a comparable session, not the watched one.** The panel's
  totals are exact and per-session; the split of the fixed prefix into system prompt, tools,
  memory files and skills comes from `ContextProbe`, which spawns its own `claude` and asks
  `get_context_usage`. That answer is about the process it spawned — same project, same
  config, **fresh conversation** — so the prefix rows are "what a session started here now
  would load" and the `Messages` part of them is always zero.

  This corrects what this list said until 2026-09-12: that the route was "answerable only by
  whoever owns the session's pipes". A spawned process does answer it; the catch is subtler,
  and it is the reason the per-session figures still come from transcripts.
  [claude-code-sessions.md](claude-code-sessions.md#correction-2026-09-12-a-spawned-probe-answers-it-about-itself)
  has the measurement.

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
- **No "Focus in …" button on a Codex row.** The Claude one walks the session's pid up the
  process tree to the app that owns it; a Codex session has no pid anywhere on disk. The
  process holding its lock does know, but reading that means enumerating another process's
  file descriptors, which is a great deal of machinery for one button.
- **The growth projection is suppressed on an ended Codex session.** It would otherwise
  extrapolate a rate measured over 13 seconds yesterday into "~full in 18 minutes" for a
  session with no future. The Claude pane needs no such guard because its list is live by
  construction. Worth knowing that the same line on an *idle but live* session of either
  vendor is still projecting from history — it is right about the rate and assumes work
  resumes now.
- **The 12-hour recency window is a guess**, and it decides what the pane is. A Codex
  session that ended is still listed; one that ended 13 hours ago is not. There is nothing
  behind the number but "a working morning".
- ~~**"Waiting for input" may be unreachable.**~~ Settled, and then seen: the lock is held
  for the whole session, and the state showed up in the app on 2026-09-12 for an idle VS
  Code thread 24 hours old. `CodexSessionState.isBestEffort` is now `false` throughout —
  every Codex state is read rather than inferred, which is the substantive difference from
  the Claude side's `SessionState`.
- **Codex homes are not discovered by convention.** `~/.codex` plus `CODEX_HOME`, and
  nothing else: unlike Claude Code, Codex documents no `~/.codex-<name>` pattern, so
  scanning for one would be inventing a convention rather than following one. Someone with
  two Codex accounts in custom homes sees only the one this process was told about.
- ~~**No forecast on Codex meters.**~~ Withdrawn 2026-09-12. The blanket refusal was the
  right worry acted on in the wrong place: `UsageForecast` already declines a reading older
  than 10% of its window — 30 minutes for the session window, 16.8 hours for the weekly —
  and measures the rate to `asOf` rather than to `now`, so a reading that passes that guard
  is sound whatever produced it. Both Codex surfaces now offer the forecast and let the
  shared rule decide, which is also what stopped the Usage pane and the Codex header
  disagreeing about the same number.
- **The scan re-lists day directories on every event.** Bounded (≤8 directories, only files
  inside the window, only re-reading a file whose size changed, plus one tail read of the
  newest rollout) and never measured under a Codex session that is actually running.
- **Nothing reads Codex logs for a rate-limit refusal.** The Claude side corrects a stale
  cache with a `QuotaHit` mined from a transcript; the Codex equivalent has not been looked
  for, so a Codex window that a refusal has already closed keeps showing its last cheerful
  percentage until the next turn writes one.
- **`~/.codex/state_5.sqlite` is left alone.** It would give exact titles, archived state
  and git branches, at the cost of depending on a versioned private schema. That trade is
  worth revisiting only if the plain files stop being enough.
