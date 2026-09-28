import CryptoKit
import Foundation
import SQLite3

/// What a save asks for. Nil fields are kept from the file on an update; on a create, `name`,
/// `prompt`, `rrule` and `cwd` are required. `status` is `active` or `paused`.
nonisolated struct SaveInput: Sendable, Equatable {
  var id: String?
  var name: String?
  var prompt: String?
  var rrule: String?
  var cwd: String?
  var model: String?
  var reasoningEffort: String?
  var status: String?
}

nonisolated enum SaveResult: Sendable, Equatable {
  case saved(CodexAutomation, created: Bool, earlyRun: CodexAutomations.EarlyRun?)
  case refused(String)
}

nonisolated enum RemoveResult: Sendable, Equatable {
  /// The automation as it was, when its file could be read.
  case removed(CodexAutomation?)
  case refused(String)
}

/// One Codex home's automations: the folder the Codex app schedules from, and read-only looks
/// at the two databases beside it.
///
/// **Writes files, never databases.** The app keeps run state in `sqlite/codex-dev.db` and its
/// projects in `state_5.sqlite`; both are opened `SQLITE_OPEN_READONLY`. Deleting removes the
/// folder only: Codex lists and schedules from the files, so the row it leaves behind is inert,
/// and `save` steers new ids around it.
nonisolated struct CodexAutomations: Sendable {
  struct Listed: Sendable {
    let id: String
    let fileURL: URL
    let parsed: CodexAutomationFile.Parsed
  }

  struct RunTimes: Sendable, Equatable {
    let lastRunAt: Date?
    let nextRunAt: Date?
  }

  /// Why Codex may run a just-saved automation once outside its rule. Measured in
  /// docs/implementation.md: Codex keeps a row's `next_run_at` while the row's status matches the
  /// file's, and a row Armada paused still says `ACTIVE`. Armada writes neither database, so it
  /// can only say so.
  nonisolated enum EarlyRun: Sendable, Equatable {
    /// Resumed with a stored run time that passed while it was paused: due at once.
    case dueWhilePaused
    /// A new rule on an active task, with a run time still stored from the old rule.
    case oldTime
  }

  static let accountOwnedRefusal =
    "This Codex keeps its automations in your OpenAI account. Armada can list them but not change them."

  /// Serializes every `save` and `remove` in this process, so two concurrent creates of the same
  /// name can't both see the id free and pick it.
  static let lock = NSLock()

  let home: CodexHome

  init(home: CodexHome) {
    self.home = home
  }

  var directory: URL { home.base.appending(path: "automations", directoryHint: .isDirectory) }
  var runDatabase: URL {
    home.base.appending(path: "sqlite/codex-dev.db", directoryHint: .notDirectory)
  }
  var stateDatabase: URL {
    home.base.appending(path: "state_5.sqlite", directoryHint: .notDirectory)
  }

  /// `qz`: not empty, not `.` or `..`, no path separator.
  static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\")
  }

  /// The sentence for an id `list()` does not have. Shared by `remove` here and by Task 5's
  /// bridge, so the two never drift apart.
  static func unknownID(_ id: String) -> String {
    "No Codex automation \"\(id)\". armada_list_schedules names them."
  }

  /// The sentence for a heartbeat: `save` and `remove` both refuse one, word for word.
  static func heartbeatRefusal(_ id: String) -> String {
    "\(id) is a heartbeat, tied to one Codex thread; change it in the Codex app."
  }

  /// Why `save` and `remove` leave an automation alone for its kind, or nil for `cron`, the one
  /// kind they change. Also the list's read-only reason, so the two never disagree.
  static func kindRefusal(_ automation: CodexAutomation) -> String? {
    switch automation.kind {
    case "cron": nil
    case "heartbeat": heartbeatRefusal(automation.id)
    default:
      "\"\(automation.id)\" is a kind of Codex automation Armada does not change; change it in "
        + "the Codex app."
    }
  }

  private func fileURL(_ id: String) -> URL {
    directory.appending(path: id, directoryHint: .isDirectory).appending(path: "automation.toml")
  }

  // MARK: Reading

  /// Every folder Codex would read, in name order. A file whose `id` is not its folder's name is
  /// skipped, as `uB` skips it.
  func list() -> [Listed] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []
    return names.sorted().compactMap { name in
      guard Self.isValidID(name) else { return nil }
      let url = fileURL(name)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      let parsed = CodexAutomationFile.parse(text)
      if case .automation(let a) = parsed, a.id != name { return nil }
      if case .notAutomation = parsed { return nil }
      return Listed(id: name, fileURL: url, parsed: parsed)
    }
  }

  /// Every entry `directory` holds, including the ones `list()` skips: a non-automation file, an
  /// id mismatch, a folder with no `automation.toml` at all. The pool `save` steers a new id
  /// around, since any of those would collide with a folder Armada is about to create.
  private func directoryEntries() -> Set<String> {
    Set(
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
        ?? [])
  }

  func runTimes() -> [String: RunTimes] {
    var out: [String: RunTimes] = [:]
    Self.query(runDatabase, "SELECT id, last_run_at, next_run_at FROM automations") { row in
      guard let id = row.text(0) else { return }
      out[id] = RunTimes(lastRunAt: row.date(1), nextRunAt: row.date(2))
    }
    return out
  }

  /// Codex's other mode: automations kept in the database under an account, with no files.
  func isAccountOwned() -> Bool {
    var owned = false
    Self.query(runDatabase, "SELECT 1 FROM automations WHERE account_id IS NOT NULL LIMIT 1") { _ in
      owned = true
    }
    return owned
  }

  /// The project whose root is `path`, comparing both the plain and the symlink-resolved
  /// spelling of the folder against both spellings of each root in `project_roots` — `/var` vs
  /// `/private/var`, most often, since a temporary or Homebrew-adjacent folder can sit on either
  /// side of that symlink while a Codex-recorded root sits on the other.
  func projectID(forFolder path: String) -> String? {
    let folderSpellings = Self.spellings(for: path)
    var found: String?
    Self.query(stateDatabase, "SELECT project_id, path FROM project_roots ORDER BY position") {
      row in
      guard found == nil, let id = row.text(0), let root = row.text(1) else { return }
      if !folderSpellings.isDisjoint(with: Self.spellings(for: root)) { found = id }
    }
    return found
  }

  /// A path as `ProjectPath` would compare it, and again after resolving any symlink in it —
  /// `URL(filePath:).resolvingSymlinksInPath().path`, per the ruling. Both spellings normalized,
  /// so a plain match or a symlink-resolved match are equally a hit.
  private static func spellings(for path: String) -> Set<String> {
    let plain = ProjectPath.normalize(path)
    let resolved = ProjectPath.normalize(URL(filePath: path).resolvingSymlinksInPath().path)
    return [plain, resolved]
  }

  /// What Codex itself writes for a folder that is not a `project_roots` row: `local-` followed
  /// by the first 32 hex characters of `sha256(<folder>)`. Verified read-only against 8 of the
  /// person's 9 real automation files (ruling m5); the ninth already had a project row.
  private static func localProjectID(for folder: String) -> String {
    let digest = SHA256.hash(data: Data(folder.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "local-" + hex.prefix(32)
  }

  /// The target Codex would write for a folder just given to `save`: its project root when one
  /// matches, else the `local-` hash Codex writes itself. `projectless` is never written here —
  /// it stays only as the shape for reading a file that already carries it.
  private func target(forFolder folder: String) -> CodexAutomation.Target {
    .project(projectID(forFolder: folder) ?? Self.localProjectID(for: folder))
  }

  /// A control character (Unicode general category Cc) other than `\t`, `\n` or `\r`. Codex's own
  /// writer (`bz`) leaves such a character raw, which is not valid TOML, so a name or prompt
  /// holding one was never something Codex itself would have written.
  private static func controlCharacterRefusal(field: String, in value: String) -> String? {
    for scalar in value.unicodeScalars where scalar.properties.generalCategory == .control {
      if scalar == "\t" || scalar == "\n" || scalar == "\r" { continue }
      return "`\(field)` holds a character Codex's file format cannot store."
    }
    return nil
  }

  // MARK: Writing

  func save(_ input: SaveInput, now: Date) -> SaveResult {
    Self.lock.withLock { performSave(input, now: now) }
  }

  private func performSave(_ input: SaveInput, now: Date) -> SaveResult {
    if isAccountOwned() { return .refused(Self.accountOwnedRefusal) }
    // An update keeps an omitted field, but never writes an empty one: a create cannot omit them.
    for (field, value) in [("name", input.name), ("prompt", input.prompt)]
    where value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
      return .refused("`\(field)` cannot be empty.")
    }
    // A prompt keeps its line breaks; a name is the one line the Codex app shows for the task.
    if let name = input.name, name.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
      return .refused("`name` is one line; it cannot hold a line break.")
    }
    for (field, value) in [
      ("name", input.name), ("prompt", input.prompt), ("cwd", input.cwd), ("model", input.model),
      ("reasoningEffort", input.reasoningEffort),
    ] {
      if let value, let refusal = Self.controlCharacterRefusal(field: field, in: value) {
        return .refused(refusal)
      }
    }
    let stamp = Int64((now.timeIntervalSince1970 * 1000).rounded())

    let status: String?
    switch input.status?.lowercased() {
    case nil: status = nil
    case "active": status = "ACTIVE"
    case "paused": status = "PAUSED"
    case let other?: return .refused("`status` is active or paused, not \"\(other)\".")
    }
    var rule: String?
    if let raw = input.rrule {
      if let refusal = CodexAutomationFile.scheduleRefusal(raw) { return .refused(refusal) }
      rule = CodexAutomationFile.normalizedRRule(raw)
    }

    var automation: CodexAutomation
    let created: Bool
    if let id = input.id {
      guard Self.isValidID(id), let listed = list().first(where: { $0.id == id }) else {
        return .refused(Self.unknownID(id))
      }
      switch listed.parsed {
      case .automation(let existing): automation = existing
      case .handEdited(let why):
        return .refused("\(id) was edited by hand (\(why)), so Armada will not rewrite it.")
      case .notAutomation: return .refused("\(id) is not an automation Codex would run.")
      }
      if let refusal = Self.kindRefusal(automation) { return .refused(refusal) }
      created = false
    } else {
      guard let name = input.name, let prompt = input.prompt, let rule, let cwd = input.cwd else {
        return .refused("A new schedule needs `name`, `prompt`, `rrule` and `project`.")
      }
      // APFS is case-insensitive: `Hand` and `hand` are the same folder to the filesystem, so
      // a case-sensitive `taken` would let `uniqueID` hand out an id that collides with one.
      let taken =
        Set(directoryEntries().map { $0.lowercased() })
        .union(runTimes().keys.map { $0.lowercased() })
      let folder = ProjectPath.normalize(cwd)
      automation = CodexAutomation(
        id: CodexAutomationFile.uniqueID(for: name, taken: taken), kind: "cron", name: name,
        prompt: prompt, status: status ?? "ACTIVE", rrule: rule, model: nil, reasoningEffort: nil,
        notificationPolicy: nil, pluginTemplateId: nil, executionEnvironment: "local",
        localEnvironmentConfigPath: nil, target: target(forFolder: folder), cwds: [folder],
        targetThreadId: nil, createdAt: stamp, updatedAt: stamp)
      created = true
    }

    var earlyRun: EarlyRun?
    if !created {
      let before = automation
      if let name = input.name { automation.name = name }
      if let prompt = input.prompt { automation.prompt = prompt }
      if let rule { automation.rrule = rule }
      if let status { automation.status = status }
      if let cwd = input.cwd {
        let folder = ProjectPath.normalize(cwd)
        automation.cwds = [folder]
        automation.target = target(forFolder: folder)
      }
      automation.updatedAt = stamp
      earlyRun = self.earlyRun(before: before, after: automation, newRule: rule, now: now)
    }
    if let model = input.model { automation.model = model.isEmpty ? nil : model }
    if let effort = input.reasoningEffort {
      automation.reasoningEffort = effort.isEmpty ? nil : effort
    }

    if let failure = write(automation, created: created) { return .refused(failure) }
    return .saved(automation, created: created, earlyRun: earlyRun)
  }

  /// What the Codex row left behind means for an update, read from `codex-dev.db` read-only. A
  /// row with no `next_run_at` gets a fresh one, and a missing row a fresh row, so only a stored
  /// time can fire early. A rule is compared in Codex's spelling, so a respelled rule is not new.
  private func earlyRun(
    before: CodexAutomation, after: CodexAutomation, newRule: String?, now: Date
  ) -> EarlyRun? {
    guard after.status == "ACTIVE", let next = runTimes()[after.id]?.nextRunAt else { return nil }
    if before.status == "PAUSED", next <= now { return .dueWhilePaused }
    let oldRule = CodexAutomationFile.normalizedRRule(before.rrule) ?? before.rrule
    if let newRule, newRule != oldRule { return .oldTime }
    return nil
  }

  /// `fB`: a temporary file beside the real one, then a rename over it.
  ///
  /// **A create never replaces.** It only ever `moveItem`s the temporary file into place, and
  /// refuses outright if the target is somehow already there — case-insensitively, most often:
  /// APFS treats `Hand` and `hand` as the same folder, so a `taken` set that missed that (fixed
  /// above, in `taken`'s lowercasing) could otherwise hand out an id that already has a file
  /// Armada never wrote, and `replaceItemAt` would happily overwrite it.
  ///
  /// **A folder this call created is removed if the write then fails**, so a failed create never
  /// leaves an empty `<id>/` behind to block that id for good.
  private func write(_ automation: CodexAutomation, created: Bool) -> String? {
    let target = fileURL(automation.id)
    let folder = target.deletingLastPathComponent()
    let temporary = folder.appending(
      path: ".automation.toml.tmp-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)")
    let targetExists = FileManager.default.fileExists(atPath: target.path(percentEncoded: false))
    if created && targetExists {
      return "\(automation.id) already has a file Armada did not write; refusing to replace it."
    }
    let folderExisted = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(CodexAutomationFile.serialize(automation).utf8).write(to: temporary)
      if targetExists {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: target)
      }
      return nil
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      if created && !folderExisted { try? FileManager.default.removeItem(at: folder) }
      return "Could not write \(target.path(percentEncoded: false)): \(error.localizedDescription)"
    }
  }

  func remove(id: String) -> RemoveResult {
    Self.lock.withLock { performRemove(id: id) }
  }

  private func performRemove(id: String) -> RemoveResult {
    if isAccountOwned() { return .refused(Self.accountOwnedRefusal) }
    guard Self.isValidID(id), let listed = list().first(where: { $0.id == id }) else {
      return .refused(Self.unknownID(id))
    }
    guard case .automation(let automation) = listed.parsed else {
      return .refused("\(id) was edited by hand, so Armada leaves it for you to remove.")
    }
    if let refusal = Self.kindRefusal(automation) { return .refused(refusal) }
    do {
      try FileManager.default.removeItem(at: listed.fileURL.deletingLastPathComponent())
      return .removed(automation)
    } catch {
      return .refused("Could not remove \(id): \(error.localizedDescription)")
    }
  }

  // MARK: SQLite, read-only

  struct Row {
    let statement: OpaquePointer
    func text(_ column: Int32) -> String? {
      sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    func date(_ column: Int32) -> Date? {
      sqlite3_column_type(statement, column) == SQLITE_NULL
        ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, column)) / 1000)
    }
  }

  /// Runs `sql` against a database that may not exist, may be missing the table, or may be mid
  /// write by the Codex app. Each of those yields no rows rather than an error: run state is a
  /// nicety, and none of them should stop a listing.
  private static func query(_ url: URL, _ sql: String, _ each: (Row) -> Void) {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK,
      let db
    else {
      sqlite3_close(db)
      return
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 1_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return
    }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW { each(Row(statement: statement)) }
  }
}
