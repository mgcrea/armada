# Antigravity CLI Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch Antigravity CLI (`agy`) sessions in Armada beside Claude Code, Codex and Grok Build: sidebar, menu bar panel, MCP fleet tools, and start/resume from saved Projects.

**Architecture:** A parallel set of `Antigravity*` types modelled on the `Grok*` ones (each vendor keeps its own types). Liveness comes from which `agy` process holds `presence/<id>.lock` open (an open-file scan, which also gives the pid); run state and titles from `conversation_summaries.db` opened read-only; tokens from `transcript.jsonl`, read incrementally.

**Tech Stack:** Swift 6, SwiftUI, SQLite3 C API, libproc (`proc_pidinfo`, `proc_pidfdinfo`), FSEvents; `make unit` (swiftc unit checks), `swift test` for ArmadaMCP.

**Spec:** [docs/superpowers/specs/2026-11-27-antigravity-design.md](../specs/2026-11-27-antigravity-design.md). Findings: [docs/antigravity-sessions.md](../../antigravity-sessions.md). Read both first.

## Global Constraints

- One home only: `~/.gemini/antigravity-cli`, counted only when `conversation_summaries.db` exists in it. No Add Account, no `NewAccount.Vendor` case.
- Never write under `~/.gemini`, never `flock` a presence lock, never open `*.pb` or `conversations/<id>.db`.
- SQLite: `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)` + `sqlite3_busy_timeout(db, 500)`, as `CodexQueue.contains(_:in:)`.
- States: `working`, `awaitingInput`, `ended` (raw values exactly these; labels "Working", "Waiting for input", "Ended").
- Running statuses: `CASCADE_RUN_STATUS_RUNNING`, `CASCADE_RUN_STATUS_BUSY`, `CASCADE_RUN_STATUS_CANCELING`.
- Recent window: 12 hours after the last write; a live session is listed regardless.
- MCP vendor string: `"antigravity"`; display name "Antigravity". Session ids are lowercase UUIDs.
- Launch: executable `agy`, `cd` into the project, no env lines; resume `--conversation=<id>`; `--model <id>` when picked; no fork (`ForkAvailability` unavailable).
- Files in `apps/apple/Armada/` need no pbxproj edit (synchronized group). Pure files checked by `make unit` must be added to `UNIT_SRC` in `apps/apple/Makefile`.
- swift-format must pass: `make -C apps/apple format-swift-check`.
- Commit by explicit path (other sessions work in the same checkout). Conventional commit messages, as in `git log`.

## Review Focus

1. **A crashed `agy` leaves the row at `RUNNING`.** Not live (no process holds the lock) → `ended`, never `working`. Test: `antigravityState` check in Task 1.
2. **A conversation started from a TUI but never prompted** has a lock and maybe no row/transcript. Listed while live with the folder name; skipped otherwise. Test in Task 2's scan check.
3. **Paths through symlinks** (`/private/tmp` vs `/tmp`, a symlinked home): lock paths from the kernel are resolved; compare against the resolved presence directory. Test: `conversationId(lockPath:presenceDir:)` with a resolved and an unresolved prefix in Task 1.
4. **A transcript line cut mid-write** at the end of the file is not counted and is re-read next scan (the offset advances only past the last newline). Test in Task 1.
5. **The pid in a close or focus request has been reused** by another process: the start time captured at scan must still match (`SessionCloserBridge.startTolerance`), or the request is refused. Test via `prepare` in Task 5.

---

### Task 1: Parsers and presence (pure, unit-checked)

**Files:**
- Create: `apps/apple/Armada/AntigravityHome.swift`, `apps/apple/Armada/AntigravityFiles.swift`, `apps/apple/Armada/AntigravityPresence.swift`
- Modify: `apps/apple/Makefile` (`UNIT_SRC`: add the three files), `apps/apple/UnitChecks/UnitCheck.swift` (new `antigravityFiles()` called from `main()` beside `grokFiles()`)

**Interfaces — Produces:**
- `nonisolated struct AntigravityHome: Sendable, Hashable` with `base: URL`; `static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AntigravityHome?` (nil unless `conversation_summaries.db` exists); `summariesDB`, `presenceDir`, `brainDir: URL`; `func transcript(id: String) -> URL` (`brain/<id>/.system_generated/logs/transcript.jsonl`); `path`, `id` (= path), `displayName` ("Antigravity"), `displayPath` (tilde-abbreviated).
- `nonisolated enum AntigravityFiles`:
  - `struct Summary: Sendable, Hashable { id, title: String?, preview: String?, cwd: String, status: String, stepCount: Int, lastModified: Date?, lastUserInput: Date?, parentId: String? }` with `var isRunning: Bool`, `var projectName: String` (as `GrokFiles.Summary`).
  - `static func summaries(databaseAt: URL, since: Date) -> [Summary]` — rows with `last_modified_time` ≥ `since` (compare as parsed dates in Swift, not as SQL text).
  - `static func date(_ text: String) -> Date?` for `2026-11-27 07:56:39.575551+00:00` (also accept no fraction).
  - `static func cwd(workspaceURIs: String) -> String` — first `file://` URL's path, percent-decoded; `""` when none.
  - `struct TranscriptDelta: Sendable, Equatable { consumed: Int, steps: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, model: String?, lastStepAt: Date?, lastPrompt: String? }` and `static func transcriptDelta(_ data: Data) -> TranscriptDelta` — parses complete lines only; `consumed` = bytes up to and including the last `\n`.
  - `static func promptText(_ content: String) -> String` — the text inside `<USER_REQUEST>…</USER_REQUEST>`, trimmed; the whole content trimmed when there is no wrapper.
- `nonisolated enum AntigravityPresence`:
  - `struct Holder: Sendable, Hashable { pid: Int32, startedAt: Date }`
  - `static func conversationId(lockPath: String, presenceDir: String) -> String?` — lowercase id when `lockPath` is `<presenceDir>/<uuid>.lock`; `presenceDir` is resolved with `realpath` by the caller once.
  - `static func holders(presenceDir: URL) -> [String: Holder]` — `ProcessAncestry.allPIDs()` filtered by `ProcessAncestry.executablePath(of:)` last component `agy` (also match `/agy` symlink targets by checking the name of the resolved path, and `language_server*` is **not** included), then `proc_pidinfo(pid, PROC_PIDLISTFDS, …)`, `proc_pidfdinfo(…, PROC_PIDFDVNODEPATHINFO, …)` per `PROX_FDTYPE_VNODE`, start time from `ProcessAncestry.startTime(of:)`. `ProcessAncestry.swift` must then join `UNIT_SRC` if it is not already there; if it pulls in AppKit, keep `holders` in a separate `AntigravityPresenceScan.swift` outside `UNIT_SRC` and check only `conversationId`.
- `enum AntigravitySessionState: String, Sendable { working, awaitingInput, ended }` with `label`, `tint`, `isLive` (copy `GrokSessionState`), and `static func of(holder: AntigravityPresence.Holder?, summary: AntigravityFiles.Summary?) -> AntigravitySessionState` — no holder → `.ended`; holder and `isRunning` → `.working`; holder otherwise → `.awaitingInput`. Put it in `AntigravityFiles.swift` so the unit checks see it.

- [ ] **Step 1: Write the failing checks** in `antigravityFiles()`:
  - `date("2026-11-27 07:56:39.575551+00:00")` equals `date(2026,11,27,7,56,39.575551 UTC)` within 0.001 s; `date("2026-11-27 07:56:32+00:00")` non-nil; `date("x")` nil.
  - `cwd(workspaceURIs: #"["file:///private/tmp/a%20b/ws"]"#) == "/private/tmp/a b/ws"`; `cwd(workspaceURIs: "[]") == ""`.
  - `summaries(databaseAt:since:)` over a temp SQLite created in the check with the real `CREATE TABLE conversation_summaries` from the findings doc and the three measured rows (one titled `Run Command Probe Ok`, one `RUNNING`): returns them with the right `title` (nil when empty), `isRunning`, `cwd`, and filters by `since`.
  - `transcriptDelta` over the four measured `transcript.jsonl` lines (copy from the findings doc / probe): `steps == 4`, `inputTokens == 11635 + 2251`, `outputTokens == 168 + 747`, `cacheReadTokens == 9586`, `model == "gemini-4-hydrogen-high"`, `lastPrompt == "Read README.md and tell me its content in one line."`; the same data plus a half line without `\n` gives the same counts and `consumed` = the full lines' byte count (Review Focus 4).
  - `promptText` strips the wrapper and drops `<ADDITIONAL_METADATA>`.
  - `conversationId(lockPath: "/Users/x/.gemini/antigravity-cli/presence/33A760CD-88ED-464B-8F42-2051D73812AB.lock", presenceDir: "/Users/x/.gemini/antigravity-cli/presence") == "33a760cd-88ed-464b-8f42-2051d73812ab"`; a non-uuid name, another directory, or a `.lock.tmp` → nil (Review Focus 3: the caller passes the realpath; the check passes `/private/tmp/p` as dir and `/private/tmp/p/<uuid>.lock`).
  - `AntigravitySessionState.of`: (nil holder, running summary) → `.ended` (Review Focus 1); (holder, running) → `.working`; (holder, idle) and (holder, nil summary) → `.awaitingInput`.
- [ ] **Step 2: Run** `make -C apps/apple unit` — expect a compile failure naming `AntigravityFiles`.
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run** `make -C apps/apple unit` — all checks pass, including the existing ones.
- [ ] **Step 5: Live sanity** (read-only): a tiny Swift script or a temporary `#if DEBUG` print is not needed; instead, with `agy` idle, `holders` must return `[:]`. Skip if it would need the app; Task 2's run covers it.
- [ ] **Step 6: Commit** the three new files, `Makefile`, `UnitCheck.swift`, plus `docs/antigravity-sessions.md`, the spec and this plan: `feat(antigravity): read the Antigravity CLI's summaries, transcripts and presence locks`.

### Task 2: Watcher, session and account

**Files:**
- Create: `apps/apple/Armada/AntigravitySession.swift`, `apps/apple/Armada/AntigravityWatcher.swift`, `apps/apple/Armada/AntigravityAccount.swift`
- Modify: `apps/apple/Armada/EntitlementGate.swift:39,51` (start/stop beside Grok), `apps/apple/Armada/RecentProject.swift:96` (overload for `[AntigravitySession]`), `apps/apple/UnitChecks/UnitCheck.swift` if `scan`'s merge logic is factored pure.

**Interfaces — Consumes:** Task 1. **Produces:**
- `@Observable final class AntigravitySession: Identifiable` — `id`, `summary: AntigravityFiles.Summary?`, `cwd: String`, `state`, `holder: AntigravityPresence.Holder?`, `lastEventAt: Date?`, `model: String?`, token totals `inputTokens/outputTokens/cacheReadTokens: Int`, `lastPrompt: String?`, `transcriptURL: URL`, `transcriptOffset: Int`; `displayName` (title, else preview's first line cut at 60 chars, else project name), `projectName`, `pid: Int32? { holder?.pid }`, `totalTokens`.
- `@MainActor @Observable final class AntigravityWatcher` — `sessions`, `didScan`, `liveSessions`, `workingCount`, `awaitingInputCount`, `start()`, `stop()`, `scheduleScan()`; `nonisolated static func scan(home:known:) -> [AntigravityScanEntry]` off the main actor. Same structure as `GrokWatcher`: FSEvents on `brainDir` only, a 5 s sweep timer (presence and the db), the generation guard, `ScreenshotMode` guard, `UsageIndex.shared.noteActivity()` when a transcript grew. `known` carries each session's `transcriptOffset` and size; the scan reads the transcript from that offset (from 0 when the file shrank) and returns the delta, which `apply` adds.
  - Listed: every id with a holder, plus every summary row with `lastModified` within 12 h. A held id with no row is listed with `cwd` from `cache/last_conversations.json` if it maps to that id, else `""` (Review Focus 2).
  - Sort by `lastEventAt ?? summary.lastModified`, newest first, then id.
- `@MainActor @Observable final class AntigravityAccount: Identifiable` — `home`, `sessions: AntigravityWatcher`, `id`, `displayName`, `displayPath`, `recentProjects`. No usage, no probe.
- `@MainActor @Observable final class AntigravityAccounts` — `static let shared`, `all: [AntigravityAccount]` (zero or one), `isEmpty`, `account(id:)`, `start()`, `stop()`, `workingCount`, `awaitingInputCount`, `liveCount`; `#if DEBUG demoInstall(_:)` on accounts and watcher, as Grok's.

- [ ] **Step 1: Failing check**: if the row/holder merge is a pure `nonisolated static func merge(summaries:holders:lastConversations:now:) -> [(id: String, summary: Summary?, holder: Holder?)]`, check it in `antigravityFiles()`: a held id with no row is kept; an unheld row older than 12 h is dropped; an unheld row within 12 h is kept as `.ended`.
- [ ] **Step 2: Run** `make -C apps/apple unit` — fails.
- [ ] **Step 3: Implement** the three files and the `EntitlementGate`/`RecentProject` edits.
- [ ] **Step 4: Run** `make -C apps/apple unit` and `make -C apps/apple build` — both pass.
- [ ] **Step 5: Commit**: `feat(antigravity): watch Antigravity CLI sessions`.

### Task 3: Window and menu bar

**Files:**
- Create: `apps/apple/Armada/AntigravityPane.swift` (`AntigravityPaneView(account:)`, `AntigravitySidebarRow`, `AntigravityStateDot`, `AntigravitySummary(account:showsName:now:)` for the menu panel, `AntigravityIconView` = `Image(systemName: "atom")` at the size `GrokIconView` uses)
- Modify: `MainWindow.swift` (`SidebarItem.antigravity(String)`, prefix `"antigravity:"`, section "Antigravity" after Grok, detail case, selection validation and fallback, empty-state copy naming `agy`); `ArmadaApp.swift` (working check, `MenuBarHalo` counts, menu panel section filtered by hidden accounts, empty-state check); `MenuBarHalo.swift` and `KeepAwake.swift`/`KeepAwakeController.swift` (`antigravityWorking`, `antigravityAwaitingInput` params defaulting to 0, counted as Grok's are); `SettingsWindow.swift:181` (row `(id, displayName, "Antigravity · path")`); `PanelVisibility.swift` only if it enumerates vendors.

**Interfaces — Consumes:** Task 2's `AntigravityAccounts.shared`, `AntigravitySession`.

The pane mirrors `GrokPaneView` minus limits, fork and headless: per session the state dot, display name, project, model, last activity, total tokens, and a Resume button (wired in Task 4; leave the action calling `NewSessionLauncher` once Task 4 lands — in this task show it disabled with no action, or build Task 4 first if the implementer prefers; the reviewer gates the pair).

- [ ] **Step 1: Failing checks** in the existing `MenuBarHalo`/`KeepAwake` unit sections (`UnitCheck.swift` ≈1371–1401): `antigravityWorking: 1` alone makes the halo and keep-awake count working, `antigravityAwaitingInput: 1` alone counts as waiting exactly as `grokAwaitingInput: 1` does.
- [ ] **Step 2: Run** `make -C apps/apple unit` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make -C apps/apple unit && make -C apps/apple build` — pass. Then follow the `rebuild-running-armada` memory (build to scratch with the real bundle id) and, **after asking the user** (focus tests need a go-ahead), open the window and check the Antigravity section lists the three probe conversations as Ended.
- [ ] **Step 5: Commit**: `feat(antigravity): show Antigravity CLI sessions in the window and the menu bar`.

### Task 4: Start and resume from Projects

**Files:**
- Modify: `NewSession.swift` (`Agent.antigravity(AntigravityHome)`, `commandName` "agy", display name "Antigravity", `executable(for:)` → `AntigravityHome.executable()` (new static: `~/.local/bin/agy` if executable, else the login-shell `PATH` lookup `GrokControl.executable()` uses), arguments: `.fresh` → none, `.identified` → not supported (treat as `.fresh`; `agy` has no `--session-id`), `.resume(id)` → `--conversation=<id>`, `.fork` → unreachable (assert); `--model <id>` and the prompt as for Grok (prompt via `-i "<prompt>"` so the TUI stays open), `accountLines` → none); `Project.swift` (`ProjectAgent.antigravity(homeID:)`, label "Antigravity", storage key "antigravity", decoding); `ProjectStore.swift` (resolve, display name, default when it is the only agent, suggestions from `recentProjects`, `Agent`→`ProjectAgent`); `ProjectPane.swift` (`ProjectSession.Source.antigravity`, its switch cases, collection, "Antigravity on X" start item, picker tag, state dot, open route `.antigravity(account.id)`); `SessionStarterBridge.swift` (`vendor == "antigravity"` resume path and default-home resolution; reject `headless` for it with "Antigravity sessions start in a terminal; headless turns are not supported yet."); `ProjectsBridge.swift` (rows with `vendor: "antigravity"`); `ForkSession.swift` (`static func antigravity(...) -> ForkAvailability` returning unavailable "The Antigravity CLI cannot fork a conversation."); `BuildSlotMonitor.swift:128` (candidates from live sessions with a pid, `vendor: "antigravity"`).

**Interfaces — Consumes:** Tasks 1–3.

- [ ] **Step 1: Failing checks**: in the projects section of `UnitCheck.swift` (≈1630), a `Project` stored with `.antigravity(homeID: "/h")` round-trips through its storage encoding with key "antigravity". If `NewSession`'s argument builder is reachable from `UNIT_SRC`, check `.resume("abc")` gives `["--conversation=abc"]`; otherwise check it in `StartSessionToolTests` via the bridge's command, or skip with a note.
- [ ] **Step 2: Run** `make -C apps/apple unit` — fails.
- [ ] **Step 3: Implement**, wiring the pane's Resume button.
- [ ] **Step 4: Run** `make -C apps/apple unit && make -C apps/apple build` — pass.
- [ ] **Step 5: Commit**: `feat(antigravity): start and resume Antigravity CLI sessions from Projects`.

### Task 5: MCP tools

**Files:**
- Modify: `Packages/ArmadaMCP/Sources/ArmadaMCP/FleetSource.swift` (`FleetSnapshot.antigravity: [AntigravityAccount]`, init param defaulting to `[]`; `FleetSnapshot.AntigravityAccount(id:name:sessions:)`; `FleetSnapshot.AntigravitySession(id, pid: Int32?, name, title, project, cwd, state, stateLabel, isLive, startedAt, lastActivity, model, totalTokens, transcriptPath)` and its `rank`); `TranscriptTail.swift` (`Vendor.antigravity`, a parser for `transcript.jsonl` steps: `USER_INPUT` → user entry via the same `<USER_REQUEST>` stripping, `PLANNER_RESPONSE` → assistant text and tool calls by name, `GENERIC` with `error` → tool error); `Tools.swift` (server instructions: Antigravity's states use Codex's vocabulary; `get_fleet` vendor enum adds "antigravity"; `needs_attention` leaves `awaitingInput` out like Codex/Grok; `get_session`, `read_transcript`, `Lookup.antigravity`, `row`/`detail` overloads; `start_session` accepts "antigravity" (no headless); `send_message` refuses "Armada cannot send messages to Antigravity CLI sessions yet."; close and focus accepted); `SessionStarter.swift`/`SessionCloser.swift` doc comments.
- Modify (app): `FleetBridge.swift` (`antigravity:` mapping), `SessionCloserBridge.swift` (`vendor == "antigravity"` → a `prepareAntigravity` that finds the session, refuses a busy one without `force` exactly as Claude's, checks `ProcessAncestry.startTime(of: pid)` against `holder.startedAt` within `startTolerance` (Review Focus 5), then reuses `terminate`), `SessionFocuserBridge.swift` (an Antigravity branch: a host from the pid — add `SessionHostLookup.host(pid:startedAt:)` beside `host(for:)` by factoring `resolve`), `MessageSenderBridge.swift` only if the vendor enum forces a case, `VoiceController.swift:397,410` (hint "Antigravity", account names).
- Create: `Packages/ArmadaMCP/Tests/ArmadaMCPTests/AntigravityToolsTests.swift`.

**Interfaces — Consumes:** Task 2's session fields.

- [ ] **Step 1: Failing tests** in `AntigravityToolsTests`, built like `GrokToolsTests` (`FakeFleetSource` with one `AntigravityAccount` at `/Users/me/.gemini/antigravity-cli`): `fleet` lists the sessions with vendor "antigravity" and their states; `needsAttention` omits an `awaitingInput` one; `session` returns the detail with `totalTokens`; `transcript` over a temp `transcript.jsonl` holding the four measured lines yields user "Read README.md and tell me its content in one line.", a `read_file` tool call, the tool error, and the final answer; `sendRefused` returns the refusal text above; `startHeadlessRefused` for `vendor: "antigravity", headless: true`.
- [ ] **Step 2: Run** `cd apps/apple/Packages/ArmadaMCP && swift test --filter AntigravityToolsTests` — fails.
- [ ] **Step 3: Implement** package and bridge changes.
- [ ] **Step 4: Run** `make -C apps/apple test` and `make -C apps/apple build` — pass.
- [ ] **Step 5: Unit check for Review Focus 5** if `prepareAntigravity`'s start-time comparison is a pure helper (`static func matches(claimed: Date, actual: Date?) -> Bool`): mismatch by 10 s → false, nil → false, 1 s → true.
- [ ] **Step 6: Commit**: `feat(mcp): expose Antigravity CLI sessions in the fleet tools`.

### Task 6: Demo seed, docs, release notes

**Files:**
- Modify: `apps/apple/Armada/DemoSeed.swift` (one `AntigravityAccount` with two sessions, one `.working` and one `.ended`, installed via `demoInstall`; add its home to the fixture home list at ≈198); `README.md` (Antigravity CLI among watched agents); `CHANGELOG.md` (an `## [Unreleased]` section above 1.15.0 with `### Added` — **Antigravity CLI sessions.** one short paragraph in the file's voice); `SECURITY.md` if it lists the folders Armada reads (add `~/.gemini/antigravity-cli`, read-only).

- [ ] **Step 1: Run** the screenshot pipeline's golden check only if it runs headless without raising windows; otherwise note that goldens will move (out of scope per spec) and confirm `make -C apps/apple build` passes with `ScreenshotMode` compiled in.
- [ ] **Step 2: Run** `make -C apps/apple format-swift-check`, `make -C apps/apple unit`, `make -C apps/apple test`, then the root `make test` once for the branch.
- [ ] **Step 3: Commit**: `docs: describe Antigravity CLI support` (and `feat(screenshots): seed an Antigravity account` if separate).
