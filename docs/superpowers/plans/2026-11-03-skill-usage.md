# Skill Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Armada counts every Agent Skill and custom command use on Claude Code, per account, folder and day, from the transcripts it already reads, and shows it through `armada_get_skill_usage` and a Skills section in the project pane.

**Architecture:**

- **The parser**, `ClaudeSkillLine`, turns one transcript line into skill uses and human messages. It is a pure function in `make unit`.
- **The ingest**, `FileIngest.claude`, gains a second cursor. A line before the token cursor reaches only the skill parser.
- **The indexer** stores one row per use in `skill_uses` (ledger schema 2). It reads the transcript archive folder as a skills-only source.
- **The rest:** `SkillCatalog` and `SkillStats` classify and roll up at query time. The app's bridge hands `SkillsSnapshot` to the new tool, and `ProjectUsageSection` draws the same roll-up.

**Tech Stack:**

- Swift 6, macOS 26, main-actor default isolation
- SQLite3 through `UsageDatabase`
- `swift-mcp-kit` (`MCPTool`, `ToolTable`, `JSONValue`)
- Swift Testing for `ArmadaMCP`, and the `UnitChecks` swiftc driver (`make unit`) for app files

**Spec:** `docs/superpowers/specs/2026-11-03-skill-usage-design.md`

## Global Constraints

- **Claude Code only.** Codex is not counted, and the tool and pane say so.
- **Tokens never count twice.** The token half of `FileIngest.claude` never sees a line that starts before `cursor.offset`. Every existing token check in `make unit` passes unchanged.
- **Ledger schema version 2.** Version 1 is migrated in place. Any other version is moved aside, as `reopenAside` does today.
- **Dedupe ids:** `"a:" + tool_use id` for auto, `"s:" + entry uuid` for slash. `INSERT OR IGNORE` on `skill_uses.use_id`.
- **`args` and `reply`** are each at most 500 characters, cut on a `Character` boundary. Replies come only from the main transcript, never a subagent's.
- **The archive folder is only read.** The indexer never writes, creates or prunes anything there.
- **The tool:** `armada_get_skill_usage` is `.readOnly`, listed in `readToolNames`, not gated, and its description is within `ToolsTests.descriptionBudget`.
- **Window values:** `7d`, `30d` and `all` (`StatsWindow` raw values), defaulting to `30d`.
- **`make unit`:** app files new to it are added to `UNIT_SRC` in `apps/apple/Makefile` and compile alone under its flags. Every type is `nonisolated`, as `UsageIngest.swift` does it.
- **No `project.pbxproj` edit:** the app target uses file-system synchronized groups.
- **Commits** use `type(scope): subject`, e.g. `feat(index): …`, `feat(mcp): …`.

## Review Focus

These are the inputs a person will hit that the spec doesn't name. Each one is pinned by a test in the task noted.

1. **The app quits partway through the backfill.** The next pass resumes from the committed `skill_offset`. No use counts twice and tokens don't move (Task 3).
2. **A Skill tool_use line is still being written** when a pass reads it. The unterminated line is not counted, and the next pass counts it once (Task 2).
3. **A transcript is rewritten (shrinks) while its skill cursor lags behind its token cursor.** Both restart at zero under the new slot. Uses stay once and tokens match a fresh read (Task 3).
4. **One assistant line holds two `Skill` tool_uses.** Both count (Task 1).
5. **A multi-kilobyte `args` or reply with an emoji at the cut.** The stored text is ≤ 500 characters and still valid UTF-8 (Task 1).

---

### Task 1: The skill line parser

**Files:**
- Create: `apps/apple/Armada/SkillLines.swift`
- Modify: `apps/apple/Makefile` (`UNIT_SRC`, after `Armada/UsageIngest.swift`)
- Test: `apps/apple/UnitChecks/UnitCheck.swift` (new `skillLines()`, called from `main()` after `usageIngest()`)

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum SkillKind: Int, Hashable, Sendable { case auto = 0, slash = 1 }
  nonisolated struct SkillUseEvent: Equatable, Sendable {
    let useID: String      // "a:<tool_use id>" or "s:<uuid>"
    let kind: SkillKind
    let skill: String      // leading "/" and whitespace removed
    let entryUUID: String
    let at: Date
    let args: String?      // ≤ 500 characters, nil when empty
  }
  nonisolated enum ClaudeSkillLine {
    enum Event: Equatable, Sendable { case use(SkillUseEvent), human(String) }
    static let excerptLimit = 500
    /// `wantHuman`: also report a message the person typed (≤ 500 characters).
    static func parse(_ line: Data, wantHuman: Bool) -> [Event]
    static func excerpt(_ text: String) -> String?
  }
  ```

- [ ] **Step 1: Write the failing checks** in `skillLines()`, using new line builders `skillToolLine(ids:skills:uuid:at:)`, `slashLine(name:uuid:args:order:)` and `humanLine(text:uuid:)` next to `claudeLine`:
  - `parse(skillToolLine(ids: ["toolu_1"], skills: ["superpowers:brainstorming"]))` returns one `.use` with `useID == "a:toolu_1"`, `kind == .auto`, `skill == "superpowers:brainstorming"`, `entryUUID` = the line's uuid.
  - A line with `ids: ["toolu_1", "toolu_2"]` gives two uses (Review Focus 4).
  - `slashLine(name: "code-health", uuid: "u1", args: "src/")` with `<command-message>` first gives `useID == "s:u1"`, `kind == .slash`, `skill == "code-health"`, `args == "src/"`.
  - The same with `<command-name>` first, as `/compact` and old `/commit` lines are, gives one use named `compact`.
  - The content `"[Workflow harness — user request] … <command-name>/code-health</command-name>"` gives no use.
  - The slash text in an entry whose `type` is `api-request-blob`, `attachment` or `api-request-shape` gives no use.
  - Invalid JSON gives `[]`.
  - `humanLine(text: "no, that's wrong")` gives `[.human("no, that's wrong")]` with `wantHuman: true`, and `[]` with `wantHuman: false`.
  - Each of these gives no `.human`:
    - an entry with `"isMeta": true`;
    - an entry whose content list holds a `tool_result`;
    - content starting with `<local-command-` or `<command-`.
  - A text-block list content (`[{"type":"text","text":"try again"}]`) gives `.human("try again")`.
  - `excerpt(String(repeating: "é", count: 499) + "😀😀")` has a `count` of 500 and round-trips through `Data(…utf8)` (Review Focus 5).
  - `excerpt("   ")` is nil.

- [ ] **Step 2: Run `make unit` from `apps/apple`.** Expected: a compile failure (`ClaudeSkillLine` undefined).

- [ ] **Step 3: Implement `SkillLines.swift`.**
  - **Cheap rejects first, like `ClaudeUsageLine`.** Skip the line unless it contains `"Skill"` or `<command-`, or `wantHuman` is set and it contains `"type":"user"`.
  - **Uses:** `type` must be `assistant` (tool_uses) or `user` (slash).
  - **Slash rule:** after leading whitespace, the content must start with `<command-message>` or `<command-name>`. Take the name with `<command-name>/?([^<]*)</command-name>` and the args from `<command-args>(…)</command-args>`.
  - **Timestamp:** read `at` with `UsageSnapshot.parseTimestamp`, and skip the event when it is missing.

- [ ] **Step 4: Run `make unit`.** Expected: `N checks passed`.

- [ ] **Step 5: Commit** — `feat(index): parse skill uses and typed messages from transcript lines`

### Task 2: Two cursors in the Claude ingest

**Files:**
- Modify: `apps/apple/Armada/UsageIngest.swift` (`FileIngest.claude`, new `SkillCursor`, `SkillContribution`)
- Test: `apps/apple/UnitChecks/UnitCheck.swift` (`usageIngest()`)

**Interfaces:**
- Consumes: `ClaudeSkillLine.parse`, `SkillUseEvent` (Task 1)
- Produces:
  ```swift
  nonisolated struct SkillCursor: Codable, Hashable, Sendable {
    var offset: Int64 = 0            // persisted in files.skill_offset, not in the JSON
    var awaiting: [String] = []      // use ids waiting for the person's next message
    enum CodingKeys: String, CodingKey { case awaiting }
  }
  nonisolated struct SkillContribution: Equatable, Sendable {
    let event: SkillUseEvent
    let day: Int
  }
  static func claude(
    _ buffer: Data, base: Int64, cursor: inout IngestCursor, skills: inout SkillCursor,
    tokens: Bool, subagent: Bool, calendar: Calendar, claim: (UInt64) -> Bool,
    sink: (IngestContribution) -> Void, skill: (SkillContribution) -> Bool,
    reply: ([String], String) -> Void
  ) -> Int
  ```
  - `base` is the file offset of `buffer`'s first byte.
  - `skill` returns true when the use was new (claimed). Only claimed uses in a main transcript (`subagent == false`) join `awaiting`.
  - `reply` gets every awaiting id and the excerpt, and `awaiting` is then emptied.

- [ ] **Step 1: Write the failing checks** in `usageIngest()`. Each one builds a buffer of `claudeLine`, `skillToolLine` and `humanLine` lines:
  - **A fresh read** (`base: 0`, both offsets 0, `tokens: true`) gives the same token total as before and one `skill` call per use. Both offsets equal the buffer's byte count.
  - **A backfill:**
    - Setup: `cursor.offset` = the buffer's full length, `skills.offset = 0`.
    - `sink` is never called, `skill` is called for every use, and `cursor.offset` is unchanged.
    - This is the token rule from Global Constraints.
  - **A partial overlap:** with `cursor.offset` at line 2's start, tokens count lines 2 and later, and skills count every line.
  - **`tokens: false`:** no `sink` calls and both offsets advance, which is what archive files use. `cursor.cwd` is still learnt.
  - **The reply:** a use followed by an `isMeta` line and then `humanLine("no")` gives one `reply(["a:toolu_1"], "no")`. Afterwards `awaiting` is empty.
  - **A subagent** (`subagent: true`): the same buffer makes no `reply` call.
  - **An unclaimed use** (`skill` returns false) never joins `awaiting`.
  - **An unterminated last line** holding a Skill tool_use gives no `skill` call, and `skills.offset` stops before it. Feeding the completed line next gives exactly one call (Review Focus 2).

- [ ] **Step 2: Run `make unit`.** Expected: a compile failure.

- [ ] **Step 3: Implement.**
  - **Per line:** `wholeLines` yields each line's start position, so the absolute start is `p = base + start`.
  - **Tokens:** a line goes to the token logic when `tokens && p >= cursor.offset`.
  - **Skills:** a line goes to `ClaudeSkillLine.parse(line, wantHuman: !skills.awaiting.isEmpty)` when `p >= skills.offset`.
  - **Folder:** cwd detection runs for any line while `cursor.cwd == nil`.
  - **Afterwards:** `cursor.offset = max(cursor.offset, base + consumed)` and `skills.offset = max(skills.offset, base + consumed)`.
  - **Codex:** `FileIngest.codex` is unchanged.

- [ ] **Step 4: Run `make unit`.** Expected: every check passes, the existing `usageIngest` and `usageIndexer` ones included.

- [ ] **Step 5: Commit** — `feat(index): read skill uses behind their own cursor`

### Task 3: Storing uses in the ledger

**Files:**
- Modify: `apps/apple/Armada/UsageIndexer.swift`
- Modify: `apps/apple/Armada/UsageLedger.swift` (`SkillUsageRow`, snapshot fields)
- Test: `apps/apple/UnitChecks/UnitCheck.swift` (`usageIndexer()`, new `skillIndexer()` called after it)

**Interfaces:**
- Consumes: `FileIngest.claude` (Task 2), `SkillCursor`, `SkillContribution`
- Produces:
  ```swift
  nonisolated struct SkillUsageRow: Hashable, Sendable {
    let day: Int; let cwd: String; let account: String; let vendor: UsageVendor
    let skill: String; let kind: SkillKind; let count: Int; let lastAt: Date
  }
  // UsageLedgerSnapshot gains:
  let skills: [SkillUsageRow]
  let skillsPassDone: Bool      // meta "skills_pass_done" == "1"
  let earliestSkillDay: Int?
  // UsageIndexer:
  static let schemaVersion = 2
  static let skillParserVersion = 1   // meta "skill_parser"
  init(url: URL, commitBytes: Int64 = UsageIndexer.commitBytes)   // the override is for tests
  ```

- [ ] **Step 1: Write the failing checks** in `skillIndexer()`, using the `pass()` harness from `usageIndexer()`:
  - **A main transcript with 2 auto uses, 1 slash and 1 human reply:**
    - The snapshot's `skills` sum to auto 2 and slash 1.
    - A second pass changes nothing.
    - Read straight from the SQLite file with `UsageDatabase`: the `reply` of the use before the human line is that text. `session_id` is the file's session, and `cwd` is the stored folder.
  - **A resumed copy:** a second file holding the same lines plus one new auto use gives auto 3, not 5.
  - **A subagent** `s1/subagents/agent-x.jsonl` with a use counts under `s1`'s folder and `session_id == "s1"`.
  - **A deleted transcript:** delete the file and pass again. Totals are unchanged, and the row's `slot` is NULL.
  - **An upgrade from v1:**
    - Setup: create a database with the v1 `files`, `seen`, `file_usage`, `archive`, `sessions` and `meta` DDL, set user_version 1, and insert one `archive` row. Index a transcript with a `/work` cwd into it as v1 would, simulated by a pass followed by `DELETE FROM skill_uses; UPDATE files SET skill_offset = 0`.
    - After the next pass: user_version is 2, the `archive` row is still there, skills are counted, and the token total equals the total before the upgrade.
  - **A cancelled backfill** (Review Focus 1):
    - Setup: run a pass and cancel it after its first commit. Use a transcript past `commitBytes`, made with a test-only `commitBytes` override passed to `UsageIndexer(url:commitBytes:)`.
    - The next pass completes. Uses equal a clean read's, and tokens equal a clean read's.
  - **A rewrite during the backfill** (Review Focus 3):
    - Setup: `skill_offset` is 0 and `offset` is at the end. Replace the file with a shorter one whose first bytes differ.
    - After the pass: uses equal the union of both versions, each once, and tokens follow the existing rewrite rule (the old figures kept in `archive`).
  - **A parser version bump:**
    - Setup: set meta `skill_parser` to `0`.
    - The next pass re-reads skills: the row count is the same, and `file_usage` is untouched (compare `SUM(output)`).

- [ ] **Step 2: Run `make unit`.** Expected: failures (no `skills` on the snapshot).

- [ ] **Step 3: Implement in `UsageIndexer`.**
  - **Schema:**
    - `files` gains `skill_offset INTEGER NOT NULL DEFAULT 0, skill_state TEXT` in its `CREATE`.
    - `skill_uses` is added exactly as in the spec, with `CREATE INDEX IF NOT EXISTS skill_uses_slot ON skill_uses(slot)`.
  - **`open()`:**
    - Version 1 runs the two `ALTER TABLE files ADD COLUMN`s, then `migrate`.
    - Any version other than 0, 1 or 2 is moved aside.
  - **`migrate`:** when meta `skill_parser` differs from `skillParserVersion`, run `DELETE FROM skill_uses WHERE slot IS NOT NULL`, `UPDATE files SET skill_offset = 0, skill_state = NULL` and `DELETE FROM meta WHERE key = 'skills_pass_done'`, then set `skill_parser`.
  - **`StoredFile`:** gains `skillCursor: SkillCursor`, with `offset` from the column and `awaiting` decoded from `skill_state`.
  - **The unchanged-file skip:** also requires `skillCursor.offset >= item.size` for Claude files.
  - **`progress.bytesTotal`:** counts from `min(offset, skillOffset)`.
  - **`process`:**
    - Seek to `min(cursor.offset, skills.offset)` for Claude, and to `cursor.offset` for Codex. Track `base` as chunks are consumed.
    - The `skill` closure runs `INSERT OR IGNORE INTO skill_uses` with `slot`, `LocalDay` day, `storedFolder(cursor.cwd ?? "")`, account, vendor, `item.sessionID`, `at.timeIntervalSince1970`, `entryUUID` and `args`, and returns `db.changes > 0`.
    - The `reply` closure runs `UPDATE skill_uses SET reply = ? WHERE use_id = ? AND reply IS NULL` for each id.
    - `flush` also writes `skill_offset` and `skill_state`. For Codex it writes `skill_offset = cursor.offset`.
  - **Rewrites:**
    - The "rewritten again" branch: after the new slot is inserted, run `UPDATE skill_uses SET slot = <new> WHERE slot = <dropped partial slot>`.
    - `finishReplacement`: `UPDATE skill_uses SET slot = new WHERE slot = old`.
  - **`fold`:** `UPDATE skill_uses SET slot = NULL WHERE slot = ?`.
  - **End of an uncancelled pass:** set `skills_pass_done = 1`.
  - **`buildSnapshot`:**
    - Fill `skills` from `SELECT day, cwd, account, vendor, skill, kind, COUNT(*), MAX(at) FROM skill_uses GROUP BY day, cwd, account, vendor, skill, kind`.
    - Set `earliestSkillDay` to the smallest day.
    - `UsageLedgerSnapshot.empty` gets empty skills.
  - **Doc comments:** add a paragraph on the second cursor and why, in the file's own style.

- [ ] **Step 4: Run `make unit`.** Expected: all checks pass, the existing `usageIndexer` ones included.

- [ ] **Step 5: Commit** — `feat(index): keep each skill use in the ledger, backfilled behind a second cursor`

### Task 4: The transcript archive as a skills-only source

**Files:**
- Modify: `apps/apple/Armada/UsageIndexer.swift` (`Source`, `FileItem`, `enumerate`, `loadFiles`, fold check)
- Modify: `apps/apple/Armada/TranscriptArchiver.swift` (new `skillSources()`)
- Modify: `apps/apple/Armada/UsageIndex.swift` (`pass` adds them)
- Test: `apps/apple/UnitChecks/UnitCheck.swift` (`skillIndexer()`)

**Interfaces:**
- Consumes: Task 3's storage
- Produces:
  ```swift
  // UsageIndexer.Source
  let skillsOnly: Bool   // default false in an added init
  var id: String { skillsOnly ? "~a|\(vendor.rawValue)|\(account)" : "\(vendor.rawValue)|\(account)" }
  static let archiveKeyPrefix = "~a:"
  // TranscriptArchiver (main actor)
  func skillSources() -> [UsageIndexer.Source]
  ```
  - **Keys:** an archive file's key is `"~a:" + <its usual key>`, with the prefix on `parentSession` too, so it never shares a `files` row with the live copy.
  - **Session id:** skill rows strip the `~a:` prefix and a trailing `~<digits>` (the archive's kept rewrites).
  - **Identity:** `FileItem.identity` becomes `"\(source.vendor.rawValue)|\(source.account)|\(key)"`, the same string as today's for live files.
  - **Folding:** `StoredFile`'s listing id is `"~a|" + source` when its key has the prefix. That is what the fold check compares with `listed`.

- [ ] **Step 1: Write the failing checks:**
  - **A live copy and an archive copy:**
    - Setup: a live root and an archive root (`<archive>/<folder>/projects/...`) both hold `s1.jsonl` with the same 2 uses. The archive also holds `s0.jsonl`, gone from live, with 1 use.
    - One pass with both sources gives 3 uses.
    - `file_usage`'s `SUM(output)` equals a pass over the live root alone, so tokens never come from the archive.
    - The `s1` rows are owned by the live slot (live items are enumerated first).
  - **An unmounted archive:** pass again with the archive source pointing at a missing folder. No row's `slot` becomes NULL and totals are unchanged.
  - **An archive-only use:** the use in `s0~1.jsonl` gets `session_id == "s0"`.

- [ ] **Step 2: Run `make unit`.** Expected: failures.

- [ ] **Step 3: Implement.**
  - **`enumerate`:** returns `codex + mains + subagents + archiveMains + archiveSubagents`, keeping the existing sort within each group.
  - **`process`:** passes `tokens: !item.source.skillsOnly`.
  - **`skillSources()`:**
    - Returns nothing unless `isOn` and the private `isAvailable(target)` holds.
    - Otherwise it reads `TranscriptArchive.readManifest(at: root)`. A throw or nil gives `[]`.
    - It maps each `.claude` entry to `Source(account: <manifest key>, vendor: .claude, root: root/<entry.folder>/projects, skillsOnly: true)`.
  - **`UsageIndex.pass`:** appends `TranscriptArchiver.shared.skillSources()` to `sources`.

- [ ] **Step 4: Run `make unit`.** Expected: all pass.

- [ ] **Step 5: Commit** — `feat(index): read skill uses from the transcript archive too`

### Task 5: Skill or built-in, and the window roll-up

**Files:**
- Create: `apps/apple/Armada/SkillStats.swift`
- Modify: `apps/apple/Makefile` (`UNIT_SRC`, after `Armada/ProjectStats.swift`)
- Test: `apps/apple/UnitChecks/UnitCheck.swift` (new `skillStats()`, after `projectStats()`)

**Interfaces:**
- Consumes: `SkillUsageRow`, `SkillKind` (Tasks 1 and 3), `StatsWindow`, `ProjectPath`
- Produces:
  ```swift
  nonisolated enum SkillSource: String, Sendable { case skill, command, plugin, builtin }
  nonisolated enum SkillCatalog {
    /// configs: each Claude account's config folder (`ClaudeConfigFolder.base`).
    static func classify(
      _ rows: [SkillUsageRow], configs: [URL], home: String,
      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: SkillSource]
  }
  nonisolated struct SkillTally: Hashable, Sendable {
    let projectID: String?; let account: String; let skill: String; let source: SkillSource
    let window: StatsWindow; let auto: Int; let slash: Int; let lastAt: Date
    var total: Int { auto + slash }
  }
  nonisolated enum SkillStats {
    static func compute(
      _ rows: [SkillUsageRow], projects: [ProjectPath.Candidate],
      sources: [String: SkillSource], today: Date, calendar: Calendar
    ) -> [SkillTally]   // one per (project or nil, account, skill, window) with any use
  }
  ```

- [ ] **Step 1: Write the failing checks** (with a fake `fileExists` over a set of paths):
  - **Plugin:** `marketing:seo-audit` is `.plugin` with nothing on disk.
  - **Auto use:** a name with one auto row is `.skill` with nothing on disk.
  - **On disk:**
    - `distill`, slash only, with `<config>/commands/distill.md` present, is `.command`.
    - `caresheet`, with `/p/canopy/.claude/skills/caresheet/SKILL.md` present and a row cwd of `/p/canopy/sub`, is `.skill`. The search walks up to `home` and no further.
  - **Built-in:** `compact` with nothing anywhere is `.builtin`.
  - **Windows:** `SkillStats.compute` on rows dated today, 10 days ago and 40 days ago puts them in `7d` / `30d` / `all` as `ProjectStats` does: 1 / 2 / 3.
  - **Projects:** a row in a nested folder goes to the deepest project. A row outside every project has `projectID == nil`.
  - **`lastAt`** is the max across the window's rows.

- [ ] **Step 2: Run `make unit`.** Expected: a compile failure.

- [ ] **Step 3: Implement.**
  - **Order:** classification follows the spec's order. The project-folder walk stops at `home` or `/`.
  - **Window floors:** taken from `ProjectStats.compute`. Extract its floor calculation into `StatsWindow.floor(today:calendar:) -> Int` and have both call it.

- [ ] **Step 4: Run `make unit`.** Expected: all pass, `projectStats()` included.

- [ ] **Step 5: Commit** — `feat(index): tell skills from built-ins and roll uses up by window`

### Task 6: `armada_get_skill_usage`

**Files:**
- Create: `apps/apple/Packages/ArmadaMCP/Sources/ArmadaMCP/SkillsSnapshot.swift`
- Modify: `apps/apple/Packages/ArmadaMCP/Sources/ArmadaMCP/FleetSource.swift` (new requirement)
- Modify: `apps/apple/Packages/ArmadaMCP/Sources/ArmadaMCP/Tools.swift` (tool, `readToolNames`, generic `lookupProject`)
- Create: `apps/apple/Armada/SkillsBridge.swift`
- Modify: `apps/apple/Packages/ArmadaMCP/Tests/ArmadaMCPTests/FakeFleetSource.swift`, `WaitToolTests.swift` (`MovingFleetSource`)
- Test: `apps/apple/Packages/ArmadaMCP/Tests/ArmadaMCPTests/SkillUsageToolTests.swift`

**Interfaces:**
- Consumes: `SkillStats.compute`, `SkillCatalog` results held by `UsageIndex` (Task 7 adds `skillSources`; this task's bridge reads `UsageIndex.shared.skillSources`, so add that stored property here as `private(set) var skillSources: [String: SkillSource] = [:]` and let Task 7 fill it)
- Produces:
  ```swift
  public struct SkillsSnapshot: Sendable {
    public let takenAt: Date; public let isEntitled: Bool
    public let index: ProjectsSnapshot.Index      // complete = firstPassDone && skillsPassDone
    public let projects: [ProjectRef]
    public let accounts: [AccountRef]
    public let tallies: [Tally]
    public struct ProjectRef: Sendable, ProjectNaming { public let id, name, path: String }
    public struct AccountRef: Sendable { public let id, name: String }
    public struct Tally: Sendable {
      public let projectID: String?; public let accountID: String; public let skill: String
      public let source: String; public let window: String
      public let auto: Int; public let slash: Int; public let lastUsed: Date
    }
  }
  public protocol ProjectNaming { var id: String { get }; var name: String { get }; var path: String { get } }
  // FleetSource
  func skills() async -> SkillsSnapshot
  // Tools: lookupProject becomes generic; ProjectsSnapshot.Project conforms to ProjectNaming
  static func lookupProject<P: ProjectNaming>(_ raw: JSONValue?, in projects: [P], isEntitled: Bool) -> ProjectLookup<P>
  enum ProjectLookup<P> { case found(P), refused(ToolResult) }
  ```

- [ ] **Step 1: Write the failing tests.** Add a `skillsFixture` to `FakeFleetSource` that covers:
  - the two accounts;
  - `armadaProject` and `siteProject`;
  - per window, `code-health` (auto 2, slash 5), `superpowers:brainstorming` (auto 3), `distill` (command, slash 4) and `compact` (builtin, slash 9);
  - one tally with `projectID: nil`.

  Then in `SkillUsageToolTests`:
  - **Default call:**
    - It uses window `30d` and every account and project, nil included. Skills are sorted by total, descending.
    - `compact` is absent and `builtinsHidden == 1`.
    - Each entry has `name`, `source`, `total`, `auto`, `slash` and `lastUsed` (ISO date).
  - **`includeBuiltins: true`** lists `compact` with `source == "builtin"`.
  - **`project`:**
    - `armadaProject`'s id prefix sums only that project's tallies.
    - An ambiguous 8-character prefix is refused with candidates, as `armada_get_projects` refuses one.
  - **`account`:** an id or a case-insensitive name filters. An unknown one is refused, listing the account names.
  - **`window`:** `"all"` and `"7d"` select those tallies. `"90d"` is refused with `Pass window: 7d, 30d or all.`
  - **`index`:** a fixture with `complete: false` gives `index.complete == false`, and the lede starts `Armada is still reading older transcripts`.
  - **`note`:** it is `Claude Code only. Codex records no skill use of its own.`
  - **The existing tests:**
    - `ToolsTests.descriptionBudget` passes.
    - The read-only listing test sees the tool with writes off.
    - `armada_get_projects` tests still pass with the generic lookup.

- [ ] **Step 2: Run `swift test --package-path Packages/ArmadaMCP` from `apps/apple`.** Expected: a compile failure.

- [ ] **Step 3: Implement.**
  - **The tool, `add(skills:source:)`:**
    - Registered after `add(projects:)`, with `title: "Skill usage"`.
    - Description: "How often each Agent Skill and custom command was used in Claude Code, read from the transcripts on this Mac: loaded by Claude itself (auto) or typed as /name (slash), with the day each was last used. Filter by project or account, over 7 days, 30 days or all time. Built-in commands such as /compact are left out unless includeBuiltins is set. Codex records no skill use and is not counted."
  - **The lede:** `"<n> skills used in the last 30 days: code-health 7 (5 typed); …"`, for the first 5 skills, then `"; and <k> more"`. It uses `7 days` / `all time` wording for the other windows.
  - **`index`:** the same object shape as `armada_get_projects`, with `since` taken from `earliestSkillDay`.
  - **`SkillsBridge.swift`:** `FleetBridge.skills()`, built as `ProjectsBridge` is built:
    - One main-actor hop copies the ledger, `candidates`, projects, account names, `skillSources`, progress and entitlement.
    - `SkillStats.compute` then runs off the main actor.

- [ ] **Step 4: Run `swift test --package-path Packages/ArmadaMCP` and `make build` from `apps/apple`.** Expected: all tests pass and the build succeeds.

- [ ] **Step 5: Commit** — `feat(mcp): armada_get_skill_usage`

### Task 7: Classification in the app, and the Skills section

**Files:**
- Modify: `apps/apple/Armada/UsageIndex.swift`
- Modify: `apps/apple/Armada/ProjectUsageSection.swift`
- Modify: `apps/apple/Armada/DemoSeed.swift` (only if it builds a `UsageLedgerSnapshot` by memberwise init: give it empty skills)

**Interfaces:**
- Consumes: `SkillCatalog.classify`, `SkillStats.compute`, `SkillTally` (Task 5), `skillSources` (Task 6)
- Produces: `UsageIndex.projectSkills(store: ProjectStore) -> [SkillTally]`, memoised like `projectUsage(store:)` on ledger generation, day, candidates and a `skillSources` version counter

- [ ] **Step 1: In `UsageIndex.receive(_ snapshot:)`, classify off the main actor.**
  - Start a detached background `Task` running `SkillCatalog.classify(snapshot.skills, configs: Accounts.shared.all.map(\.folder.base), home: NSHomeDirectory())`. Read the configs on the main actor before detaching.
  - Assign the result to `skillSources` only if `snapshot.generation` is still current, and bump the version counter.

- [ ] **Step 2: Add the section.** It goes after the Folders slices in `ProjectUsageSection.body`, and is shown only when the project has a non-builtin tally in `window`:
  - Header `Skills`.
  - The top 10 by total, summed across accounts. Each row is `LabeledContent(skill, value: slash > 0 ? "\(total) (\(slash) typed)" : "\(total)")`.
  - Footer: `Claude Code only. Typed means started with /name; the rest Claude loaded on its own.`

- [ ] **Step 3: Run `make build` and `make unit` from `apps/apple`.** Expected: both succeed.
  - Don't launch the app to look at the section: it would take the focus from the person at the Mac.
  - Check the layout with the SwiftUI preview of `ProjectUsageSection`, if one exists, through `RenderPreview`. Otherwise go by the build.

- [ ] **Step 4: Commit** — `feat(projects): a Skills section in the project pane`

### Task 8: Docs and the check against real numbers

**Files:**
- Modify: `docs/claude-code-sessions.md` (new section "Skill uses")
- Modify: `CHANGELOG.md` (new `## [Unreleased]` above `## [1.11.1]`)
- Modify: `README.md` (Status table)

- [ ] **Step 1: Document the forms.** Add a `docs/claude-code-sessions.md` section describing the auto and slash forms, both tag orders, the entry types that repeat the text, and the harness-relay false positive. Take the figures from the spec's survey.

- [ ] **Step 2: Add the CHANGELOG entry.**
  - `### Added`: "Skill usage: Armada counts each Agent Skill and custom command used in Claude Code, whether Claude loaded it or you typed it, per project and account. See it in the project pane or ask an agent through `armada_get_skill_usage`. History goes back as far as the transcripts on this Mac, and the transcript archive when one is set."
  - `### Internal`: "Ledger schema 2, with skill uses read behind a second per-file cursor."

- [ ] **Step 3: Add the README Status row** after **Projects**: `| **Skills** | each skill and command used in Claude Code, typed or loaded, per project, in the pane and through `armada_get_skill_usage` |`. Pad it to the table's column widths.

- [ ] **Step 4: Check against real data.**
  - **Setup:**
    - Copy the debug build's ledger with `sqlite3 "<support dir>/usage-index.sqlite" ".backup <scratchpad>/ledger.sqlite"`. Take the support dir from `AppInfo.supportDirectory` for `io.mgcrea.armada.debug`.
    - This needs a debug build that has run a full pass. If none has, ask the person to launch it once rather than launching it yourself.
  - **The query:**
    ```sql
    SELECT skill, COUNT(*), SUM(kind = 0), SUM(kind = 1) FROM skill_uses
    WHERE skill IN ('project-mail-archive','superpowers:brainstorming','code-health',
                    'reply-as-olivier','push-testflight-build') GROUP BY skill;
    ```
  - **Expected:** each total, auto and slash is at least the spec's table. They will be higher, because the archive adds 2026-08-05 → 2026-09-01 and sessions have run since. Report both sets of figures, and look into any figure below the table.

- [ ] **Step 5: Run the full `make test` from the repo root.** Expected: it passes.

- [ ] **Step 6: Commit** — `docs: skill usage in the CHANGELOG, README and session format`
