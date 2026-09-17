# What is built

Status on 2026-09-11: **a working macOS app**, covering the first two of v1's three
features. [design.md](design.md) still describes v1 in full and remains the plan; this doc
says what of it exists, what was deliberately left out, and the things a reader would
otherwise have to rediscover.

The app lives in `apps/apple`. `make run` builds and launches it, and `make test` runs every
suite; what CI gates on is listed in the [README](../README.md#working-on-it).

## What it does

- **Sessions**, per account: every live Claude Code session with its title, project, age and
  inferred state, beside a detail pane that includes how full its context window is.
- **Usage**, per account: the 5-hour and 7-day windows with reset times, asked of the
  account directly through a headless `claude` and falling back to the cache on disk, with
  a badge saying which answered and how old it is.
- **Menu bar**: an accessory app (`LSUIElement`) with a popover summarising every account,
  and a template glyph that fills when anything is working.
- **New sessions**, per account: the detail pane with nothing selected is an account
  overview — the six folders that account ran in last, one click each, a folder picker,
  and a tally of what the account's sessions are doing. "New Session in <project>" is also
  on a session's right-click. Starting one opens a terminal window with `claude` or
  `codex` running in that folder on that account: Armada writes a startup script and
  hands it to Terminal, never owns the process, and the new session arrives through the
  watchers like any other.
- **Projects**: folders saved across accounts, in a pane of their own under Usage — the list
  on the left, the selected project on the right. A project starts a session on its default
  account or any other, lists the live sessions whose folder is the
  project's or below it (the deepest saved project wins), and renames, moves or removes the
  project in place. Saved to `projects.json` beside the usage history. Starting a Claude Code
  session in a saved project marks its folder trusted in that account's `.claude.json`
  (`ClaudeTrust`), so the session opens without the trust dialog; it is the one write to a
  vendor's folder. The pane also shows the tokens spent there, from a ledger the usage index
  builds in the background over every transcript and rollout (`usage-index.sqlite`).
- **Supervisor**, opt-in: an MCP server on `127.0.0.1` (Settings ▸ Supervisor) with seven read
  tools (one, `armada_wait`, a long poll) and, behind its Allow writes switch, `armada_start_session` and `armada_close_session`; and
  a Start Supervisor Session button that opens an ordinary Claude Code session with that
  server attached, its read tools pre-allowed (never the start or close tool), and a brief. The session is the chat: ask it
  which sessions need you, what one is doing, or how much plan is left.
- **Voice**, opt-in (Settings ▸ Voice): a global shortcut opens a card at the top of the
  screen, Parakeet v3 (or Apple's dictation until Parakeet is downloaded) turns the question into
  text on the Mac, a headless `claude` Armada runs on
  the chosen account answers through the same MCP server (allowed `armada_start_session` only
  while Allow writes is on, after confirming out loud), and the reply is spoken a sentence at
  a time, in a system voice or in Kokoro once downloaded. Press or hold, chosen in Settings. That `claude` has no built-in tools and only the six
  read tools, continues the conversation for follow-ups, and closes after five idle minutes.
- **Settings** on `swift-support-kit`'s shared scaffold, with an About pane and the Help
  menu.
- **Codex**, as a spike: a second sidebar section with its own pane, sessions and plan
  limits, read from `~/.codex`, a card in the global Usage pane beside the Claude accounts,
  and the same context panel in its detail pane. See below — it is real code and shipped
  behaviour, but it was written in one pass to find out what Codex makes possible, and it is
  the part most likely to want revisiting.

Not built, and all of it deliberate: **messaging** (v1's third feature), hooks, `hubctl`,
the Unix socket, the messaging MCP surface (`send_message`, `list_agents`), and anything that
writes to a vendor's config. This app
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
| `NewSessionLauncher` | the click, and the alert when a launch fails |
| `AccountOverview` / `CodexOverview` | the detail pane with nothing selected, per vendor |
| `NewSessionSection` / `SessionTallySection` | the two halves both overviews are built from |
| `RecentProject` | the folders an account has run in, for that menu |
| `ProjectPath` | folder matching on whole path components, and which saved project a `cwd` belongs to |
| `Project` / `ProjectsFile` | a saved folder and the agent it starts; `projects.json`, versioned |
| `ProjectStore` | the saved list, each folder's symlink-resolved spelling, the live account behind an agent |
| `ProjectsPaneView` / `ProjectRow` / `ProjectDetail` | the Projects pane: the list, the selected project, and "Add to Projects" |
| `UsageLines` | one transcript or rollout line → the tokens it spent |
| `UsageIngest` | whole lines of a chunk → contributions, a cursor, and the dedupe claims |
| `UsageLedger` | `TokenTally`, `StableHash`, `LocalDay`, and the snapshot the app holds |
| `UsageIndexer` / `UsageDatabase` | the background pass and its SQLite ledger |
| `UsageIndex` | when a pass runs, and the snapshot and progress the views read |
| `ProjectStats` / `ProjectUsageSection` | the ledger rolled up into projects, and how the pane shows it |
| `ProjectsSnapshot` (package) / `ProjectsBridge` | `armada_get_projects`'s second hop: stored projects, ledger and live sessions copied in one main-actor hop, rolled up after it |
| `SessionStarter` (package) / `SessionStarterBridge` | `armada_start_session`'s door: one main-actor hop that re-checks the project, resolves the account, throttles and launches; mints the `--session-id` for a terminal launch, and for `resume` refuses a live or recently written session and finds the account and folder from the transcript |
| `MessageSender` (package) / `MessageSenderBridge` | `armada_send_message`'s door: checks the switch, the session and its account's hook on the main actor, writes the labelled message into the session's inbox, and watches it for three seconds to say delivered or why it is queued |
| `MessageHook` | the Stop hook's script and command, and the byte-level edit that adds or removes it in a `settings.json`; `make unit` runs the real script |
| `MessageDelivery` / `SessionInbox` | Settings ▸ Supervisor ▸ Deliver messages: writes the script, syncs every account's `settings.json` to the switch at launch and on change; the inbox a message is written to, and whether a hook is listening |
| `SessionCloser` (package) / `SessionCloserBridge` | `armada_close_session`'s door: one main-actor hop that re-checks the session's state and ties its pid to it by start time, then `SIGTERM`, a wait, and `SIGKILL` for one still there |
| `LaunchScript` | the startup script's plain-text parts: shell quoting, and an opening message read from its file |
| `ArmadaMCP` (package) | the ten tools, `FleetSource` and its snapshot types, `SessionStarter`, `SessionCloser`, the transcript condenser; `make -C apps/apple test` |
| `FleetBridge` | the one main-actor door from a tool call to `Accounts` and `CodexAccounts` |
| `MCPServerController` | the loopback listener, its Keychain token, and when it runs |
| `SupervisorPane` | Settings ▸ Supervisor: the switch, the port, the supervisor launch, client snippets |
| `SupervisorMCPConfig` | the 0600 MCP configuration both supervisors are started with |
| `ArmadaSupervisor` (package) | voice's decisions with no audio or UI: stream-json decoding, the voice `claude`'s arguments, sentence chunking and Kokoro's phoneme splitting, the stored voice choice, the silence rule, the shortcut reducer; `make -C apps/apple test` |
| `VoiceController` | voice's coordinator: performs `VoiceTurn`'s effects, holds what the card shows, starts and resumes the voice `claude` |
| `VoiceCapture` | the microphone and the recognizer for one question: Parakeet, transcribed again every half second, or `DictationTranscriber` |
| `ArmadaSpeech` (package, dynamic framework) | `ParakeetRecognizer` and `KokoroSynthesizer`: FluidAudio's Parakeet v3 and Kokoro-82M, their offline loads and their downloads |
| `SpeechModelStore`, `VoiceRecognitionSection` | whether each model is on the Mac and loaded, and Parakeet's Download button and its progress (Kokoro's is in `VoicePane`) |
| `SupervisorProcess` | the headless `claude` voice owns: frames to stdin, stream-json events back, closed when idle |
| `VoiceShortcut`, `ShortcutRecorder` | the one global chord through `RegisterEventHotKey`, and the Settings control that records it |
| `VoiceOverlay`, `Speaker` | the non-activating card at the top of the screen, and the speaker: a system voice or Kokoro per sentence, in order |
| `VoicePane` | Settings ▸ Voice: the switch, the shortcut, the account, the voice and a button to hear it |

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
- **A project matches on whole path components and on its resolved path.** `/work/armada`
  is a string prefix of `/work/armada-old`, so `ProjectPath.contains` decides at a `/`. And
  the open panel can hand back a symlinked path while Claude Code records the resolved `cwd`,
  so `ProjectStore` keeps both spellings, resolved with `realpath(3)`:
  `resolvingSymlinksInPath` also strips a leading `/private`, which turns the `/private/tmp`
  a session records into a `/tmp` that matches nothing.
- **A message can be in two transcripts, and nothing says so.** A resumed, forked or
  `bridge-session` mirror transcript copies earlier messages with the same `message.id`, the
  same timestamp and the same `cwd` under a new `sessionId`; 52 of them were shared by two
  files in one folder here on 2026-09-14. Within a file, every content block of a message
  repeats its `usage` (226 lines, 52 messages). So the ledger dedupes on the id across every
  file, first seen wins. The same goes for Codex: a forked rollout replays its parent's
  `token_count` totals before its own, with no marker, so a cumulative total already counted
  counts for nothing.
- **Codex moves old rollouts into `archived_sessions/`**, flat, keeping the file name. The
  index keys a rollout on the uuid in its name and follows it by inode, so a move is a path
  update and not a new file.
- **A transcript's `cwd` moves with the agent's shell.** 163 of the 300 newest here carry more
  than one. A session belongs to the folder it started in: the first `cwd` of its own
  transcript, which its subagents take too.
- **Never `Hasher` for anything stored.** It is seeded per process, so a dedupe key written by
  one launch matches nothing in the next. `StableHash` is FNV-1a.
- **The kit's write gate is `gate:`, not the annotations.** `MCPTool.mutates` is
  `gate == .requiresWrites`; `.mutating(...)` only tells a client what the tool does. A tool
  annotated as mutating and left at the default `.always` is listed and callable with Allow
  writes off.
- **An agent's opening message is made safe by refusing, not by quoting.** Both CLIs take it as
  the trailing word on their command line, and a message that begins with `-` is a flag
  (`--dangerously-skip-permissions`), `!` is shell mode and `/` a slash command, whatever the
  quoting. So `Tools.promptRefusal` refuses those, the message travels in a 0600 file the script
  reads and deletes, and it reaches the command line as one double-quoted word. It is still
  visible to `ps` for the same user while the agent runs, which SECURITY.md puts out of scope.
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
- **`CLAUDE_CONFIG_DIR` must have no trailing slash, and failing that is silent.** A
  slash makes Claude Code report `rate_limits_available: false, subscription_type: null`
  — the same answer as a wrongly-set default folder, and `UsageProbe` returns nil for it
  like any other failure, so the account quietly shows its on-disk cache forever. It is
  the difference between an account with 981 recorded usage samples and one with 11. Use
  `ClaudeConfigFolder.path` (and `CodexHome.path`), never `base.path` — `base` is built
  with `directoryHint: .isDirectory` and therefore ends in a slash.
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
- **The detail pane no longer falls back to the first session.** `selected` is nil when
  nothing is selected, which is a state with a view of its own — the account overview —
  rather than an empty branch inside `SessionDetail`. Both detail views therefore take a
  non-optional session. The overview is reached at launch, by clicking empty space in the
  list, and by ⌘-clicking the selected row; there is no other way back to it, which is
  the same deal Mail offers and the reason the New Session control lives there rather
  than in the header.
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
- **MCP tool calls run on the listener's connection threads, never the main actor.**
  `FleetBridge` is the only door, and it hops once with `MainActor.run` and reads stored
  properties. Two hops can straddle a rescan and pair one session's state with another rescan's
  context; an `await` or a file read inside the hop runs MCP work on the thread drawing the
  window. Transcript reads happen in the tool, after the hop, off the main actor.
- **`FleetBridge` is a `nonisolated struct`, not a main-actor class.** Under
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a main-actor class conforming to `FleetSource`
  gets an isolated conformance, and that cannot be handed to the listener's threads at all.
- **The supervisor's token travels in a file, never an argument.** `--mcp-config` takes inline
  JSON too, but a process's arguments are readable through `ps`. The file is created 0600 in
  the launch's own temporary directory, and `prune` clears it with the script.
- **The MCP token's Keychain item is per bundle identifier.** Debug and the installed build are
  signed differently, so one shared item would prompt in whichever did not create it. Each build
  has its own token, and the two collide on the port if both are switched on.
- **A Debug build can serve 503 on every authenticated call.** Observed 2026-09-15: `/health`
  answered 401 without the token and 503 with it, and `/mcp` returned "The credential store
  cannot be read right now. Unlock the keychain and try again." It did not clear in an hour, and
  the cause was not diagnosed. A client sees every tool fail, so check `/health` with the token
  before blaming the client.

- **Voice's `claude` is Armada's own child, so the session list hides it.**
  `SessionRegistry.isArmadaProbe` filters every `claude` whose parent is Armada, which is right
  here: it is not a session you started. It is stopped by its pid, never by a pattern.
- **`--safe-mode` is the obvious flag for the voice `claude` and the wrong one.** It drops
  `--mcp-config` too. `--setting-sources local` is what keeps the person's hooks out.
- **A resumed `claude` keeps the system prompt its conversation began with.** A new
  `--append-system-prompt` is ignored on `--resume` (measured on 2.1.273, see
  claude-code-sessions.md), so a reply language, instructions or Allow writes changed during a
  conversation never reached the model: French questions went on getting French answers.
  `VoiceConversation` resumes only when the brief is unchanged, and otherwise the next question
  starts a new conversation.
- **The voice card must never become key.** The shortcut is pressed while typing somewhere
  else, and a panel that took focus would take the next keystroke. The panel settings are
  Cupertino's `DrivingOverlay`'s, where that was measured.
- **A held hot key repeats its press.** `VoiceShortcut` drops presses while the key is down;
  without that, holding the chord in press mode would send the question at once.
- **Writing to a `claude` that has just died raises SIGPIPE**, which ends Armada. The voice
  process's stdin is set `F_SETNOSIGPIPE`, so the write fails instead.
- **The voice `claude` starts while you are still speaking.** `VoiceController` pre-warms it
  on the press, so the second or two it takes is spent before the question exists.
- **FluidAudio lives in its own framework so the audit can name it.** Linked statically, its
  downloader's URLSession symbols would sit in Armada's executable. `ArmadaSpeech` is a dynamic
  library product for that reason alone; do not make it static.
- **FluidAudio downloads whenever it is allowed to.** Loading a missing model fetches it unless
  `ModelHub.offlineMode` is on, so `ParakeetRecognizer.prepare` turns it on before anything else
  and only `download` turns it off.
- **The first Parakeet load on a Mac compiles the model**: 12.8 s measured, 0.13 s every time
  after. `SpeechModelStore.warmUp` loads it when voice is switched on, never on the first press.
- **Kokoro refuses more than 510 phonemes in one call**, counted as Swift characters, and
  FluidAudio at this revision no longer splits for it. `KokoroSynthesizer.samples` cuts each
  sentence's phonemes with `PhonemeSplit` first.
- **Kokoro's G2P files live at a fixed path.** `G2PModel.shared` reads
  `~/.cache/fluidaudio/Models/kokoro` whatever directory the manager is given, so Armada passes
  none, and `KokoroSynthesizer.isInstalled` checks both folders.
- **The lexicon and extra voice packs come through `AssetDownloader`, which offline mode does not
  stop.** Loading reaches it only for a missing file, so `isInstalled` requires the lexicon before
  anything loads.
- **macOS 26.4–26.5.x crash in Apple's BNNS during Kokoro synthesis** (FluidAudio #844, fixed in
  26.6). FluidAudio only logs it, so `KokoroSynthesizer.isSupported` hides Kokoro there.
- **Kokoro's first load compiles seven stages for the Neural Engine**, about 20 s by FluidAudio's
  measure on an M1. `Speaker` reads with the system voice until `SpeechModelStore.voice.isLoaded`,
  so an answer never waits for it.
- **Stop the `AVAudioPlayerNode` before its engine.** An engine stopped under a player left playing
  restarts with that player stuck: `isPlaying` stays true, `play()` does nothing, and the next
  buffer never plays or completes, which left every answer after the first one silent. `Speaker`'s
  `stopEngine` stops the player first whenever the queue drains, on `stop()`, and after an audio
  configuration change, where the system has already stopped the engine.
- **Another app's copy of a model cannot be checked from the outside.** Listing
  `~/Library/Containers/<other app>/Data` fails with "Operation not permitted", even from
  Terminal, and hiding that error makes the folder look empty. That is why voice reads
  FluidAudio's shared models folder and not Cadence's container.
- **FluidAudio's streaming managers do not fit.** `StreamingUnifiedAsrManager` runs an
  English-only model, and the multilingual Nemotron streaming model is a separate download,
  weaker on French. Live words come from running v3 over the growing buffer instead.

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

# The MCP endpoint, with Settings ▸ Supervisor switched on:
curl -s -H "Authorization: Bearer <token>" http://127.0.0.1:8790/health   # 200 and the versions
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8790/health    # 401 without the token
log stream --predicate 'subsystem == "io.mgcrea.armada" && category == "mcp"'  # a line per call

# A tools/list round trip. The 2026-07-28 revision wants the method in a header and the
# version in the body's _meta as well; without them the listener refuses the frame.
curl -s http://127.0.0.1:8790/mcp -H "Authorization: Bearer <token>" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/list' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{
       "io.modelcontextprotocol/protocolVersion":"2026-07-28",
       "io.modelcontextprotocol/clientInfo":{"name":"curl","version":"1"}}}}' \
  | jq -r '.result.tools[].name'                          # the armada_* tools: seven, ten with Allow writes on

# A tools/call needs the tool's name in an Mcp-Name header too, or the listener answers -32020.
# Same headers as above plus -H 'Mcp-Name: armada_wait', and in the body
# "method":"tools/call","params":{"name":"armada_wait","arguments":{"timeout_seconds":5},"_meta":{...}}

# Message delivery, with Settings ▸ Supervisor ▸ Deliver messages on:
grep -c deliver-message ~/.claude*/settings.json          # 1 per account; 0 once it is off
ls ~/Library/Application\ Support/io.mgcrea.armada.debug/inbox   # a folder per session that has had a turn
pgrep -lf deliver-message.zsh                             # one waiting hook per live session, no more

# Voice, with Settings ▸ Voice and the MCP server on, while a conversation is open:
pgrep -lP "$(pgrep -nx Armada)"                          # the voice claude, Armada's own child
ls ~/Library/Application\ Support/io.mgcrea.armada.debug/voice   # a folder per account; io.mgcrea.armada when installed
ls ~/Library/Application\ Support/FluidAudio/Models/parakeet-tdt-0.6b-v3   # the model voice uses when it is there
```

Voice also needs three checks by eye, none of which a command can make. Type in TextEdit, press
the shortcut, and keep typing: the text must keep landing in TextEdit. The orange microphone
dot must show only while the card says it is listening. A screenshot taken while the card is
up must not contain it.

To point a session in this repo at the endpoint rather than starting a supervisor, put the
JSON snippet from Settings ▸ Supervisor in `.mcp.json` at the root. It carries the bearer
token, which is why `.gitignore` lists it beside the secrets. Claude Code shows a project
`.mcp.json` server as pending until it is approved, and connects to it only after that.

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

- **The tests cover what fails silently, not the UI.** `make test` runs four suites:
  `scripts/` under node:test (the CHANGELOG parse the appcast, the release body and the What's
  New pane share; the licence key format; and the Sparkle signature check `make appcast` runs),
  the licence Worker under vitest inside the Workers runtime against a local D1, the app's
  pure files under `make unit` (the transcript parsers, forecasts, sort order and licence
  refusals, compiled beside a check driver with `swiftc`), and the ArmadaMCP package under
  `swift test` against a fake fleet. The app target has no test bundle.
  `make license-check`, which runs a minted key through the real `License.swift`, needs the
  signing key, so it is not part of `make test` and runs in CI only where that secret exists.
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

### Where the supervisor is thin

Shipped 2026-09-14. The package suite covers the tool table against a fake fleet, and the
listener was driven over a real socket with that table; the rest is known and unmeasured.

- **Never run end to end from the button.** Not yet observed: a session started by Start
  Supervisor Session connecting, `--allowedTools mcp__armada` sparing it the permission
  prompts, and `--name` reaching the registry so the row reads "Armada supervisor" before an
  `ai-title` lands. The argument order was checked by having zsh split the generated line.
- **Regenerating the token cuts off every client silently.** A running supervisor and any
  `.mcp.json` holding the old token get a 401 on their next call. Nothing tells them why.
- **Debug and installed builds keep separate tokens and share a default port.** Whichever
  is switched on second shows the bind failure in the pane and serves nothing.
- **Codex transcripts are condensed thinly.** `armada_read_transcript` keeps messages,
  function calls and their outputs, and turn completions. Reasoning and the `event_msg`
  copies are dropped, and the injected-context filter is a prefix match on the tags seen on
  this Mac.
- **Codex never needs attention.** `armada_needs_attention` leaves it out for the reason the
  halo does: `awaitingInput` means open, not blocked. A supervisor asked about Codex has to
  read `armada_get_fleet` and judge.
- **A Claude context percentage can rest on a guess.** The limit comes from
  `ContextWindow.resolve`, and `limitNote` carries its explanation. An agent that drops the
  note reports an assumed 200k as fact.
- **Messaging is measured in the terminal only.** The hook fires for VS Code sessions (the
  2026-09-10 stream-json run), but whether the panel shows the turn a message starts is not
  confirmed. A session reaches a message only while its hook runs: from the end of its first turn
  after delivery was turned on, for up to 24 hours idle. Debug and installed builds each install
  their own hook, so with both switched on a session runs two.
- **Closing a VS Code session is unmeasured.** `armada_close_session` was driven end to end
  on 2026-09-16 against Claude Code 2.1.273 sessions in a pty: busy refused without `force`,
  closed with it in 0.66s with its running command gone, idle closed in 0.7s, a second close
  inside five seconds refused. What the Claude Code panel in VS Code does when its CLI is ended
  underneath it was not tried.
- **A fresh `sessionId` is unverified through the app.** The flag was measured (see
  claude-code-sessions.md), and resume was driven end to end, but no fresh Terminal launch was:
  the debug build had "start in VS Code" on, which by design returns no id.
- **`armada_wait` polls.** It takes a fleet snapshot every second for up to 240s, one main-actor
  hop each, rather than being woken by the watchers. A supervisor looping on it costs one hop a
  second for as long as it watches.
- **The supervisor is Claude-only.** Codex takes an MCP server through `-c mcp_servers`, so a
  Codex supervisor is a launch-script change, not a server change.

### Where voice is thin

Built 2026-09-15. The package suite pins the stream-json shapes, the argument lockdown, the
chunker, the silence rule and every shortcut transition, and the app builds and passes `make
audit`. Nothing below has been run end to end.

- **Never run with a live microphone or a tool call.** The spike measured stream-json, resume,
  interrupt and dictation from a recorded file, but Armada's endpoint could not read its token
  that day. No voice turn has called an Armada tool, and the `tool_use`, API-error and retry
  fixtures are built from the CLI's schema rather than captured.
- **Press mode ends a question on level alone**: -42 dBFS and 1.5 s of quiet, untuned. A loud
  room holds it open until the 45 s cap, and a quiet voice may be cut off.
- **The microphone prompt is untested in the app bundle**, and so is whether an app, unlike the
  command-line spike, is also asked for speech recognition.
- **Unless Answer in fixes a language, replies are spoken in the system language's voice**,
  whatever language the reply is in. Kokoro reads English only, so a French answer read by Kokoro
  sounds wrong.
- **Kokoro has never read a live answer.** Its download, first load and playback are untested in
  the app, it offers one voice (`af_heart`), and what it adds to Armada's memory is unmeasured.
- **Parakeet was measured on four recorded French questions**, against Apple's dictation, not on
  English or on sentences mixing both. The Download button has never run, and a 480 MB download
  interrupted halfway is untested.
- **A live pass transcribes everything heard so far**, so its cost grows with the question:
  0.125 s at 16 s, and the silence rule ends a question at 45 s.
- **`ArmadaSpeech` carries a name lookup it never uses.** `_getaddrinfo` comes from
  `libtext_processing_rs`, the Rust text normaliser FluidAudio links, not from FluidAudio's own
  code, and the audit allows it by name.
- **Only Claude answers.** A Mac with Codex accounts and no Claude account has no voice.
- **A conversation lasts until Start a New Conversation, an account switch or a relaunch.** Its
  session id is held in memory, so the context grows with every question until one of those, and
  a relaunch never resumes a history the Voice pane no longer shows.
- **Debug and installed builds share the default shortcut.** Whichever registers second shows
  that another app already uses it.
