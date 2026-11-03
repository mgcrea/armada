import Darwin
import Foundation
import os

/// Reads every transcript and rollout on this Mac into a ledger of tokens spent, a folder,
/// an account and a model at a time.
///
/// **Every file, not only saved projects', and keyed by the folder a session started in.**
/// A project is a view over that ledger (`ProjectStats`), so adding one shows its history at
/// once and nesting one needs no rescan.
///
/// **Incremental, resumable and never lowering a total.**
///
/// - Each file keeps a cursor: the byte after its last whole line. A pass reads only what was
///   appended since, in 1MB chunks, and commits the cursor, the dedupe keys and the tokens
///   in one transaction.
/// - A file that shrank or whose first bytes changed was rewritten. It is read again from
///   zero under a new slot, and when that read reaches the end, whatever the old read counted
///   beyond the new one is kept in `archive`.
/// - A file that is gone — Claude Code removes transcripts after 30 days by default — has its
///   figures folded into `archive` and its dedupe keys kept, so a copy that turns up later
///   counts for nothing.
///
/// **Skill uses are kept one row each, behind a second cursor.** A Claude transcript's
/// `skill_offset` can trail its token cursor. A read starts at the lesser of the two and each
/// half reads only past its own, so a backfill rides the pass it is part of and never counts
/// a token twice. A use is keyed by its own id, so a copy of it counts once.
///
/// **A slot holds only the uses its file still holds**, which is what lets a file be read
/// again for them. While a rewrite is read, each use the new version still holds moves to
/// its slot; once the read reaches the end, what the old version alone held stays with no
/// file, like the uses of a file that is gone. A use with no file is never deleted.
///
/// **A file read by an older skill parser (`skill_parser`) is read again when the pass
/// reaches it.** That includes every file of a ledger that counted tokens before skills. Its
/// own slot's uses are deleted and read back in the same transaction, from byte zero for
/// skills only. Nothing else is touched, so a file that is gone, or under an account no
/// longer read, keeps the uses it had.
///
/// **Order matters for the first pass.** Codex rollouts go first by name, so a parent is read
/// before the forks that replay it; then Claude transcripts newest first, so the 7-day and
/// 30-day figures fill in long before the old ones; and a session's own transcript before its
/// subagents', which take its folder.
///
/// **The transcript archive is read for skill uses only** (`Source.skillsOnly`), so skill
/// history reaches back past the 30 days Claude Code keeps, and a token is never counted from
/// a copy. Its files are keyed with `~a:` before their usual key, so a copy never shares a row
/// with its live file, and go after every live file, so a use both hold is the live file's. An
/// archive that cannot be listed, a NAS not mounted, folds nothing. The archive is only read.
actor UsageIndexer {
  nonisolated struct Source: Hashable, Sendable {
    let account: String
    let vendor: UsageVendor
    /// Claude: the account's `projects/`. Codex: the home itself.
    let root: URL
    /// The transcript archive's copy of an account: read for its skill uses, never its tokens.
    let skillsOnly: Bool

    init(account: String, vendor: UsageVendor, root: URL, skillsOnly: Bool = false) {
      self.account = account
      self.vendor = vendor
      self.root = root
      self.skillsOnly = skillsOnly
    }

    var id: String {
      skillsOnly ? "~a|\(vendor.rawValue)|\(account)" : "\(vendor.rawValue)|\(account)"
    }

    /// On an archive file's key and its `parentSession`, so it never shares a `files` row
    /// with the live copy.
    static let archiveKeyPrefix = "~a:"
  }

  nonisolated struct Progress: Equatable, Sendable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var firstPass = false
  }

  nonisolated struct FileItem: Sendable {
    let source: Source
    let key: String
    let url: URL
    let relativePath: String
    let size: Int64
    let mtime: Double
    let inode: Int64
    /// A Claude subagent transcript's parent session, whose folder it takes.
    let parentSession: String?

    /// An archive file's is its live session's: the prefix comes off, and so does the
    /// `~<n>` of a rewrite the archive kept beside the new copy.
    var sessionID: String {
      let id = parentSession ?? key
      let prefix = Source.archiveKeyPrefix
      guard id.hasPrefix(prefix) else { return id }
      let bare = id.dropFirst(prefix.count)
      guard let tilde = bare.lastIndex(of: "~") else { return String(bare) }
      let number = bare[bare.index(after: tilde)...]
      let isVersion = !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
      return String(isVersion ? bare[..<tilde] : bare)
    }
    /// The vendor and account, never `skillsOnly`: the key's prefix already tells an archive
    /// file from the live copy, and a live file's identity stays what it always was.
    var identity: String { "\(source.vendor.rawValue)|\(source.account)|\(key)" }
  }

  private nonisolated struct StoredFile {
    let slot: Int64
    let source: String
    let account: String
    let key: String
    let path: String
    let inode: Int64
    let size: Int64
    let mtime: Double
    let headHash: Int64
    let headLength: Int64
    let cwd: String?
    let cursor: IngestCursor
    /// Restarted at zero when `skillsStale`, so a stale file is never skipped as unchanged.
    let skillCursor: SkillCursor
    /// Its uses were read by an older skill parser, and are read again from byte zero.
    let skillsStale: Bool
    let replaces: Int64?

    /// The `Source.id` it was listed under, which the fold check looks for in `listed`: an
    /// archive file is gone only when the archive could be listed, never when it is unmounted.
    var listing: String {
      key.hasPrefix(Source.archiveKeyPrefix) ? "~a|" + source : source
    }

    /// Where a read of it starts: each half reads past its own cursor, and a Codex rollout
    /// has only tokens.
    func start(_ vendor: UsageVendor) -> Int64 {
      vendor == .claude ? min(cursor.offset, skillCursor.offset) : cursor.offset
    }
  }

  private nonisolated struct DayModel: Hashable {
    let day: Int
    let model: String
  }

  static let schemaVersion = 2
  /// Bumped when the reading of skill uses changes: every file still on disk is read again
  /// for its uses, one at a time as each is reached.
  static let skillParserVersion = 1
  static let chunkBytes = 1 << 20
  static let commitBytes: Int64 = 64 << 20
  static let headBytes: Int64 = 4_096

  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "index")

  private static let schema = """
    CREATE TABLE IF NOT EXISTS files(
      slot INTEGER PRIMARY KEY, account TEXT NOT NULL, vendor INTEGER NOT NULL,
      key TEXT NOT NULL, path TEXT NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL,
      mtime REAL NOT NULL, head_hash INTEGER NOT NULL, head_len INTEGER NOT NULL, cwd TEXT,
      cursor TEXT NOT NULL, replaces INTEGER, superseded INTEGER NOT NULL DEFAULT 0,
      skill_offset INTEGER NOT NULL DEFAULT 0, skill_state TEXT,
      skill_parser INTEGER NOT NULL DEFAULT 0);
    CREATE UNIQUE INDEX IF NOT EXISTS files_key ON files(vendor, account, key)
      WHERE superseded = 0;
    CREATE TABLE IF NOT EXISTS skill_uses(
      use_id TEXT PRIMARY KEY, slot INTEGER,
      day INTEGER NOT NULL, cwd TEXT NOT NULL, account TEXT NOT NULL, vendor INTEGER NOT NULL,
      skill TEXT NOT NULL, kind INTEGER NOT NULL,
      session_id TEXT NOT NULL, at REAL NOT NULL, entry_uuid TEXT NOT NULL,
      args TEXT, reply TEXT) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS skill_uses_slot ON skill_uses(slot);
    CREATE TABLE IF NOT EXISTS seen(hash INTEGER PRIMARY KEY, slot INTEGER NOT NULL)
      WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS file_usage(
      slot INTEGER NOT NULL, day INTEGER NOT NULL, model TEXT NOT NULL,
      fresh INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL,
      output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
      PRIMARY KEY(slot, day, model)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS archive(
      day INTEGER NOT NULL, cwd TEXT NOT NULL, account TEXT NOT NULL, vendor INTEGER NOT NULL,
      model TEXT NOT NULL, fresh INTEGER NOT NULL, cache_write INTEGER NOT NULL,
      cache_read INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
      PRIMARY KEY(day, cwd, account, vendor, model)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS sessions(
      account TEXT NOT NULL, vendor INTEGER NOT NULL, session_id TEXT NOT NULL,
      cwd TEXT NOT NULL, first_at REAL NOT NULL, last_at REAL NOT NULL,
      is_child INTEGER NOT NULL, PRIMARY KEY(account, vendor, session_id)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    """

  /// The upsert that adds a row of tokens to whatever `archive` already holds for its key.
  private static let archiveConflict = """
    ON CONFLICT(day, cwd, account, vendor, model) DO UPDATE SET
      fresh = fresh + excluded.fresh, cache_write = cache_write + excluded.cache_write,
      cache_read = cache_read + excluded.cache_read, output = output + excluded.output,
      reasoning = reasoning + excluded.reasoning
    """

  private let url: URL
  private let commitBytes: Int64
  private let chunkBytes: Int
  private var database: UsageDatabase?
  private var generation = 0
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  /// The sizes are for tests, which need a file read in several commits to be small.
  init(
    url: URL, commitBytes: Int64 = UsageIndexer.commitBytes,
    chunkBytes: Int = UsageIndexer.chunkBytes
  ) {
    self.url = url
    self.commitBytes = commitBytes
    self.chunkBytes = chunkBytes
  }

  /// What the ledger already holds, before any pass: the figures from the last launch.
  func loadSnapshot() -> UsageLedgerSnapshot? {
    guard let db = open() else { return nil }
    return try? buildSnapshot(db)
  }

  /// Read everything that changed since the last pass.
  ///
  /// `progress` is called at most twice a second and `publish` at most every ten seconds,
  /// both from this actor; the caller hops to wherever it draws.
  func runPass(
    sources: [Source], calendar: Calendar,
    progress: @escaping @Sendable (Progress) -> Void,
    publish: @escaping @Sendable (UsageLedgerSnapshot) -> Void
  ) -> UsageLedgerSnapshot? {
    guard let db = open() else { return nil }
    let started = Date()
    do {
      let stored = try loadFiles(db)
      let (items, listed) = Self.enumerate(sources)

      var work: [(item: FileItem, stored: StoredFile?)] = []
      var present: Set<String> = []
      try db.begin()
      for item in items {
        present.insert(item.identity)
        let file = stored[item.identity]
        if let file, file.inode == item.inode, file.size == item.size, file.mtime == item.mtime,
          file.start(item.source.vendor) >= item.size, file.replaces == nil
        {
          // Unchanged. A Codex rollout moved into `archived_sessions` keeps its inode and
          // arrives here under a new path, which is all that needs writing down.
          if file.path != item.relativePath {
            try db.run(
              "UPDATE files SET path = ? WHERE slot = ?",
              [.text(item.relativePath), .int(file.slot)])
          }
          continue
        }
        work.append((item, file))
      }
      for (identity, file) in stored where !present.contains(identity) {
        // Only under a root this pass could list: a folder that failed to open says nothing
        // about whether the files in it are gone.
        guard listed.contains(file.listing) else { continue }
        try fold(file, db)
      }
      try db.commit()

      var parentFolders: [String: String] = [:]
      for file in stored.values where file.source.hasPrefix("\(UsageVendor.claude.rawValue)|") {
        if !file.key.contains("/"), let cwd = file.cursor.cwd {
          parentFolders["\(file.account)|\(file.key)"] = cwd
        }
      }

      let firstPass = try meta("first_pass_done", db) != "1"
      var report = Progress(
        filesDone: 0, filesTotal: work.count, bytesDone: 0,
        bytesTotal: work.reduce(0) {
          $0 + max(0, $1.item.size - ($1.stored?.start($1.item.source.vendor) ?? 0))
        },
        firstPass: firstPass)
      progress(report)
      var lastProgress = Date.distantPast
      var lastPublish = Date()

      for (item, file) in work {
        if Task.isCancelled { break }
        let parentFolder = item.parentSession.flatMap {
          parentFolders["\(item.source.account)|\($0)"]
        }
        do {
          let folder = try process(
            item, stored: file, parentFolder: parentFolder, db: db, calendar: calendar,
            onBytes: { bytes in
              report.bytesDone += Int64(bytes)
              if Date().timeIntervalSince(lastProgress) > 0.5 {
                progress(report)
                lastProgress = Date()
              }
            },
            onCommit: {
              guard Date().timeIntervalSince(lastPublish) > 10,
                let snapshot = try? buildSnapshot(db)
              else { return }
              publish(snapshot)
              lastPublish = Date()
            })
          if item.source.vendor == .claude, item.parentSession == nil, let folder {
            parentFolders["\(item.source.account)|\(item.key)"] = folder
          }
        } catch is CancellationError {
          break
        } catch {
          // One unreadable file must not stop the pass; it is tried again next time.
          Self.logger.error(
            "index skipped \(item.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
        report.filesDone += 1
      }
      progress(report)

      if !Task.isCancelled {
        try setMeta("first_pass_done", "1", db)
        try setMeta("skills_pass_done", "1", db)
      }
      let snapshot = try buildSnapshot(db)
      let seconds = Date().timeIntervalSince(started)
      Self.logger.info(
        "index pass: \(report.filesDone, privacy: .public)/\(work.count, privacy: .public) files, \(report.bytesDone, privacy: .public) bytes, \(seconds, format: .fixed(precision: 1), privacy: .public)s\(Task.isCancelled ? " (cancelled)" : "", privacy: .public)"
      )
      return snapshot
    } catch {
      try? db.rollback()
      Self.logger.error("index pass failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  // MARK: - One file

  /// Read one file from its cursor to its end, committing as it goes. Returns the folder its
  /// session started in, for the subagent transcripts that come after it.
  private func process(
    _ item: FileItem, stored: StoredFile?, parentFolder: String?, db: UsageDatabase,
    calendar: Calendar, onBytes: (Int) -> Void, onCommit: () -> Void
  ) throws -> String? {
    let (headHash, headLength) = try Self.headHash(
      item.url, size: item.size, length: stored?.headLength)

    try db.begin()
    var inTransaction = true
    defer { if inTransaction { try? db.rollback() } }

    var slot: Int64
    var cursor: IngestCursor
    var skills: SkillCursor
    var replaces: Int64?

    if let stored, item.size >= stored.cursor.offset, headHash == stored.headHash,
      stored.inode == item.inode || stored.path != item.relativePath
    {
      slot = stored.slot
      cursor = stored.cursor
      skills = stored.skillCursor
      replaces = stored.replaces
      if stored.skillsStale {
        // Read back from byte zero below, in this transaction. Uses still on the slot being
        // replaced are not this file's yet, and stay.
        try db.run("DELETE FROM skill_uses WHERE slot = ?", [.int(slot)])
      }
    } else {
      if let stored {
        if let older = stored.replaces {
          // Rewritten again before the last rewrite was read to the end: compare against
          // the original, and drop the partial read in between. Its uses happened, so they
          // go back to the original's slot, to move on as the new version holds them.
          try db.run("DELETE FROM file_usage WHERE slot = ?", [.int(stored.slot)])
          try db.run("DELETE FROM seen WHERE slot = ?", [.int(stored.slot)])
          try db.run(
            "UPDATE skill_uses SET slot = ? WHERE slot = ?", [.int(older), .int(stored.slot)])
          try db.run("DELETE FROM files WHERE slot = ?", [.int(stored.slot)])
          replaces = older
        } else {
          try db.run("UPDATE files SET superseded = 1 WHERE slot = ?", [.int(stored.slot)])
          // Its own messages have to be claimable again by the re-read. Messages another
          // file owns stay owned there.
          try db.run("DELETE FROM seen WHERE slot = ?", [.int(stored.slot)])
          replaces = stored.slot
        }
      }
      cursor = IngestCursor()
      skills = SkillCursor()
      if item.parentSession != nil { cursor.cwd = parentFolder }
      try db.run(
        """
        INSERT INTO files(account, vendor, key, path, inode, size, mtime, head_hash, head_len,
          cwd, cursor, replaces, skill_parser)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(item.source.account), .int(Int64(item.source.vendor.rawValue)), .text(item.key),
          .text(item.relativePath), .int(item.inode), .int(item.size), .double(item.mtime),
          .int(headHash), .int(headLength), .null, .text(try encode(cursor)),
          replaces.map { .int($0) } ?? .null, .int(Int64(Self.skillParserVersion)),
        ])
      slot = db.lastInsertRowID
    }

    let vendor = Int64(item.source.vendor.rawValue)
    var tallies: [DayModel: TokenTally] = [:]
    var storeError: Error?
    let claim: (UInt64) -> Bool = { hash in
      do {
        try db.run(
          "INSERT OR IGNORE INTO seen(hash, slot) VALUES (?, ?)",
          [.int(Int64(bitPattern: hash)), .int(slot)])
        return db.changes > 0
      } catch {
        storeError = error
        return false
      }
    }
    let sink: (IngestContribution) -> Void = { contribution in
      tallies[DayModel(day: contribution.day, model: contribution.model), default: TokenTally()] +=
        contribution.tokens
    }
    let skill: (SkillContribution) -> Bool = { contribution in
      let use = contribution.event
      do {
        try db.run(
          """
          INSERT OR IGNORE INTO skill_uses(use_id, slot, day, cwd, account, vendor, skill, kind,
            session_id, at, entry_uuid, args)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            .text(use.useID), .int(slot), .int(Int64(contribution.day)),
            .text(Self.storedFolder(contribution.cwd ?? "")), .text(item.source.account),
            .int(vendor), .text(use.skill), .int(Int64(use.kind.rawValue)),
            .text(item.sessionID), .double(use.at.timeIntervalSince1970), .text(use.entryUUID),
            use.args.map { .text($0) } ?? .null,
          ])
        if db.changes > 0 { return true }
        if let replaces {
          // The new version still holds it, so it is this file's now.
          try db.run(
            "UPDATE skill_uses SET slot = ? WHERE use_id = ? AND slot = ?",
            [.int(slot), .text(use.useID), .int(replaces)])
        }
        return false
      } catch {
        storeError = error
        return false
      }
    }
    let reply: ([String], String) -> Void = { ids, text in
      for id in ids {
        do {
          try db.run(
            "UPDATE skill_uses SET reply = ? WHERE use_id = ? AND reply IS NULL",
            [.text(text), .text(id)])
        } catch {
          storeError = error
        }
      }
    }

    func flush() throws {
      let folder = cursor.cwd.map(Self.storedFolder)
      // A rollout has no skills: its skill cursor keeps up with its tokens.
      let isClaude = item.source.vendor == .claude
      try db.run(
        """
        UPDATE files SET path = ?, inode = ?, size = ?, mtime = ?, head_hash = ?, head_len = ?,
          cwd = ?, cursor = ?, skill_offset = ?, skill_state = ?, skill_parser = ? WHERE slot = ?
        """,
        [
          .text(item.relativePath), .int(item.inode), .int(item.size), .double(item.mtime),
          .int(headHash), .int(headLength), folder.map { .text($0) } ?? .null,
          .text(try encode(cursor)), .int(isClaude ? skills.offset : cursor.offset),
          isClaude ? .text(try encode(skills)) : .null, .int(Int64(Self.skillParserVersion)),
          .int(slot),
        ])
      for (key, tokens) in tallies where !tokens.isZero {
        try db.run(
          """
          INSERT INTO file_usage(slot, day, model, fresh, cache_write, cache_read, output, reasoning)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(slot, day, model) DO UPDATE SET
            fresh = fresh + excluded.fresh, cache_write = cache_write + excluded.cache_write,
            cache_read = cache_read + excluded.cache_read, output = output + excluded.output,
            reasoning = reasoning + excluded.reasoning
          """,
          [
            .int(slot), .int(Int64(key.day)), .text(key.model), .int(Int64(tokens.fresh)),
            .int(Int64(tokens.cacheWrite)), .int(Int64(tokens.cacheRead)),
            .int(Int64(tokens.output)), .int(Int64(tokens.reasoning)),
          ])
      }
      tallies = [:]
      // Only a file that counted something makes a session: a pure mirror adds none.
      if let first = cursor.firstAt, let last = cursor.lastAt, let folder {
        try db.run(
          """
          INSERT INTO sessions(account, vendor, session_id, cwd, first_at, last_at, is_child)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(account, vendor, session_id) DO UPDATE SET
            first_at = MIN(first_at, excluded.first_at), last_at = MAX(last_at, excluded.last_at)
          """,
          [
            .text(item.source.account), .int(Int64(item.source.vendor.rawValue)),
            .text(item.sessionID), .text(folder), .double(first.timeIntervalSince1970),
            .double(last.timeIntervalSince1970), .int(cursor.isChild ? 1 : 0),
          ])
      }
    }

    // The file offset of `pending`'s first byte.
    var base =
      item.source.vendor == .claude ? min(cursor.offset, skills.offset) : cursor.offset
    let handle = try FileHandle(forReadingFrom: item.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(base))
    var pending = Data()
    var sinceCommit: Int64 = 0

    while true {
      if Task.isCancelled { throw CancellationError() }
      guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
      pending.append(chunk)
      let used =
        switch item.source.vendor {
        case .claude:
          FileIngest.claude(
            pending, base: base, cursor: &cursor, skills: &skills,
            tokens: !item.source.skillsOnly,
            subagent: item.parentSession != nil, calendar: calendar, claim: claim, sink: sink,
            skill: skill, reply: reply)
        case .codex:
          FileIngest.codex(pending, cursor: &cursor, calendar: calendar, claim: claim, sink: sink)
        }
      if let storeError { throw storeError }
      pending = Data(pending.dropFirst(used))
      base += Int64(used)
      sinceCommit += Int64(chunk.count)
      onBytes(chunk.count)
      if sinceCommit >= commitBytes {
        try flush()
        try db.commit()
        onCommit()
        try db.begin()
        sinceCommit = 0
      }
    }

    try flush()
    if let replaces { try finishReplacement(old: replaces, new: slot, db) }
    try db.commit()
    inTransaction = false
    onCommit()
    return cursor.cwd
  }

  /// A rewritten file was read to its end: keep whatever the old read counted beyond it.
  private func finishReplacement(old: Int64, new: Int64, _ db: UsageDatabase) throws {
    try db.run(
      """
      INSERT INTO archive(day, cwd, account, vendor, model, fresh, cache_write, cache_read,
        output, reasoning)
      SELECT o.day, IFNULL(f.cwd, ''), f.account, f.vendor, o.model,
        MAX(0, o.fresh - IFNULL(n.fresh, 0)), MAX(0, o.cache_write - IFNULL(n.cache_write, 0)),
        MAX(0, o.cache_read - IFNULL(n.cache_read, 0)), MAX(0, o.output - IFNULL(n.output, 0)),
        MAX(0, o.reasoning - IFNULL(n.reasoning, 0))
      FROM file_usage o JOIN files f ON f.slot = o.slot
      LEFT JOIN file_usage n ON n.slot = ? AND n.day = o.day AND n.model = o.model
      WHERE o.slot = ?
      \(Self.archiveConflict)
      """, [.int(new), .int(old)])
    try db.run("DELETE FROM file_usage WHERE slot = ?", [.int(old)])
    // What the new version holds moved over as it was read. The rest only the old version
    // held: it happened, and stays with no file, like a gone file's uses.
    try db.run("UPDATE skill_uses SET slot = NULL WHERE slot = ?", [.int(old)])
    try db.run("DELETE FROM files WHERE slot = ?", [.int(old)])
    try db.run("UPDATE files SET replaces = NULL WHERE slot = ?", [.int(new)])
  }

  /// A file that is gone: its figures move to `archive`, its dedupe keys stay, and its skill
  /// uses stay with no file.
  private func fold(_ file: StoredFile, _ db: UsageDatabase) throws {
    if let old = file.replaces { try finishReplacement(old: old, new: file.slot, db) }
    try db.run(
      """
      INSERT INTO archive(day, cwd, account, vendor, model, fresh, cache_write, cache_read,
        output, reasoning)
      SELECT u.day, IFNULL(f.cwd, ''), f.account, f.vendor, u.model, u.fresh, u.cache_write,
        u.cache_read, u.output, u.reasoning
      FROM file_usage u JOIN files f ON f.slot = u.slot
      WHERE u.slot = ?
      \(Self.archiveConflict)
      """, [.int(file.slot)])
    try db.run("DELETE FROM file_usage WHERE slot = ?", [.int(file.slot)])
    try db.run("UPDATE skill_uses SET slot = NULL WHERE slot = ?", [.int(file.slot)])
    try db.run("DELETE FROM files WHERE slot = ?", [.int(file.slot)])
  }

  // MARK: - Snapshot

  private func buildSnapshot(_ db: UsageDatabase) throws -> UsageLedgerSnapshot {
    var rows: [UsageRow] = []
    try db.query(
      """
      SELECT day, cwd, account, vendor, model, SUM(fresh), SUM(cache_write), SUM(cache_read),
        SUM(output), SUM(reasoning)
      FROM (
        SELECT u.day AS day, IFNULL(f.cwd, '') AS cwd, f.account AS account, f.vendor AS vendor,
          u.model AS model, u.fresh AS fresh, u.cache_write AS cache_write,
          u.cache_read AS cache_read, u.output AS output, u.reasoning AS reasoning
        FROM file_usage u JOIN files f ON f.slot = u.slot WHERE f.superseded = 0
        UNION ALL
        SELECT day, cwd, account, vendor, model, fresh, cache_write, cache_read, output, reasoning
        FROM archive
      )
      GROUP BY day, cwd, account, vendor, model
      """
    ) { row in
      guard let cwd = row.text(1), let account = row.text(2), let model = row.text(4),
        let vendor = UsageVendor(rawValue: Int(row.int(3)))
      else { return }
      rows.append(
        UsageRow(
          day: Int(row.int(0)), cwd: cwd, account: account, vendor: vendor, model: model,
          tokens: TokenTally(
            fresh: Int(row.int(5)), cacheWrite: Int(row.int(6)), cacheRead: Int(row.int(7)),
            output: Int(row.int(8)), reasoning: Int(row.int(9)))))
    }

    var sessions: [UsageSessionRow] = []
    try db.query(
      "SELECT account, vendor, session_id, cwd, first_at, last_at, is_child FROM sessions"
    ) { row in
      guard let account = row.text(0), let id = row.text(2), let cwd = row.text(3),
        let vendor = UsageVendor(rawValue: Int(row.int(1)))
      else { return }
      sessions.append(
        UsageSessionRow(
          account: account, vendor: vendor, sessionID: id, cwd: cwd,
          firstAt: Date(timeIntervalSince1970: row.double(4)),
          lastAt: Date(timeIntervalSince1970: row.double(5)), isChild: row.int(6) != 0))
    }

    var skills: [SkillUsageRow] = []
    try db.query(
      """
      SELECT day, cwd, account, vendor, skill, kind, COUNT(*), MAX(at) FROM skill_uses
      GROUP BY day, cwd, account, vendor, skill, kind
      """
    ) { row in
      guard let cwd = row.text(1), let account = row.text(2), let skill = row.text(4),
        let vendor = UsageVendor(rawValue: Int(row.int(3))),
        let kind = SkillKind(rawValue: Int(row.int(5)))
      else { return }
      skills.append(
        SkillUsageRow(
          day: Int(row.int(0)), cwd: cwd, account: account, vendor: vendor, skill: skill,
          kind: kind, count: Int(row.int(6)), lastAt: Date(timeIntervalSince1970: row.double(7))))
    }

    generation += 1
    return UsageLedgerSnapshot(
      generation: generation, rows: rows, sessions: sessions,
      earliestDay: rows.map(\.day).min(), firstPassDone: try meta("first_pass_done", db) == "1",
      skills: skills, skillsPassDone: try meta("skills_pass_done", db) == "1",
      earliestSkillDay: skills.map(\.day).min())
  }

  // MARK: - Storage

  private func open() -> UsageDatabase? {
    if let database { return database }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var db = try UsageDatabase(url: url)
      var version = try db.userVersion()
      if ![0, 1, Self.schemaVersion].contains(version) {
        db.close()
        db = try reopenAside(reason: "schema version \(version)")
        version = 0
      }
      try migrate(db, from: version)
      database = db
      return db
    } catch {
      Self.logger.error("index database unusable: \(error.localizedDescription, privacy: .public)")
      guard let db = try? reopenAside(reason: error.localizedDescription) else { return nil }
      try? migrate(db, from: 0)
      database = db
      return db
    }
  }

  /// **Version 1 is upgraded in place.** It lacks only the skill columns, and its files
  /// arrive with `skill_parser` 0, so each is read again for skills only when the pass
  /// reaches it, as after a new skill parser. Nothing is deleted here: a file that is never
  /// read again keeps its uses. One transaction, so a crash part way through leaves
  /// version 1 to upgrade again.
  private func migrate(_ db: UsageDatabase, from version: Int) throws {
    try db.begin()
    do {
      if version == 1 {
        try db.execute("ALTER TABLE files ADD COLUMN skill_offset INTEGER NOT NULL DEFAULT 0")
        try db.execute("ALTER TABLE files ADD COLUMN skill_state TEXT")
        try db.execute("ALTER TABLE files ADD COLUMN skill_parser INTEGER NOT NULL DEFAULT 0")
      }
      try db.execute(Self.schema)
      // Each file is read again as the pass reaches it; this only says the pass has not.
      let parser = String(Self.skillParserVersion)
      if try meta("skill_parser", db) != parser {
        try db.run("DELETE FROM meta WHERE key = 'skills_pass_done'")
        try setMeta("skill_parser", parser, db)
      }
      try db.setUserVersion(Self.schemaVersion)
      try db.commit()
    } catch {
      try? db.rollback()
      throw error
    }
  }

  /// **Moved aside, never deleted.** The archive holds history no transcript on disk still
  /// has, so a database this build cannot read is kept for a later one that can.
  ///
  /// **A move that fails throws, rather than reopening what is still there.** It used to be
  /// `try?`, and a failed move reopened the same file: a newer build's database, which the
  /// migration then stamped with this build's schema and the pass wrote into. Thrown, `open`
  /// returns nil and the ledger stands down for the pass. See `StoreFile`.
  private func reopenAside(reason: String) throws -> UsageDatabase {
    let stamp = Int(Date().timeIntervalSince1970)
    let fileManager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
      let source = URL(filePath: url.path(percentEncoded: false) + suffix)
      guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
      let target = URL(filePath: url.path(percentEncoded: false) + ".bak-\(stamp)" + suffix)
      try fileManager.moveItem(at: source, to: target)
    }
    Self.logger.error("index database moved aside: \(reason, privacy: .public)")
    return try UsageDatabase(url: url)
  }

  private func loadFiles(_ db: UsageDatabase) throws -> [String: StoredFile] {
    var files: [String: StoredFile] = [:]
    try db.query(
      """
      SELECT slot, account, vendor, key, path, inode, size, mtime, head_hash, head_len, cwd,
        cursor, replaces, skill_offset, skill_state, skill_parser
      FROM files WHERE superseded = 0
      """
    ) { row in
      guard let account = row.text(1), let key = row.text(3), let path = row.text(4),
        let text = row.text(11),
        let cursor = try? decoder.decode(IngestCursor.self, from: Data(text.utf8))
      else { return }
      // No state yet is nothing waiting for a reply. A stale read starts over from zero.
      let stale = row.int(15) < Int64(Self.skillParserVersion)
      var skills = SkillCursor()
      if !stale {
        skills =
          row.text(14).flatMap { try? decoder.decode(SkillCursor.self, from: Data($0.utf8)) }
          ?? SkillCursor()
        skills.offset = row.int(13)
      }
      let source = "\(row.int(2))|\(account)"
      files["\(source)|\(key)"] = StoredFile(
        slot: row.int(0), source: source, account: account, key: key, path: path,
        inode: row.int(5), size: row.int(6), mtime: row.double(7), headHash: row.int(8),
        headLength: row.int(9), cwd: row.text(10), cursor: cursor, skillCursor: skills,
        skillsStale: stale, replaces: row.isNull(12) ? nil : row.int(12))
    }
    return files
  }

  private func meta(_ key: String, _ db: UsageDatabase) throws -> String? {
    var value: String?
    try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
    return value
  }

  private func setMeta(_ key: String, _ value: String, _ db: UsageDatabase) throws {
    try db.run(
      "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [.text(key), .text(value)])
  }

  private func encode(_ cursor: some Encodable) throws -> String {
    String(decoding: try encoder.encode(cursor), as: UTF8.self)
  }

  /// Scratchpads and Armada's own launch scripts collapse to one folder: they are counted,
  /// never suggested, and never part of a project.
  private nonisolated static func storedFolder(_ cwd: String) -> String {
    ProjectPath.isTemporary(cwd) ? "~tmp" : ProjectPath.normalize(cwd)
  }

  // MARK: - Finding files

  nonisolated static func enumerate(_ sources: [Source]) -> (items: [FileItem], listed: Set<String>)
  {
    let fileManager = FileManager.default
    var codex: [FileItem] = []
    var mains: [FileItem] = []
    var subagents: [FileItem] = []
    var archiveMains: [FileItem] = []
    var archiveSubagents: [FileItem] = []
    var listed: Set<String> = []

    for source in sources {
      switch source.vendor {
      case .claude:
        let root = source.root.path(percentEncoded: false)
        guard let folders = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
        listed.insert(source.id)
        // An archive copy is keyed apart from the live one, and read after every live file,
        // so a use both hold is the live file's.
        let prefix = source.skillsOnly ? Source.archiveKeyPrefix : ""
        for folder in folders {
          let folderURL = source.root.appending(path: folder, directoryHint: .isDirectory)
          guard
            let names = try? fileManager.contentsOfDirectory(
              atPath: folderURL.path(percentEncoded: false))
          else { continue }
          for name in names {
            if name.hasSuffix(".jsonl") {
              let item = file(
                source, key: prefix + name.dropLast(".jsonl".count),
                url: folderURL.appending(path: name, directoryHint: .notDirectory),
                relative: "\(folder)/\(name)", parent: nil)
              if let item {
                if source.skillsOnly { archiveMains.append(item) } else { mains.append(item) }
              }
            } else if !name.contains(".") {
              // A session's own folder, which holds its subagents' transcripts.
              let agentsURL = folderURL.appending(path: name, directoryHint: .isDirectory)
                .appending(path: "subagents", directoryHint: .isDirectory)
              guard
                let agents = try? fileManager.contentsOfDirectory(
                  atPath: agentsURL.path(percentEncoded: false))
              else { continue }
              for agent in agents where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                let item = file(
                  source, key: "\(prefix)\(name)/\(agent.dropLast(".jsonl".count))",
                  url: agentsURL.appending(path: agent, directoryHint: .notDirectory),
                  relative: "\(folder)/\(name)/subagents/\(agent)", parent: prefix + name)
                if let item {
                  if source.skillsOnly {
                    archiveSubagents.append(item)
                  } else {
                    subagents.append(item)
                  }
                }
              }
            }
          }
        }

      case .codex:
        // A rollout holds only tokens, which never come from the archive.
        if source.skillsOnly { continue }
        let sessions = source.root.appending(path: "sessions", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
          atPath: sessions.path(percentEncoded: false), isDirectory: &isDirectory),
          isDirectory.boolValue,
          let walker = fileManager.enumerator(atPath: sessions.path(percentEncoded: false))
        {
          listed.insert(source.id)
          for case let relative as String in walker {
            let name = (relative as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let item = file(
              source, key: CodexRollout.sessionId(fromFilename: name) ?? name,
              url: sessions.appending(path: relative, directoryHint: .notDirectory),
              relative: "sessions/\(relative)", parent: nil)
            if let item { codex.append(item) }
          }
        }
        let archived = source.root.appending(path: "archived_sessions", directoryHint: .isDirectory)
        let archivedNames =
          (try? fileManager.contentsOfDirectory(atPath: archived.path(percentEncoded: false))) ?? []
        for name in archivedNames where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
          let item = file(
            source, key: CodexRollout.sessionId(fromFilename: name) ?? name,
            url: archived.appending(path: name, directoryHint: .notDirectory),
            relative: "archived_sessions/\(name)", parent: nil)
          if let item { codex.append(item) }
        }
      }
    }

    codex.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
    mains.sort { $0.mtime > $1.mtime }
    subagents.sort { $0.mtime > $1.mtime }
    archiveMains.sort { $0.mtime > $1.mtime }
    archiveSubagents.sort { $0.mtime > $1.mtime }
    return (
      onePerIdentity(codex + mains + subagents + archiveMains + archiveSubagents), listed
    )
  }

  /// One file per identity, the largest, in the order given.
  ///
  /// **The identity has no folder in it,** so a session found under two project folders —
  /// a `cp -R` of a renamed repo, a backup left inside `projects/` — is two files competing
  /// for one slot. Read both and the slot alternates between them, and every second pass
  /// a shorter copy reads as a rewrite whose difference goes to `archive`, while the longer
  /// one counts its later messages again: a total that grows with no new use. The largest
  /// holds whatever the others do, and on a tie the first path by name is kept, so the
  /// choice does not move between passes.
  nonisolated static func onePerIdentity(_ items: [FileItem]) -> [FileItem] {
    var kept: [String: FileItem] = [:]
    for item in items {
      guard let held = kept[item.identity] else {
        kept[item.identity] = item
        continue
      }
      if item.size > held.size
        || (item.size == held.size && item.relativePath < held.relativePath)
      {
        kept[item.identity] = item
      }
    }
    return items.filter { kept[$0.identity]?.relativePath == $0.relativePath }
  }

  private nonisolated static func file(
    _ source: Source, key: String, url: URL, relative: String, parent: String?
  ) -> FileItem? {
    var info = Darwin.stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0,
      info.st_mode & S_IFMT == S_IFREG
    else { return nil }
    let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return FileItem(
      source: source, key: key, url: url, relativePath: relative, size: Int64(info.st_size),
      mtime: mtime, inode: Int64(bitPattern: UInt64(info.st_ino)), parentSession: parent)
  }

  /// A hash of a file's first bytes, which is what tells an appended file from a rewritten
  /// one. Hashed over the same length as last time, so a young file that grew still matches.
  private nonisolated static func headHash(
    _ url: URL, size: Int64, length stored: Int64?
  ) throws -> (hash: Int64, length: Int64) {
    let length = min(stored ?? headBytes, size)
    guard length > 0 else { return (Int64(bitPattern: StableHash.offsetBasis), 0) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: Int(length)) ?? Data()
    return (Int64(bitPattern: StableHash.fnv1a64(data)), Int64(data.count))
  }
}
