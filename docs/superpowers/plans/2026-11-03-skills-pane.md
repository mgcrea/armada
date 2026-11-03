# Skills Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Skills pane in Armada's main window: every skill used across every project and account, with one skill's totals, per-project and per-account splits, and its recent uses.

**Architecture:** The totals and splits are pure roll-ups of the `[SkillTally]` that `UsageIndex.projectSkills(store:)` already memoises. Recent uses come from a read-only query on a SQLite connection of its own, so WAL lets it run while a pass holds the indexer actor. The pane copies `ProjectsPaneView`'s list-and-detail split, and `MainWindowRoute` handles the click-throughs.

**Tech Stack:** Swift 6, SwiftUI on macOS 26, main-actor default isolation, SQLite3 through `UsageDatabase`. The tests are `make -C apps/apple unit` (swiftc-built `UnitChecks/UnitCheck.swift`).

**Spec:** `docs/superpowers/specs/2026-11-03-skills-pane-design.md`

## Global Constraints

- Work in the main checkout on `main`: no worktree, no branch switch. Stage only your own files, and commit each task when it's green.
- Xcode groups are file-system synchronized: a new file under `apps/apple/Armada/` needs no pbxproj edit. A file the unit checks compile must be added to `UNIT_SRC` in `apps/apple/Makefile`.
- Match the surrounding code: its doc-comment density and its bold-lead paragraphs ("**Why.** …"), `.formatted()` for counts, and `LabeledContent` rows in a grouped `Form`.
- The UI copy is the spec's: "Skills", "Outside saved projects", "(n typed)". Built-ins are never listed.
- Never launch or drive the app to verify. `make build` and reading the code are the UI check.
- Before each commit, run `make format-swift-check` from the repo root. Swift formatting is enforced in CI.
- Any `CHANGELOG.md` edit is followed by `make changelog`, from the repo root, in the same commit. `make changelog-check` must pass.

## Review Focus

1. **A pass is running when the pane opens.** The first pass holds the indexer actor for minutes. Recent uses must still load, so they never go through the actor. Covered by Task 2's design (its own read-only connection). The reviewer checks that no `await indexer.` appears in the path.
2. **The ledger file doesn't exist yet** (fresh install, or a locked app). Recent uses come back empty, and the query never creates the file. Covered by Task 2's check "a missing ledger gives nothing and is not created".
3. **The selected skill has no use in the new window, or it stopped being listed** because its files were deleted and it now reads as a built-in. The detail says "No uses in this window." instead of keeping the last figures. Covered by Task 1's check "a skill with no use in the window has no summary", plus a guard in Task 3.
4. **A use outside every saved project, or from an account no longer on this Mac.** It still shows: "Outside saved projects" in By project, and the folder path in By account. Covered by Task 1's nil-project check, plus `accountName` reuse in Task 3.
5. **Long or multi-line args and replies.** They're cut to two lines in the row, with the full text in the `.help` tooltip. This is reviewed in Task 3. The stored excerpts are already 500 characters or fewer.

---

### Task 1: Roll-ups for one skill and for every skill

**Files:**
- Modify: `apps/apple/Armada/SkillStats.swift` (append after `SkillStats.compute`)
- Test: `apps/apple/UnitChecks/UnitCheck.swift`, in the `SkillStats` checks, after the `SkillStats.compute` section (around line 3110)

**Interfaces:**
- Consumes: `SkillTally`, `SkillSource`, `StatsWindow` (existing).
- Produces:
  ```swift
  /// One skill in one window, summed across projects and accounts.
  nonisolated struct SkillSummary: Hashable, Sendable, Identifiable {
    let skill: String          // also `id`
    let source: SkillSource
    let auto: Int
    let slash: Int
    let lastAt: Date
    var total: Int { auto + slash }
    var id: String { skill }
  }
  /// One project's or one account's share of a skill's uses.
  nonisolated struct SkillShare: Hashable, Sendable {
    let key: String?           // project id (nil = outside saved projects) or account id
    let total: Int
    let slash: Int
  }
  extension SkillStats {
    /// Every skill used in `window`, built-ins left out, most used first, then by name.
    static func summaries(_ tallies: [SkillTally], window: StatsWindow) -> [SkillSummary]
    /// `skill`'s uses in `window` per project, most first; ties by key, nil last.
    static func byProject(_ tallies: [SkillTally], skill: String, window: StatsWindow) -> [SkillShare]
    /// `skill`'s uses in `window` per account, most first; ties by key.
    static func byAccount(_ tallies: [SkillTally], skill: String, window: StatsWindow) -> [SkillShare]
  }
  ```

- [ ] **Step 1: Write the failing checks.** Add `section("SkillStats summaries and shares")`. Reuse the `tallies` fixture the `SkillStats.compute` section builds, from the same rows, today and `utc`. Use `expectEqual`:
  - "every skill in the window, built-ins left out": `SkillStats.summaries(tallies, window: .all).map(\.skill) == ["tdd"]`. `compact` is a builtin in the fixture, so it's left out.
  - "summed across projects and accounts": `.week` summary for `tdd`, `[auto, slash] == [2, 7]`. The week rows are 1 auto in outer, 4 slash on /b in outer, 1 auto in inner, 1 auto in armada-old (nil), and 2 slash in ~tmp (nil). That's auto 1+1+1 = 3 and slash 4+2 = 6. **Recompute from the fixture when writing the check, and assert the figures the fixture yields.** The point is that the summary equals the sum over every project and account.
  - "last used is the newest across projects": `.all` summary `lastAt == date("2026-11-03T09:00:00Z")`.
  - "most used first, then by name": build `[SkillTally]` by hand, with `b` total 3, `a` total 3 and `c` total 5, all `.week`, `.skill`. Check `summaries(...).map(\.skill) == ["c", "a", "b"]`.
  - "a skill with no use in the window has no summary": `summaries(tallies, window: .week)` does not contain `compact`, and the hand-built list gives `[]` for `.month` when every tally is `.week`.
  - "per project, outside saved projects last": `byProject(tallies, skill: "tdd", window: .week).map(\.key)` has `nil` last, and the `outer` share's `total` equals the sum of outer's week tallies over both accounts.
  - "per account": `byAccount(tallies, skill: "tdd", window: .week).map(\.key)` contains `"/b"` and `"/Users/x/.claude"`, most first.
- [ ] **Step 2: Run `make -C apps/apple unit`.** Expected: a compile failure, because `summaries`, `byProject` and `byAccount` aren't defined.
- [ ] **Step 3: Implement the two structs and three functions** in `SkillStats.swift`, under `SkillStats.compute`, with doc comments in the file's style. `summaries` filters `window` and `source != .builtin`, sums `auto` and `slash`, and takes the max `lastAt`. Both share functions filter `skill` and `window`, and sum `total` and `slash` per key.
- [ ] **Step 4: Run `make -C apps/apple unit`.** Expected: every check passes, with the count above 928.
- [ ] **Step 5: Commit** `feat(skills): roll skill tallies up per skill, project and account`.

### Task 2: Recent uses, read beside the pass

**Files:**
- Modify: `apps/apple/Armada/UsageDatabase.swift`, `init(url:)` → `init(url:readOnly:)`
- Modify: `apps/apple/Armada/UsageLedger.swift`, add `SkillUseRecord` beside `SkillUsageRow`
- Modify: `apps/apple/Armada/UsageIndexer.swift`, add a `nonisolated static func recentSkillUses` near `buildSnapshot`
- Modify: `apps/apple/Armada/UsageIndex.swift`, add `recentSkillUses(skill:window:)`
- Test: `apps/apple/UnitChecks/UnitCheck.swift`, in `skillIndexer()`, after the reply checks (around line 1810)

**Interfaces:**
- Consumes: the `skill_uses` columns `use_id, day, cwd, account, skill, kind, session_id, at, args, reply` (schema 2), and `StatsWindow.floor(today:calendar:)`.
- Produces:
  ```swift
  // UsageDatabase.swift
  /// `readOnly` opens without CREATE and sets no pragmas: a reader beside the indexer's
  /// connection, which never creates the file and never changes the journal mode.
  init(url: URL, readOnly: Bool = false) throws

  // UsageLedger.swift
  /// One use of a skill, as the ledger keeps it: for the Skills pane's recent list.
  nonisolated struct SkillUseRecord: Hashable, Sendable, Identifiable {
    let id: String        // use_id
    let at: Date
    let cwd: String
    let account: String
    let kind: SkillKind
    let sessionID: String
    let args: String?
    let reply: String?
  }

  // UsageIndexer.swift
  /// The newest `limit` uses of `skill` on or after `sinceDay`, newest first, read on a
  /// connection of its own. Empty when the ledger is missing or unreadable.
  nonisolated static func recentSkillUses(
    at url: URL, skill: String, sinceDay: Int, limit: Int
  ) -> [SkillUseRecord]

  // UsageIndex.swift (main actor)
  /// The Skills pane's recent uses, read off the main actor. 20 at most.
  func recentSkillUses(skill: String, window: StatsWindow) async -> [SkillUseRecord]
  ```
  `UsageIndex.recentSkillUses` resolves the URL from `AppInfo.supportDirectory` and `Self.fileName`, returning `[]` when it's nil. It computes `sinceDay = window.floor(today: AppClock.now, calendar: .current)` on the main actor, then runs the static function in `Task.detached(priority: .userInitiated)`. It never touches `indexer`.

- [ ] **Step 1: Write the failing checks** in `skillIndexer()`. Use the `mainURL` ledger, after the first pass over `session`. It holds `code-health` typed (`u1`) and auto (`toolu_1`), and `simplify` auto (`toolu_2`, whose reply is "no, not that one").
  - "recent uses are the skill's own, newest first": `UsageIndexer.recentSkillUses(at: mainURL, skill: "code-health", sinceDay: .min, limit: 20).map(\.kind) == [.auto, .slash]`. The tool line is stamped 21:51:53 and the slash line 21:50:00.
  - "the reply and args are carried": for `simplify`, `.first?.reply == "no, not that one"`. Then add a session written with `slashLine(name: "push-testflight-build", uuid: "u9", args: "armada mac", session: "s9")` to a new file, pass again, and check that `.first?.args == "armada mac"`.
  - "limit holds": `limit: 1` gives a count of 1, and it's the newest.
  - "a day floor leaves older uses out": `sinceDay: 20_261_025` gives `[]`, since the fixture days are 2026-10-24.
  - "a missing ledger gives nothing and is not created": call it with `root.appending(path: "absent.sqlite")`, then check that the result is empty and that `FileManager.default.fileExists` is false.
  - "read while the indexer holds its own connection": the call above runs while `indexer` (still alive, connection open) owns `mainURL`, so a passing check already shows that two connections coexist. No extra check is needed. Keep `indexer` alive across these calls.
- [ ] **Step 2: Run `make -C apps/apple unit`.** Expected: a compile failure, because `recentSkillUses` isn't defined.
- [ ] **Step 3: Implement.**
  - **`UsageDatabase.init(url:readOnly:)`:** `readOnly` uses `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`, keeps `sqlite3_busy_timeout`, and skips both pragmas. Update the class comment ("`UsageIndexer` owns the only instance") to name the read-only readers.
  - **The SQL:** `SELECT use_id, at, cwd, account, kind, session_id, args, reply FROM skill_uses WHERE skill = ? AND day >= ? ORDER BY at DESC, use_id LIMIT ?`.
  - **`recentSkillUses`:** opens, queries and closes, and any thrown error gives `[]`. A row with an unknown `kind` is skipped.
- [ ] **Step 4: Run `make -C apps/apple unit`.** Expected: every check passes.
- [ ] **Step 5: Run `make build`** from the repo root. Expected: `** BUILD SUCCEEDED **`, so the `UsageIndex` wrapper compiles in the app.
- [ ] **Step 6: Commit** `feat(skills): read a skill's recent uses beside the pass`.

### Task 3: The pane, its sidebar row and the click-throughs

**Files:**
- Create: `apps/apple/Armada/SkillsPane.swift`
- Modify: `apps/apple/Armada/MainWindow.swift`: `SidebarItem.skills`, the `"skills"` token, the sidebar row, the `detail` switch, `resolved`
- Modify: `apps/apple/Armada/MainWindowRoute.swift`: `open(skill:)`
- Modify: `apps/apple/Armada/ProjectUsageSection.swift`: the skill rows become click-throughs, and `skillsFooter` and `accountName` move to shared helpers
- Modify: `CHANGELOG.md`, `README.md` (the Skills Status row), then regenerate `apps/apple/Armada/Changelog.swift` with `make changelog`

**Interfaces:**
- Consumes:
  - `SkillStats.summaries` / `byProject` / `byAccount`, `SkillSummary` and `SkillShare` (Task 1);
  - `UsageIndex.recentSkillUses(skill:window:)` and `SkillUseRecord` (Task 2);
  - `UsageIndex.projectSkills(store:)`, `ProjectStore.project(id:)` / `.candidates`, and `ProjectPath.deepest(for:in:)`;
  - `MainWindowRoute.open(project:)` and `takeSession(in:)`.
- Produces:
  - `SidebarItem.skills`, stored as `"skills"`;
  - `MainWindowRoute.open(skill name: String)`, which is `open(.skills, session: name)`;
  - `struct SkillsPaneView: View`.

- [ ] **Step 1: Make the shared helpers** in `ProjectUsageSection.swift`. Move the skills footer text into `extension UsageLedgerSnapshot { var skillsFooter: String }`, with the same text and the same backfill clause. Move the account naming into a free `@MainActor func usageAccountName(_ id: String, vendor: UsageVendor?) -> String` with the same three cases. `ProjectUsageSection` calls both, and its behaviour is unchanged.
- [ ] **Step 2: Add the sidebar item and the route.**
  - In `MainWindow.swift`, add a `.skills` case with a doc comment, and a `skillsToken = "skills"` in both `stored` and `init?(stored:)`.
  - Add the row `Label("Skills", systemImage: "wand.and.sparkles").tag(SidebarItem.skills)` after Projects, listed only while `!UsageIndex.shared.ledger.skills.isEmpty`. Hold the index in an `@State` like the other stores.
  - In `resolved`: `case .skills where hasSkills: .skills`. In `detail`: `case .skills: SkillsPaneView()`.
  - Update every other exhaustive `switch` over `SidebarItem` that the build finds.
  - In `MainWindowRoute.swift`, add `open(skill:)` with a one-line doc comment, mirroring `open(project:)`.
- [ ] **Step 3: Build `SkillsPaneView`** in `SkillsPane.swift`, shaped like `ProjectsPaneView`:
  - **Layout:** `HSplitView` with `GeometryReader`s at the same widths, `navigationTitle("Skills")`, and a subtitle like "12 skills" from `.formatted()`.
  - **Selection:** `@AppStorage("armada.selectedSkill")`, with `applyRoute()` on `.onAppear` and `.onChange(of: route.token)` using `takeSession(in: .skills)`.
  - **Left:** a segmented `Picker` bound to `StatsWindow.defaultsKey` above a `List(selection:)` of `SkillSummary` rows. Each row has a source icon: `skill` → `"wand.and.sparkles"`, `command` → `"terminal"`, `plugin` → `"puzzlepiece.extension"`, each with an `.accessibilityLabel`. It shows the name, then on the right the total in `.caption.monospacedDigit()`, with "(n typed)" when `slash > 0`. The `skillsFooter` is a caption under the list.
  - **Empty state:** `ContentUnavailableView` "No skills in this window" when `summaries` is empty. When nothing is selected, the detail shows "No skill selected" / "Select a skill to see where it's used.".
  - **Detail:** `Form` with `.formStyle(.grouped)`.
    - **Totals:** a "Totals" section with Total, "Loaded by Claude" (auto), Typed, and Last used (`.clockRelative(presentation: .named)`, as in Last active).
    - **By project:** a `Button(.plain)` row per project with `LabeledContent(name, value: count)` that calls `route.open(project:)`. The name comes from `store.project(id:)?.displayName`. The nil key is a non-button "Outside saved projects" row.
    - **By account:** only when there's more than one share, labelled with `usageAccountName`.
    - **Recent uses:** one row per `SkillUseRecord`.
      - The first line is the date (`.dateTime.day().month().hour().minute()`), "· typed" or "· loaded", and "· <project or abbreviated folder>". Resolve the project with `ProjectPath.deepest(for: record.cwd, in: store.candidates)`, and abbreviate a folder with `abbreviatingWithTildeInPath`.
      - Then `args` in `.callout`, and "Next: <reply>" in `.callout` `.secondary`. Each is `lineLimit(2)` with `.help(fullText)`, and omitted when nil.
      - Loaded with `.task(id: RecentKey(skill:window:generation: index.ledger.generation))`, which calls `index.recentSkillUses`. "No uses in this window." shows when the summary is missing.
    - **Rebuild:** `.id(skill)` on the detail, so state resets per skill.
- [ ] **Step 4: Add the project pane click-through.** In `ProjectUsageSection`, wrap each skill row in `Button { MainWindowRoute.shared.open(skill: skill.id) } label: { LabeledContent(...) }.buttonStyle(.plain)`, with `.help("Show \(skill.id) in Skills")`.
- [ ] **Step 5: Update the docs.**
  - **CHANGELOG:** in `## [Unreleased]` → `### Added`, extend the skill usage entry's "See it in the project pane" to "See it in the Skills pane, across every project, or in each project's pane". Keep the entry one bullet.
  - **README:** change the Skills row's "in the pane" to "in the Skills pane and each project's".
  - **Regenerate:** run `make changelog` from the repo root.
- [ ] **Step 6: Verify, from the repo root.** Run `make build`, `make -C apps/apple unit`, `make format-swift-check` and `make changelog-check`. Expected: all pass. Then read `SkillsPane.swift` once against Review Focus items 3–5.
- [ ] **Step 7: Commit** `feat(skills): a Skills pane across every project`, including `Changelog.swift`.
