# Build Slots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A machine-wide queue for `swift build|test` and `xcodebuild` builds and tests: PATH shims that take a kernel file lock in the build's own process, shipped inside Armada.app, with Armada showing who holds and who waits.

**Architecture:** A new local package `apps/apple/Packages/BuildSlot` holds `BuildSlotCore` (pure decisions plus the lock and file primitives) and the `buildslot` executable (acquire loop, child process, signals). An Xcode tool target compiles that executable into `Armada.app/Contents/Helpers/buildslot`. The app links `BuildSlotCore` to write settings, install the `sh` shims, poll the queue, and match holders to sessions. `ArmadaMCP` gets one read tool through `FleetSource`.

**Tech Stack:** Swift 6.2 tools / Swift 6 language mode, macOS 26, Darwin `fcntl`/`posix_spawn`/`sysctlbyname`, Swift Testing, SwiftUI, `swift-mcp-kit` (already a dependency).

**Spec:** `docs/superpowers/specs/2026-11-24-build-slots-design.md`. Read it in full before any task; every value below comes from it.

## Global Constraints

- Lock directory: `/private/tmp/armada-build-slots-<uid>/` with `slots/N.lock` and `waiting/<pid>.lock`, mode 0700, created on demand.
- Settings file: `~/Library/Application Support/Armada/build-slots/settings.json`, fixed path, **not** `AppInfo.supportDirectory`. Written only by the app, read only by the tool.
- Settings JSON: `{"version":1,"slots":2,"memoryRule":"warning","memoryWaitCapSeconds":600,"slotWaitCapSeconds":1800}`; slots clamped to 1…8; missing or unreadable means these defaults.
- Test-only overrides: `ARMADA_BUILDSLOT_DIR` (lock directory) and `ARMADA_BUILDSLOT_SETTINGS` (settings file). Nesting: `ARMADA_BUILDSLOT_HOLDER=<pid>`. Bypass: `ARMADA_BUILDSLOT=off`.
- Locks are `fcntl(F_SETLK)` whole-file `F_WRLCK`, never `flock`. Every descriptor `O_CLOEXEC`. A process never opens a file it holds a lock on a second time, and never relies on `F_GETLK` to see its own locks.
- Every stderr line starts `buildslot: `. Copy as in the spec's "What the shim says".
- Shim marker line: `# armada-buildslot-shim v1 — written by Armada; Armada repairs or removes this file.`
- Shims only in `~/.local/bin`; never overwrite a `swift`/`xcodebuild` there without the marker.
- Only bundle id `io.mgcrea.armada` installs shims at launch; `io.mgcrea.armada.debug` never does.
- Feature switch **off by default**; not behind the licence.
- Any failure to queue (unwritable lock dir, unreadable settings, missing helper) runs the real tool unqueued. Never fail a build.
- Files under `Packages/BuildSlot` are added to `SWIFT_SRC` in `apps/apple/Makefile`; `make format-swift-check` must stay green.
- Subagents: implementers `model: opus`, `effort: medium`; reviewers `model: opus`, `effort: high`.

## Review Focus

1. **A worktree under the main checkout** (`repo/.claude/worktrees/x` while the main checkout holds a slot) must queue, not pass as "same tree". Test in Task 3 (`sameTreeStopsAtNestedGit`).
2. **Ctrl-C at a terminal while the build runs** must cancel it cleanly with one SIGINT reaching the child, and the shim must exit by that signal. Test in Task 4 (`interruptReachesChildOnce`).
3. **The helper deleted or moved** while shims remain: the `sh` shim runs the real tool and the build succeeds. Test in Task 5 (`shimFallsBackWhenHelperMissing`).
4. **A foreign `~/.local/bin/swift`** (someone's own wrapper) is never overwritten or removed. Test in Task 5 (`installRefusesForeignFile`, `uninstallKeepsForeignFile`).
5. **A slot file with a leftover record from a `kill -9`ed holder** must read as free, and its record must not be shown as a holder. Test in Task 2 (`leftoverRecordReadsFree`).

---

### Task 1: Package skeleton, invocation rules and the holder label

**Files:**
- Create: `apps/apple/Packages/BuildSlot/Package.swift`
- Create: `apps/apple/Packages/BuildSlot/Sources/BuildSlotCore/Invocation.swift`
- Create: `apps/apple/Packages/BuildSlot/Sources/BuildSlotCore/HolderLabel.swift`
- Create: `apps/apple/Packages/BuildSlot/Sources/buildslot/main.swift` (prints usage, exits 64; filled in Task 4)
- Create: `apps/apple/Packages/BuildSlot/Tests/BuildSlotCoreTests/InvocationTests.swift`
- Create: `apps/apple/Packages/BuildSlot/Tests/BuildSlotCoreTests/HolderLabelTests.swift`
- Modify: `apps/apple/Makefile` (`test` gains `swift test --package-path Packages/BuildSlot`; `SWIFT_SRC` gains `Packages/BuildSlot/Package.swift Packages/BuildSlot/Sources Packages/BuildSlot/Tests`)

**Interfaces:**
- Produces:
  - `public enum Tool: String, Sendable, CaseIterable { case swift, xcodebuild }`
  - `public enum Invocation { public static func queues(_ tool: Tool, arguments: [String]) -> Bool }` (arguments exclude argv[0])
  - `public enum HolderLabel { public static func label(cwd: String, hasGit: (String) -> Bool = HolderLabel.defaultHasGit) -> String; public static func workingTreeRoot(of path: String, hasGit: (String) -> Bool = HolderLabel.defaultHasGit) -> String? }`

Package shape: tools 6.2, `.macOS(.v26)`, products `.library(BuildSlotCore)` and `.executable(buildslot)`; targets `BuildSlotCore` (no dependencies), `buildslot` (depends on `BuildSlotCore`), test target `BuildSlotCoreTests` depending on `BuildSlotCore` and `buildslot` (so `swift test` builds the binary for Tasks 4–5). Header comment in the house style saying why it is a package (the tool must run without the app; the app reads the same format).

- [ ] **Step 1: Write the failing tests**

`InvocationTests` (Swift Testing), one `@Test` per row, `#expect(Invocation.queues(tool, arguments: args) == expected)`:

| tool | arguments | queues |
|---|---|---|
| swift | `build` | true |
| swift | `test --package-path Packages/X` | true |
| swift | `--package-path P test --filter Foo` | true |
| swift | `build --show-bin-path` | false |
| swift | `test --help` / `build -h` / `build --version` | false |
| swift | `run`, `run MyTool --flag`, `package resolve`, `format`, `repl`, `--version`, (empty) | false |
| xcodebuild | `build -project A.xcodeproj -scheme A` | true |
| xcodebuild | `-project A.xcodeproj -scheme A -destination platform=macOS` (no action) | true |
| xcodebuild | `test -scheme A -destination 'platform=macOS'` | true |
| xcodebuild | `-scheme build test` (scheme literally named `build`, action `test`) | true |
| xcodebuild | `-scheme test` (scheme named `test`, no action) | true (default build) |
| xcodebuild | `archive`, `analyze`, `install`, `docbuild`, `build-for-testing` | true |
| xcodebuild | `test-without-building -xctestrun x.xctestrun` | false |
| xcodebuild | `clean`, `installsrc` | false |
| xcodebuild | `-showBuildSettings -scheme A`, `-list`, `-version`, `-exportArchive -archivePath a`, `-resolvePackageDependencies`, `-showsdks`, `-showdestinations -scheme A`, `-showTestPlans`, `-create-xcframework`, `-checkFirstLaunchStatus`, `-runFirstLaunch`, `-help`, `-usage` | false |
| xcodebuild | `test -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner` | false |
| xcodebuild | `build CODE_SIGNING_ALLOWED=NO -scheme A` | true |

Plus one test that runs every `swift`/`xcodebuild` line from `~/Projects/apps/maquette/apps/apple/Makefile` and this repo's `apps/apple/Makefile`, transcribed as literal argument arrays in the test (not read from disk), with the expected answer for each.

`HolderLabelTests`, with a fake `hasGit` set:
- `/u/p/valise/.claude/worktrees/land-gate-f764fa9` → `valise/land-gate-f764fa9`
- `/u/p/valise/.claude/worktrees/land-gate-f764fa9/apps/apple` → `valise/land-gate-f764fa9`
- `/u/p/maquette/apps/apple` with `.git` at `/u/p/maquette` → `maquette`
- `/tmp/scratch` with no `.git` anywhere → `scratch`
- `workingTreeRoot("/u/p/valise/.claude/worktrees/x/sub")` with `.git` at both `/u/p/valise` and `/u/p/valise/.claude/worktrees/x` → `/u/p/valise/.claude/worktrees/x`

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/BuildSlot`
Expected: compile failure, `Invocation`/`HolderLabel` not found.

- [ ] **Step 3: Implement `Invocation.queues` and `HolderLabel`**

xcodebuild: an option table of value-taking options (`-project -workspace -scheme -target -configuration -destination -sdk -arch -derivedDataPath -resultBundlePath -xctestrun -testPlan -archivePath -exportPath -exportOptionsPlist -only-testing -skip-testing -toolchain -xcconfig -testProductsPath -clonedSourcePackagesDirPath -packageCachePath -destination-timeout -parallel-testing-worker-count -maximum-concurrent-test-simulator-destinations -resultStreamPath -jobs -default-test-execution-time-allowance -maximum-test-execution-time-allowance -test-iterations -testLanguage -testRegion`), skipped with their value; any argument starting `-` not in the table and not a pass-through flag is a flag without value; bare `KEY=VALUE` is a build setting; other bare words are actions. `defaultHasGit` checks `FileManager.fileExists(atPath: dir + "/.git")`. Paths resolved with `realpath` before walking.

- [ ] **Step 4: Run them to see them pass**

Run: `swift test --package-path apps/apple/Packages/BuildSlot` → all pass. Then `make -C apps/apple format-swift-check` → clean.

- [ ] **Step 5: Commit**

`git commit -m "feat(buildslot): package, which invocations queue, and the holder label"`

---

### Task 2: Settings, records, paths, locks and the reader

**Files:**
- Create: `Sources/BuildSlotCore/BuildSlotSettings.swift`, `SlotRecord.swift`, `BuildSlotPaths.swift`, `LockFile.swift`, `QueueReader.swift`, `MemoryPressure.swift` (all under `apps/apple/Packages/BuildSlot/`)
- Create: `Tests/BuildSlotCoreTests/SettingsTests.swift`, `LockTests.swift`, `TestHelpers.swift`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the package.
- Produces:
  - `public enum MemoryRule: String, Codable, Sendable, CaseIterable { case off, critical, warning }`
  - `public struct BuildSlotSettings: Codable, Equatable, Sendable { var version = 1; var slots = 2; var memoryRule = MemoryRule.warning; var memoryWaitCapSeconds = 600; var slotWaitCapSeconds = 1800; static let defaults; static func load(from url: URL) -> BuildSlotSettings; func encoded() throws -> Data }` (load clamps `slots` to 1…8 and caps to ≥ 0; unknown `memoryRule` → `.warning`)
  - `public enum MemoryPressure: Int, Sendable { case normal = 1, warning = 2, critical = 4; static func current() -> MemoryPressure; func blocks(under rule: MemoryRule) -> Bool; var word: String }` (`current()` reads `kern.memorystatus_vm_pressure_level`; any failure or unknown value → `.normal`)
  - `public struct SlotRecord: Codable, Equatable, Sendable { version: Int; pid: Int32; processStart: Date?; startedAt: Date?; waitingSince: Date?; cwd: String; label: String; tool: String; argv: [String]; static func truncated(_ argv: [String]) -> [String] }` (truncation: at most 20 arguments and 2048 bytes total, last kept argument cut, `…` appended as its own element when anything was dropped). JSON dates ISO 8601.
  - `public struct BuildSlotPaths: Sendable { lockRoot: URL; settingsFile: URL; var slotsDir: URL; var waitingDir: URL; func slotFile(_ n: Int) -> URL; func waitingFile(pid: Int32) -> URL; func waitingTempFile(pid: Int32) -> URL; static func standard(environment: [String: String] = ProcessInfo.processInfo.environment, uid: uid_t = getuid(), home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BuildSlotPaths; func ensureDirectories() throws }` (temp file name `.<pid>.tmp`)
  - `public final class LockFile { init(path: URL) throws /* O_RDWR|O_CREAT|O_CLOEXEC, 0600 */; func tryLock() -> Bool; func write(_ record: SlotRecord) throws /* ftruncate + pwrite via the same fd */; func rename(to: URL) throws; func unlinkAndClose(); deinit closes }`
  - `public enum LockProbe { static func holderPID(of path: URL) -> Int32? }` (opens `O_RDONLY|O_CLOEXEC`, `F_GETLK` with `F_WRLCK`, closes; nil when free or missing)
  - `public struct QueueEntry: Equatable, Sendable { slot: Int?; record: SlotRecord }`
  - `public struct QueueState: Equatable, Sendable { holders: [QueueEntry]; waiters: [QueueEntry]; freeSlots: [Int] }`
  - `public enum QueueReader { static func read(_ paths: BuildSlotPaths, slotCount: Int, ownPID: Int32? = nil, now: Date = .now, sweep: Bool = true) -> QueueState }`: slots `0..<max(slotCount, highest existing file + 1)`; a slot counts as held only when `LockProbe` names a pid equal to the record's `pid`; `freeSlots` lists free indices below `slotCount`; skips `ownPID`'s slot and waiting file without opening them; with `sweep`, deletes `waiting/<pid>.lock` whose lock is free and `.tmp` files older than 60 s.

- [ ] **Step 1: Write the failing tests**

`TestHelpers.swift`: `func tempPaths() -> BuildSlotPaths` (unique dir under `FileManager.default.temporaryDirectory`), and `func holdLock(_ url: URL, record: SlotRecord?) -> Process`, which starts `/usr/bin/python3 -I -c` with a short script taking `fcntl.lockf(f, LOCK_EX|LOCK_NB)` (a POSIX record lock, same family as `F_SETLK`), optionally writing the record JSON, printing `locked`, then sleeping 30 s. It returns once `locked` is read. Tests terminate it themselves. A second process is required because `F_GETLK` never reports the caller's own locks.

`SettingsTests`:
- `defaultsWhenMissing`: load of a missing file == `.defaults`.
- `defaultsWhenGarbage`: load of `"{"` == `.defaults`.
- `clampsSlots`: `slots: 0` → 1, `slots: 99` → 8.
- `unknownRuleIsWarning`: `"memoryRule":"sometimes"` → `.warning`.
- `roundTrips`: encode then load equals the value, and the encoded JSON has exactly the spec's five keys.
- `pressureBlocks`: `.warning.blocks(under: .warning)` true, `.warning.blocks(under: .critical)` false, `.critical.blocks(under: .critical)` true, anything under `.off` false, `.normal` never.
- `truncatesArgv`: 25 short args → 20 kept + `"…"`; one 5000-byte arg → its byte count ≤ 2048, `"…"` appended.
- `pathsHonourOverrides`: `standard(environment: ["ARMADA_BUILDSLOT_DIR": "/x", "ARMADA_BUILDSLOT_SETTINGS": "/y.json"])` gives those; without, `/private/tmp/armada-build-slots-<uid>` and `<home>/Library/Application Support/Armada/build-slots/settings.json`.

`LockTests`:
- `tryLockFailsWhileAnotherProcessHolds`: helper holds `slots/0.lock`; `LockFile(path:).tryLock()` false; after terminating the helper, true.
- `probeNamesHolder`: `LockProbe.holderPID` == helper's pid; nil after it exits.
- `leftoverRecordReadsFree`: write a record with pid 99999 into `slots/0.lock`, no lock held → `QueueReader.read(...).holders` empty, `freeSlots == [0, 1]`.
- `recordMustMatchProbe`: helper holds `slots/1.lock` with a record claiming another pid → not listed as holder, and slot 1 not in `freeSlots`.
- `readsHolderAndWaiter`: helper holds `slots/0.lock` with its own pid in the record; another holds `waiting/<pid>.lock` → one holder (slot 0), one waiter.
- `sweepsDeadWaiter`: `waiting/123.lock` with no lock → deleted by `read`; with `sweep: false` kept.
- `skipsOwnFiles`: `read(ownPID: getpid())` with this process holding `slots/0.lock` through `LockFile` → lock still held afterwards (helper's `tryLock` on it still fails).

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path apps/apple/Packages/BuildSlot` → compile failure.

- [ ] **Step 3: Implement the six files**

- [ ] **Step 4: Run them to see them pass**

Same command, all pass; `make -C apps/apple format-swift-check` clean.

- [ ] **Step 5: Commit**

`git commit -m "feat(buildslot): settings, slot records, fcntl locks and the queue reader"`

---

### Task 3: The acquire decisions, nesting and the messages

**Files:**
- Create: `Sources/BuildSlotCore/AcquirePolicy.swift`, `Nesting.swift`, `WaitMessages.swift`
- Create: `Tests/BuildSlotCoreTests/AcquirePolicyTests.swift`, `NestingTests.swift`, `WaitMessagesTests.swift`

**Interfaces:**
- Consumes: `BuildSlotSettings`, `MemoryPressure`, `QueueState`, `SlotRecord`, `HolderLabel.workingTreeRoot` (Tasks 1–2).
- Produces:
  - `public enum AcquireStep: Equatable, Sendable { case take(slot: Int); case waitForSlot; case waitForMemory(MemoryPressure); case takeAnyway(slot: Int?, reason: AnywayReason) }`
  - `public enum AnywayReason: Equatable, Sendable { case memoryCap, slotCap }`
  - `public enum AcquirePolicy { static func decide(state: QueueState, settings: BuildSlotSettings, pressure: MemoryPressure, waitedForSlot: TimeInterval, waitedForMemory: TimeInterval) -> AcquireStep }`. Rules: free slot and (no holder, or pressure does not block) → `.take(first free)`; free slot, a holder exists, pressure blocks, `waitedForMemory < memoryWaitCapSeconds` → `.waitForMemory`; same past the cap → `.takeAnyway(slot: first free, .memoryCap)`; no free slot and `waitedForSlot < slotWaitCapSeconds` → `.waitForSlot`; past it → `.takeAnyway(slot: nil, .slotCap)` (runs without a lock).
  - `public enum Nesting { static func passesThrough(environment: [String: String], ancestors: [Int32], cwd: String, holders: [SlotRecord], workingTreeRoot: (String) -> String?) -> Bool }`: true when `ARMADA_BUILDSLOT_HOLDER` parses to a pid in `ancestors`; or when some holder's `cwd` is `cwd` or a path-component prefix of it **and** `workingTreeRoot(cwd) == workingTreeRoot(holder.cwd)` (both non-nil).
  - `public enum WaitMessages { static func waitingForSlot(holders: [SlotRecord], busy: Int, total: Int, now: Date) -> String; static func waitingForMemory(_ p: MemoryPressure, remaining: TimeInterval) -> String; static func memoryCapReached(_ p: MemoryPressure, after: TimeInterval) -> String; static func slotCapReached(after: TimeInterval) -> String; static func gotSlot(_ slot: Int, after: TimeInterval) -> String; static func unqueued(_ reason: String) -> String; static func duration(_ t: TimeInterval) -> String }`. `duration`: `< 60` → `"40 s"`, `< 3600` → `"2 min"` or `"3 min 12 s"` when seconds are non-zero, else `"1 h 5 min"`. The holder's command is `argv[0]`'s basename plus the first non-option argument (`swift test`, `xcodebuild test`).

- [ ] **Step 1: Write the failing tests**

`AcquirePolicyTests` (build `QueueState` values by hand):
- `takesFirstFree`: free `[1]`, one holder → `.take(slot: 1)`.
- `firstBuildIgnoresPressure`: no holders, free `[0,1]`, `.critical`, rule `.warning` → `.take(slot: 0)`.
- `waitsOnMemoryWhileOthersBuild`: one holder, free `[1]`, `.warning`, rule `.warning`, waited 0 → `.waitForMemory(.warning)`.
- `memoryCapRunsAnyway`: same, `waitedForMemory: 600` → `.takeAnyway(slot: 1, reason: .memoryCap)`.
- `ruleCriticalIgnoresWarning`: one holder, free `[1]`, `.warning`, rule `.critical` → `.take(slot: 1)`.
- `waitsForSlot`: free `[]` → `.waitForSlot`.
- `slotCapRunsAnyway`: free `[]`, `waitedForSlot: 1800` → `.takeAnyway(slot: nil, reason: .slotCap)`.

`NestingTests`:
- `holderEnvAncestor`: env holder `"500"`, ancestors `[600, 500, 1]` → true.
- `holderEnvNotAncestor`: env `"500"`, ancestors `[600, 1]` → false (leaked variable).
- `holderEnvGarbage`: env `"x"` → false.
- `sameTreeBelowHolder`: holder cwd `/r/apps/apple`, cwd `/r/apps/apple/Packages/K`, both roots `/r` → true.
- `sameTreeStopsAtNestedGit`: holder cwd `/r`, cwd `/r/.claude/worktrees/x`, roots `/r` and `/r/.claude/worktrees/x` → false.
- `siblingFolderQueues`: holder `/r/Packages/A`, cwd `/r/Packages/B` → false.
- `prefixIsByComponent`: holder `/r/app`, cwd `/r/apple` → false.

`WaitMessagesTests`: the spec's example lines exactly, e.g.
`waitingForSlot(holders: [valise (pid 17804, ["swift","test"], started 120 s ago), maquette (pid 11208, ["/usr/bin/xcodebuild","test","-scheme","M"], 40 s ago)], busy: 2, total: 2, now:)` ==
`"buildslot: waiting for a slot (2 of 2 busy), held by valise/land-gate-f764fa9 (pid 17804, swift test, 2 min) and maquette/components (pid 11208, xcodebuild test, 40 s). Queued, not hung."`;
three holders join as `A, B and C`; `waitingForMemory(.warning, remaining: 480)` == `"buildslot: a slot is free; waiting for memory pressure (warning) to ease, runs anyway in 8 min."`; `memoryCapReached(.warning, after: 600)` == `"buildslot: memory pressure still warning after 10 min; running anyway."`; `slotCapReached(after: 1800)` == `"buildslot: no slot after 30 min; running anyway."`; `gotSlot(1, after: 192)` == `"buildslot: got slot 1 after 3 min 12 s."`; `unqueued("cannot write /private/tmp/armada-build-slots-501")` == `"buildslot: cannot write /private/tmp/armada-build-slots-501; running unqueued."`. Slot numbers in messages are the index as stored (slot 1 is `slots/1.lock`).

- [ ] **Step 2: Run them to see them fail** — `swift test --package-path apps/apple/Packages/BuildSlot` → compile failure.

- [ ] **Step 3: Implement the three files**

- [ ] **Step 4: Run them to see them pass**, plus `format-swift-check`.

- [ ] **Step 5: Commit** — `git commit -m "feat(buildslot): acquire policy, nesting rules and the waiting lines"`

---

### Task 4: The `buildslot` executable: acquire loop, child process, signals

**Files:**
- Create: `Sources/BuildSlotCore/RealTool.swift`, `Sources/BuildSlotCore/ProcessTree.swift`
- Create: `Sources/buildslot/Acquirer.swift`, `Sources/buildslot/ChildRunner.swift`, `Sources/buildslot/StatusCommand.swift`
- Modify: `Sources/buildslot/main.swift`
- Create: `Tests/BuildSlotCoreTests/RealToolTests.swift`, `Tests/BuildSlotCoreTests/BinaryTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces:
  - `public enum RealTool { static func resolve(_ tool: Tool, path: String, skipping shimDirectory: String?, helperPath: String, isShim: (String) -> Bool = RealTool.defaultIsShim) -> String }`: walks `path` (`:`-split, empty entries skipped), skips any directory whose `realpath` equals `realpath(shimDirectory)`, skips candidates that are shims (`defaultIsShim` reads the first 256 bytes for the marker) or whose `realpath` is `realpath(helperPath)`, returns the first executable; falls back to `/usr/bin/swift` or `/usr/bin/xcodebuild`.
  - `public enum ProcessTree { static func ancestors(of pid: Int32, maxDepth: Int = 32) -> [Int32]; static func startTime(of pid: Int32) -> Date?; static func executableName(of pid: Int32) -> String? }`: `kinfo_proc` via `sysctl`, as `Armada/ProcessAncestry.swift` does; returns `[]`/nil when the sandbox refuses.
  - CLI (exit 64 on bad usage):
    - `buildslot --as <swift|xcodebuild> [args…]`: if `ARMADA_BUILDSLOT=off`, `!Invocation.queues`, or `Nesting.passesThrough` → `execv` the real tool (pass-through needs no wrapper). Otherwise acquire, then run as a child.
    - `buildslot run -- <cmd> [args…]`: queues regardless of `Invocation`, but applies `ARMADA_BUILDSLOT=off` and `Nesting` like `--as`; runs `cmd` resolved on PATH.
    - `buildslot status [--json]`: `QueueReader.read` plus settings and pressure; `--json` prints `{"settings":…,"pressure":"normal","holders":[…],"waiters":[…]}`.
    - `buildslot install [--bin-dir DIR]` / `uninstall [--bin-dir DIR]`: wired in Task 5.
  - Acquire loop (`Acquirer.acquire(tool:argv:paths:) -> Held`, where `Held` keeps the `LockFile?` alive): load settings, `ensureDirectories()` (failure → `unqueued` line and run without a lock), try `LockFile.tryLock` on each free slot; on wait, create the waiting file by temp-name + lock + write + rename, then poll every 0.5 s with `QueueReader.read(ownPID:)`, `MemoryPressure.current()` and settings reloaded each poll, feeding `AcquirePolicy.decide`. Print the waiting line on the first wait, whenever the set of holder pids changes, and every 60 s. On taking: write the holder record (`startedAt` now, `processStart` from `ProcessTree.startTime(of: getpid())`, label from `HolderLabel`, argv truncated), delete the waiting file, print `gotSlot` only if it waited.
  - Child run (`ChildRunner.run(path:arguments:environment:) -> Never`): `posix_spawn` with the environment plus `ARMADA_BUILDSLOT_HOLDER=<getpid()>`, same process group; while it runs set SIGINT and SIGQUIT to `SIG_IGN` and forward SIGTERM and SIGHUP to the child (`sigaction` handler doing `kill(child, sig)`); `waitpid` retrying on `EINTR`; then exit as the spec says: exit code passed on; INT/TERM/HUP/KILL/PIPE re-raised after resetting to default; ABRT/SEGV/BUS/ILL/TRAP/FPE/QUIT → `exit(128 + sig)`.

- [ ] **Step 1: Write the failing tests**

`RealToolTests` (temp dirs with fake executables):
- `skipsShimDirectory`: PATH `shimDir:realDir`, both with `swift` → `realDir/swift`.
- `skipsMarkerShimElsewhere`: PATH `otherDir:realDir`, `otherDir/swift` carries the marker → `realDir/swift`.
- `skipsSymlinkToHelper`: `otherDir/swift` → symlink to the helper path → skipped.
- `fallsBackToUsrBin`: empty PATH → `/usr/bin/swift`.

`BinaryTests`. The built binary sits beside the test bundle: `Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }!.bundleURL.deletingLastPathComponent().appending(path: "buildslot")`. Every test sets `ARMADA_BUILDSLOT_DIR` to a fresh temp dir and `ARMADA_BUILDSLOT_SETTINGS` to a written file with `slots: 1`, `memoryRule: off`, and runs `buildslot run -- /bin/sh -c '<script>'`:
- `secondWaitsAndSaysWhy`: start A (`sleep 2`) from cwd `/tmp/a-repo`; once `status --json` shows a holder, start B; B's stderr contains `waiting for a slot (1 of 1 busy), held by a-repo (pid <A's pid>` and `Queued, not hung.`; B finishes after A, and its stderr contains `got slot 0 after`.
- `killNineFreesAtOnce`: A holds (`sleep 30`); B waits; `kill -9` A's buildslot pid; B prints `got slot 0` within 1.5 s.
- `exitCodePassesThrough`: `sh -c 'exit 7'` → 7.
- `signalDeathReRaised`: `sh -c 'kill -TERM $$'` → process terminated by SIGTERM.
- `crashSignalBecomesExitCode`: `sh -c 'kill -ABRT $$'` → exit status 134, not signalled.
- `interruptReachesChildOnce`: child script traps INT, appends a line per INT to a file, then exits 130 after 1 s; send SIGINT to the **process group** (`kill(-pgid, SIGINT)`, run the binary in its own group via `posix_spawnattr_setpgroup`) → file has exactly one line; buildslot exits 130.
- `termForwarded`: send SIGTERM to buildslot's pid only → child receives it (trap writes a line), buildslot ends by SIGTERM or the child's code.
- `nestedPassesThrough`: with slots 1, `buildslot run -- sh -c "$BUILDSLOT run -- /bin/echo inner"` (`BUILDSLOT` set to the binary's path) → prints `inner` within 5 s with no `waiting` line: the inner call sees `ARMADA_BUILDSLOT_HOLDER` naming an ancestor. (`run` applies the nesting rules as `--as` does.)
- `passThroughNeverWaits`: with slots 1 held by another process, `buildslot --as swift build --show-bin-path` (cwd a temp SwiftPM-less dir is fine; assert only that stderr has no `buildslot:` line and it returns within 10 s).
- `unwritableLockDirRunsUnqueued`: `ARMADA_BUILDSLOT_DIR=/System/forbidden` → stderr has `; running unqueued.` and the child's exit code passes through.
- `statusJSON`: with one holder, `status --json` decodes and lists it with `slot: 0`.

- [ ] **Step 2: Run them to see them fail** — `swift test --package-path apps/apple/Packages/BuildSlot` → failures (binary prints usage).

- [ ] **Step 3: Implement the files**

- [ ] **Step 4: Run them to see them pass**; run the suite three times in a row to catch timing flakes (`for i in 1 2 3; do swift test --package-path apps/apple/Packages/BuildSlot || break; done`). Then `format-swift-check`.

- [ ] **Step 5: Commit** — `git commit -m "feat(buildslot): the acquire loop, the child process and its signals"`

---

### Task 5: Shims and their installer

**Files:**
- Create: `Sources/BuildSlotCore/ShimInstaller.swift`
- Modify: `Sources/buildslot/main.swift` (wire `install` / `uninstall`)
- Create: `Tests/BuildSlotCoreTests/ShimInstallerTests.swift`

**Interfaces:**
- Produces:
  - `public enum ShimInstaller { static let marker: String /* the Global Constraints line, without "# " */; static func script(for tool: Tool, helperPath: String) -> String; static func install(binDir: URL, helperPath: String) -> InstallReport; static func uninstall(binDir: URL) -> [Tool]; static func installedHelperPath(binDir: URL, tool: Tool) -> String? }`
  - `public struct InstallReport: Equatable, Sendable { var written: [Tool]; var unchanged: [Tool]; var refused: [Tool] /* a file without the marker */; var error: String? }`
  - The script is the spec's `sh` shape with the helper path single-quoted (a `'` in the path escaped as `'\''`), `--as <tool>`, the PATH walk fallback, and `exec /usr/bin/<tool> "$@"` last. Files written `0755`, atomically (temp + rename). `install` creates `binDir` if missing.

- [ ] **Step 1: Write the failing tests**
- `writesBothShims`: empty dir → `written == [.swift, .xcodebuild]`, files executable, first two lines are `#!/bin/sh` and the marker line.
- `secondInstallUnchanged`: same helper → `unchanged == [.swift, .xcodebuild]`.
- `repointsMovedHelper`: install with `/A/buildslot`, then `/B/buildslot` → `written` both; `installedHelperPath` == `/B/buildslot`.
- `installRefusesForeignFile`: a `swift` without the marker → `refused == [.swift]`, file content unchanged, `xcodebuild` written.
- `uninstallKeepsForeignFile`: foreign `swift` + our `xcodebuild` → `uninstall` returns `[.xcodebuild]`, foreign file still there.
- `quotesHelperPath`: helper `/tmp/it's here/buildslot` → running the shim with a fake helper at that path that echoes `$@` prints `--as swift build`.
- `shimRunsHelper`: helper is a script echoing `HELPER $@`; run `binDir/swift test` with `PATH=binDir:/usr/bin` → stdout `HELPER --as swift test`.
- `shimFallsBackWhenHelperMissing`: helper path does not exist; `realDir/swift` is a script echoing `REAL $@`; PATH `binDir:realDir` → stdout `REAL build`, exit 0.
- `shimFallbackSkipsItselfViaSymlinkedDir`: PATH holds a symlink to `binDir` before `realDir` → still `REAL build`.

- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement, and wire `buildslot install|uninstall [--bin-dir DIR]`** (default `~/.local/bin`; prints one line per tool: `wrote`, `unchanged`, `left alone: not written by Armada`). `install` uses the binary's own `realpath` as the helper path.
- [ ] **Step 4: Run them to see them pass**, plus `format-swift-check`.
- [ ] **Step 5: Commit** — `git commit -m "feat(buildslot): sh shims that fall back to the real tool, and their installer"`

---

### Task 6: Ship the helper inside Armada.app

**Files:**
- Modify: `apps/apple/Armada.xcodeproj/project.pbxproj`
- Modify: `Makefile` (root: `sign` target; a `RELEASE_HELPER` variable)
- Modify: `apps/apple/Makefile` only if needed (comment on `test` naming the new package)

**Interfaces:**
- Produces: `Armada.app/Contents/Helpers/buildslot` in Debug and Release builds; the app target can `import BuildSlotCore`.

Wiring, in the pbxproj's hand-numbered style (`0FA8DA…` ids, next free numbers):
- `XCLocalSwiftPackageReference "Packages/BuildSlot"` in the project's package list.
- Product dependencies `BuildSlotCore` for the **Armada** target (Frameworks phase) and for a new target.
- New `PBXNativeTarget` **buildslot**, `com.apple.product-type.tool`, with a `PBXFileSystemSynchronizedRootGroup` at `Packages/BuildSlot/Sources/buildslot`, build settings `PRODUCT_NAME = buildslot`, `SKIP_INSTALL = YES`, `ENABLE_HARDENED_RUNTIME = YES`, `MACOSX_DEPLOYMENT_TARGET` as the app's, signing and Swift language settings as the app target's, except `SWIFT_DEFAULT_ACTOR_ISOLATION`, left at its nonisolated default (do not copy the app's MainActor default).
- Armada target: a `PBXTargetDependency` on **buildslot**, and a `PBXCopyFilesBuildPhase` "Embed Helpers" with `dstSubfolderSpec = 1` (wrapper), `dstPath = Contents/Helpers`, the tool product with `CodeSignOnCopy`.
- Root `Makefile` `sign`: `RELEASE_HELPER = $(RELEASE_APP)/Contents/Helpers/buildslot`; a `test -x` guard with the other two; `codesign --force --options runtime --timestamp --sign "$$id" "$(RELEASE_HELPER)"` after ArmadaSpeech and before the app wrapper; the comment's inside-out list gains it.

- [ ] **Step 1: Build and check the bundle**

Run: `make -C apps/apple build && ls -l apps/apple/.build/Build/Products/Debug/Armada.app/Contents/Helpers/buildslot && apps/apple/.build/Build/Products/Debug/Armada.app/Contents/Helpers/buildslot status`
Expected: build succeeds; the file exists; `status` prints an empty queue.

- [ ] **Step 2: Check the release path's signing**

Run: `make bundle` (unsigned build + `sign`; a local Apple Development identity is fine) then `codesign -dv --verbose=2 apps/apple/.build/Build/Products/Release/Armada.app/Contents/Helpers/buildslot 2>&1 | grep -E 'flags=.*runtime'` and `codesign --verify --deep --strict apps/apple/.build/Build/Products/Release/Armada.app`.
Expected: the runtime flag on the helper; verify passes.

- [ ] **Step 3: Network audit and tests**

Run: `make audit` and `make test` (root).
Expected: both pass (the helper opens no socket).

- [ ] **Step 4: Commit** — `git commit -m "build: ship buildslot in Armada.app/Contents/Helpers and sign it"`

---

### Task 7: The app side: settings, shims at launch, the monitor, the Settings pane

**Files:**
- Create: `apps/apple/Armada/BuildSlots.swift` (`@MainActor @Observable final class BuildSlots`: the switch, the settings file, shim install, the PATH check)
- Create: `apps/apple/Armada/BuildSlotMonitor.swift` (`@MainActor @Observable`: polling and matching)
- Create: `apps/apple/Armada/BuildSlotsPane.swift`
- Create: `apps/apple/Packages/BuildSlot/Sources/BuildSlotCore/SessionMatch.swift` and `Tests/BuildSlotCoreTests/SessionMatchTests.swift`
- Modify: `apps/apple/Armada/SettingsWindow.swift` (a `buildSlots` case: title "Build Slots", symbol `hammer`, group `.configuration`, after `.supervisor`)
- Modify: `apps/apple/Armada/ArmadaApp.swift` (`applicationDidFinishLaunching`: `BuildSlots.shared.launch()`)

**Interfaces:**
- Consumes: `BuildSlotSettings`, `BuildSlotPaths`, `QueueReader`, `MemoryPressure`, `ShimInstaller`, `HolderLabel`, `ProcessTree` (Tasks 2–5); `ProcessAncestry`, `LoginShell`, `Accounts.shared`, `CodexAccounts.shared`, `GrokAccounts.shared` (app).
- Produces:
  - `public struct MatchCandidate: Sendable, Equatable { id: String; vendor: String /* "claude" | "codex" | "grok" */; pid: Int32?; cwd: String; title: String }`
  - `public enum SessionMatch { static func match(ancestors: [Int32], ancestorNames: [String], holderCwd: String, candidates: [MatchCandidate]) -> MatchCandidate? }`: first ancestor equal to a candidate's `pid` wins; else, if any ancestor name is `codex`, the Codex candidate whose `cwd` equals or is a component prefix of `holderCwd`, deepest first, only when exactly one has that depth; else nil.
  - `BuildSlots.shared`: `isEnabled: Bool` (`@AppStorage`-backed key `armada.buildSlots.enabled`, default false), `settings: BuildSlotSettings` (didSet writes the file via `StoreFile.write`), `installReport: InstallReport?`, `pathWarning: String?`, `func launch()`, `func setEnabled(_:)`. `launch()` installs only when `Bundle.main.bundleIdentifier == "io.mgcrea.armada"` and enabled; turning the switch off uninstalls (any bundle, marker-only). Helper path: `Bundle.main.bundleURL/Contents/Helpers/buildslot`.
  - `BuildSlotMonitor.shared`: `holders: [MonitoredEntry]`, `waiters: [MonitoredEntry]`, `pressure: MemoryPressure`, `func entry(forSession id: String) -> MonitoredEntry?`; `struct MonitoredEntry: Identifiable, Equatable { id: Int32 /* pid */; slot: Int?; record: SlotRecord; session: MatchCandidate?; var isHolding: Bool; waitsOnMemory: Bool /* a waiter while the read's freeSlots is non-empty */ }`. Polls every 2 s on a background task while `BuildSlots.shared.isEnabled` or the lock directory has any file; reads with `sweep: true`; matches with `SessionMatch` over the three account stores' live sessions.

- [ ] **Step 1: Write the failing `SessionMatchTests`**
- `claudeByPid`: ancestors `[700, 650, 1]`, candidate claude pid 650 → it.
- `grokByPid`: same with a grok candidate.
- `codexByCwd`: no pid match, names contain `codex`, one Codex candidate at `/r` and holder cwd `/r/apps/apple` → it.
- `codexAmbiguous`: two Codex candidates both at `/r` → nil.
- `codexDeepestWins`: candidates at `/r` and `/r/apps` → `/r/apps`.
- `noCodexAncestorNoCwdMatch`: names lack `codex` → nil even with a Codex cwd match.
- `prefixByComponent`: candidate `/r/app`, holder `/r/apple` → nil.

- [ ] **Step 2: Run them to see them fail**, then implement `SessionMatch`, run them to pass.

- [ ] **Step 3: Implement `BuildSlots`, `BuildSlotMonitor` and the pane**

Pane rows (house style of `SupervisorPane`/`ArchivePane`): "Queue builds" toggle; "Slots" stepper 1–8; "Memory" picker with labels Off / Wait while critical / Wait while under pressure; the PATH warning (`~/.local/bin` must come before `/usr/bin` on your shell's PATH) when `LoginShell`'s PATH fails the check; a refusal line per `installReport.refused` tool ("~/.local/bin/swift was not written by Armada, so it was left alone."); a list of holders and waiters (label, command, age, session title or "Terminal"); the footnote: "Xcode's own builds, `xcrun swift` and `swift run` don't queue." While the bundle is the Debug one, a line: "Debug builds don't install the shims; run this build's `Contents/Helpers/buildslot install` to test them."

- [ ] **Step 4: Build and check**

Run: `make -C apps/apple build && swift test --package-path apps/apple/Packages/BuildSlot && make -C apps/apple format-swift-check`
Expected: all pass. Verify the pane by reading the code paths, not by driving the app (memory: don't steal focus).

- [ ] **Step 5: Commit** — `git commit -m "feat(app): Build Slots settings, shim install at launch, and the queue monitor"`

---

### Task 8: Rows and popover

**Files:**
- Create: `apps/apple/Armada/BuildSlotBadge.swift` (`struct BuildSlotBadge: View { let entry: MonitoredEntry; let now: Date }`)
- Modify: `apps/apple/Armada/SessionsPane.swift` (`SessionRow`), `apps/apple/Armada/CodexPane.swift` (`CodexSessionRow`), `apps/apple/Armada/GrokPane.swift` (`GrokSessionRow`), each row's detail pane (one "Build" line), and `StatusMenu` in `apps/apple/Armada/ArmadaApp.swift`

**Interfaces:**
- Consumes: `BuildSlotMonitor.shared.entry(forSession:)`, `MonitoredEntry`, `WaitMessages.duration`.

Copy: holding → `building · 2 min`; waiting for a slot → `waiting for a slot · 40 s`; waiting with a free slot (memory) → `waiting on memory · 40 s`. The badge sits in the row's caption line after the project, styled like the row's existing caption items, white on a selected row as `SessionRowFigures` does. The detail pane line: `Building: swift test (slot 1, 6 min)` or `Waiting for a slot: swift test (40 s)`. Popover: one `SummaryRow`-style line while the feature is on: `Build slots 2/2 · 1 waiting` (`n/total` held over slots; ` · k waiting` only when k > 0). Waiting on memory is `MonitoredEntry.waitsOnMemory` (Task 7).

- [ ] **Step 1: Implement the badge and its four uses**
- [ ] **Step 2: Build** — `make -C apps/apple build && make -C apps/apple format-swift-check` → pass.
- [ ] **Step 3: Commit** — `git commit -m "feat(app): show building and waiting on session rows and in the popover"`

---

### Task 9: MCP: `armada_get_build_slots` and `buildSlot` on sessions

**Files:**
- Create: `apps/apple/Packages/ArmadaMCP/Sources/ArmadaMCP/BuildSlotsSnapshot.swift`
- Modify: `apps/apple/Packages/ArmadaMCP/Sources/ArmadaMCP/FleetSource.swift`, `Tools.swift`
- Create: `apps/apple/Packages/ArmadaMCP/Tests/ArmadaMCPTests/BuildSlotsToolTests.swift`
- Modify: `apps/apple/Packages/ArmadaMCP/Tests/ArmadaMCPTests/FakeFleetSource.swift`, `ToolsTests.swift` (tool lists)
- Modify: `apps/apple/Armada/FleetBridge.swift`

**Interfaces:**
- Produces:
  - `public struct BuildSlotsSnapshot: Sendable { enabled: Bool; slots: Int; memoryRule: String; memoryPressure: String; holders: [Entry]; waiters: [Entry]; public struct Entry: Sendable { slot: Int?; pid: Int32; label: String; cwd: String; tool: String; argv: [String]; since: Date; waitsOnMemory: Bool; session: SessionRef? }; public struct SessionRef: Sendable { id: String; vendor: String; title: String } }` and `static let empty`.
  - `FleetSource.buildSlots() async -> BuildSlotsSnapshot`, with a protocol-extension default returning `.empty` (so existing fakes compile); `FleetBridge` implements it from `BuildSlotMonitor.shared` and `BuildSlots.shared`. `ArmadaMCP` does not import `BuildSlotCore`.
  - Tool `armada_get_build_slots`, read-only, added to `readToolNames` after `armada_wait`, no arguments. Description: "The machine-wide build queue: how many builds and test runs may run at once, the memory rule, the Mac's memory pressure now, and who holds each slot and who waits, with the session behind each when Armada can tell. `swift build`, `swift test` and `xcodebuild` builds and tests wait for a slot when the person turned Build Slots on. Check this before starting a long build or test suite; when every slot is busy, do other work first." Lede: `"Build slots off."` when disabled; else `"<held> of <slots> slots busy, <k> waiting; memory pressure <word>."`. Payload: `enabled`, `slots`, `memoryRule`, `memoryPressure`, `holders`, `waiters`, each entry `{slot?, pid, label, cwd, tool, argv, since (ISO 8601), waitsOnMemory, session?: {id, vendor, title}}`.
  - `armada_get_fleet` and `armada_get_session` add `"buildSlot": {"state": "holding"|"waiting", "since", "tool"}` to a session whose id appears in `buildSlots()`'s entries; absent otherwise. One extra `await source.buildSlots()` per call.

- [ ] **Step 1: Write the failing tests** (`BuildSlotsToolTests`, against `FakeFleetSource` given a `buildSlots` value):
- `listedAsRead`: `readToolNames` contains `armada_get_build_slots`; it is not in `writeTools`; listed with writes off.
- `offLede`: `.empty` → lede `Build slots off.`, `enabled: false`.
- `holdersAndWaiters`: one holder (slot 0, session claude `abc`), one waiter on memory → lede `1 of 2 slots busy, 1 waiting; memory pressure warning.`; payload entries carry the fields above.
- `fleetSessionCarriesBuildSlot`: fleet with Claude session `abc`, buildSlots holder for `abc` → that session's object has `buildSlot.state == "holding"`; another session has no `buildSlot` key.
- `getSessionCarriesWaiting`: `armada_get_session` for a waiting Codex session → `buildSlot.state == "waiting"`.

- [ ] **Step 2: Run them to see them fail** — `swift test --package-path apps/apple/Packages/ArmadaMCP` → compile failure.
- [ ] **Step 3: Implement** the snapshot, the default, the tool, the two session additions, the fake's field, and the bridge.
- [ ] **Step 4: Run** `swift test --package-path apps/apple/Packages/ArmadaMCP`, `make -C apps/apple build`, `format-swift-check` → pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(mcp): armada_get_build_slots, and the build slot on each session"`

---

### Task 10: Docs

**Files:**
- Modify: `docs/implementation.md` ("What it does" bullet; table rows for `BuildSlot` package, `BuildSlots`, `BuildSlotMonitor`, `BuildSlotsPane`, `BuildSlotBadge`; a "Where build slots are thin" section under Known gaps listing the spec's documented limits verbatim; a "Verifying it against reality" snippet: `buildslot status --json`, the three-worktree check)
- Modify: `docs/README.md` status paragraph only if it lists features (one clause)
- Modify: the supervisor brief or MCP instructions text in `Tools.swift`/`MCPServerController.swift` only if it enumerates the read tools by name (search for `armada_wait` in prose)

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Check** — `rg -n "armada_get_build_slots|buildslot" docs` shows the new sections; `make test` (root) passes.
- [ ] **Step 3: Commit** — `git commit -m "docs: build slots — what is built, its limits, and how to verify it"`

---

### Task 11: End-to-end check (no code unless it fails)

Run with the Debug bundle's helper pointed at by the shims: `apps/apple/.build/Build/Products/Debug/Armada.app/Contents/Helpers/buildslot install`, settings written with `slots: 2` (via the Debug app's pane or by writing the settings file). Afterwards `buildslot uninstall`, so nothing of the branch stays installed.

- [ ] **1.** Three `swift test` runs from three worktrees of one repo (create throwaway worktrees of this repo under `.claude/worktrees/bs-e2e-{1,2,3}` running `swift test --package-path apps/apple/Packages/ArmadaSupervisor`): two run, the third prints the waiting line naming both holders.
- [ ] **2.** `kill -9` one holder's `buildslot` pid: the waiter prints `got slot` within a second.
- [ ] **3.** While they run: the Debug app's rows show `building ·` / `waiting for a slot ·` on the sessions that started them, and `armada_get_build_slots` (Debug MCP endpoint, as in `docs/implementation.md`'s curl recipe) lists the same holders and waiter.
- [ ] **4.** `make test-all` in `~/Projects/apps/maquette/apps/apple` runs through without deadlock (stderr shows no wait longer than other activity explains).
- [ ] **5.** `swift build --show-bin-path` and `xcodebuild -version` return at once while both slots are busy.
- [ ] **6.** From a Codex session (`workspace-write`), `swift test` in a repo takes a slot (`buildslot status` shows it) rather than printing `running unqueued`.
- [ ] **7.** Rename the Debug `Armada.app` aside: `swift --version` and `swift build` in a package run the real tool. Rename it back.
- [ ] Remove the throwaway worktrees; `buildslot uninstall`; report each result with its output.
