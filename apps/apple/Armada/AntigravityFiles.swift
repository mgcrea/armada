import Foundation
import SQLite3
import SwiftUI

/// The parsers for what the Antigravity CLI writes, with no UI, so `make unit` can check them.
/// Every shape here was read off `agy` 1.5.18 on 2026-11-27; docs/antigravity-sessions.md has
/// the samples.
nonisolated enum AntigravityFiles {
  /// The statuses that mean a turn is under way. Only `_RUNNING` was seen; the binary also
  /// knows `_BUSY` and `_CANCELING`, which are still busy, and `_IDLE` and `_UNSPECIFIED`.
  static let runningStatuses: Set<String> = [
    "CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING",
  ]

  /// One row of `conversation_summaries`.
  struct Summary: Sendable, Hashable {
    /// `conversation_id`, a lowercase UUID.
    let id: String
    /// Written for TUI conversations; empty, so nil, for both measured headless runs.
    let title: String?
    /// The first prompt's text.
    let preview: String?
    /// The first of `workspace_uris`, the folder `agy` ran in. Empty when it listed none, as the
    /// one measured TUI conversation's row did: `merge` then looks elsewhere.
    let cwd: String
    /// `CASCADE_RUN_STATUS_*`.
    let status: String
    let stepCount: Int
    let lastModified: Date?
    let lastUserInput: Date?
    let parentId: String?

    /// What the row says. A crashed `agy` can leave it at `_RUNNING`, so liveness is the
    /// presence lock's to decide (`AntigravitySessionState.of`).
    var isRunning: Bool { AntigravityFiles.runningStatuses.contains(status) }

    var projectName: String {
      cwd.isEmpty ? "Unknown folder" : URL(filePath: cwd).lastPathComponent
    }
  }

  /// The rows last modified at or after `since`, newest first; none when there is no database,
  /// and nil when it is there but could not be read, so a caller can keep what it read last.
  /// Opened read-only, as `CodexQueue` opens Codex's: every `agy` process writes it. The times
  /// are compared once parsed, since their text is not ISO 8601.
  ///
  /// **A WAL database with no `-wal` beside it is opened immutable.** Once the last `agy` has
  /// closed it, its `-wal` and `-shm` are gone, and a read-only connection then cannot set up
  /// the shared memory a WAL read needs: Apple's SQLite opens it and fails the first `prepare`
  /// with `SQLITE_CANTOPEN`. `immutable=1` reads the file as it stands and creates nothing. With
  /// a `-wal` present some `agy` may be writing, so the ordinary read-only open sees its writes.
  static func summaries(databaseAt url: URL, since: Date) -> [Summary]? {
    let path = url.path(percentEncoded: false)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path) else { return [] }
    var db: OpaquePointer?
    let opened =
      fileManager.fileExists(atPath: path + "-wal")
      ? sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
      : sqlite3_open_v2(
        immutableURI(path), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil)
    guard opened == SQLITE_OK, let db else {
      sqlite3_close(db)
      return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 500)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        """
        SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
          status, parent_conversation_id, last_user_input_time
        FROM conversation_summaries
        """, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    func text(_ column: Int32) -> String {
      sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    func nonEmpty(_ column: Int32) -> String? {
      let value = text(column)
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
    var rows: [Summary] = []
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
      defer { step = sqlite3_step(statement) }
      let id = text(0).lowercased()
      guard !id.isEmpty, let modified = date(text(4)), modified >= since else { continue }
      rows.append(
        Summary(
          id: id, title: nonEmpty(1), preview: nonEmpty(2), cwd: cwd(workspaceURIs: text(5)),
          status: text(6), stepCount: Int(sqlite3_column_int64(statement, 3)),
          lastModified: modified, lastUserInput: date(text(8)),
          parentId: nonEmpty(7)?.lowercased()))
    }
    // A read cut short (busy past the timeout, or the file changing under an immutable read)
    // is no answer, rather than the rows before the failure.
    guard step == SQLITE_DONE else { return nil }
    return rows.sorted {
      ($0.lastModified ?? .distantPast, $0.id) > ($1.lastModified ?? .distantPast, $1.id)
    }
  }

  /// `file:<path>?immutable=1`, the path percent-encoded so a `?`, `#` or `%` in it stays path.
  static func immutableURI(_ path: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#%")
    return "file:" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
      + "?immutable=1"
  }

  /// `2026-11-27 07:56:39.575551+00:00`, with or without the fraction.
  static func date(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let space = trimmed.firstIndex(of: " ") else { return nil }
    return UsageSnapshot.parseTimestamp(trimmed.replacingCharacters(in: space...space, with: "T"))
  }

  /// The first `file://` URL's path in a `workspace_uris` JSON array, or `""`.
  static func cwd(workspaceURIs: String) -> String {
    guard
      let array = try? JSONSerialization.jsonObject(with: Data(workspaceURIs.utf8)) as? [Any]
    else { return "" }
    for case let uri as String in array {
      guard let url = URL(string: uri), url.isFileURL else { continue }
      let path = url.path(percentEncoded: false)
      return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    return ""
  }

  /// How long a conversation no process holds stays listed after its row's last write.
  static let recentWindow: TimeInterval = 12 * 3600

  /// `cache/last_conversations.json`: each folder's last conversation, `{"<cwd>": "<id>"}`.
  static func lastConversations(_ data: Data) -> [String: String] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object.compactMapValues { ($0 as? String)?.lowercased() }
  }

  /// `lastConversations` turned around: each conversation's folder. Sorted, so two folders
  /// naming one conversation always give the same answer.
  static func folders(lastConversations: [String: String]) -> [String: String] {
    var folders: [String: String] = [:]
    for (cwd, id) in lastConversations.sorted(by: { $0.key < $1.key }) where folders[id] == nil {
      folders[id] = cwd
    }
    return folders
  }

  /// What a scan lists: every held conversation, with or without a row, and every row written
  /// within `recentWindow`. A held conversation with no row was opened in a TUI and not
  /// prompted yet. Newest row first, then the rowless by id.
  ///
  /// A conversation's folder is the first of these that names one: the row's `workspace_uris`;
  /// the holding process's working directory (`Holder.cwd`), since a TUI conversation's row was
  /// measured with no workspace at all; `last_conversations.json`, which names only each
  /// folder's newest conversation; and `remembered`, what an earlier scan found, so a folder
  /// read off a live process is kept once that process has exited.
  static func merge(
    summaries: [Summary], holders: [String: AntigravityPresence.Holder],
    lastConversations: [String: String], remembered: [String: String] = [:], now: Date
  ) -> [(id: String, summary: Summary?, holder: AntigravityPresence.Holder?, cwd: String)] {
    let named = folders(lastConversations: lastConversations)
    func folder(_ id: String, row: Summary?, holder: AntigravityPresence.Holder?) -> String {
      [row?.cwd, holder?.cwd, named[id], remembered[id]]
        .lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
    let cutoff = now.addingTimeInterval(-recentWindow)
    var seen: Set<String> = []
    var listed:
      [(id: String, summary: Summary?, holder: AntigravityPresence.Holder?, cwd: String)] = []
    for row in summaries where seen.insert(row.id).inserted {
      let holder = holders[row.id]
      guard holder != nil || (row.lastModified ?? .distantPast) >= cutoff else { continue }
      listed.append((row.id, row, holder, folder(row.id, row: row, holder: holder)))
    }
    for (id, holder) in holders.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
      listed.append((id, nil, holder, folder(id, row: nil, holder: holder)))
    }
    return listed
  }

  /// What the whole lines of a stretch of `transcript.jsonl` add up to.
  struct TranscriptDelta: Sendable, Equatable {
    /// Bytes up to and including the last newline: where the next read starts.
    let consumed: Int
    let steps: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    /// The newest `PLANNER_RESPONSE`'s model.
    let model: String?
    let lastStepAt: Date?
    /// The newest `USER_INPUT`'s prompt, unwrapped.
    let lastPrompt: String?
  }

  /// Reads whole lines only. A line still being written has no newline yet, so it is left for
  /// the next read, from `consumed`. Tokens are per model step, so they add.
  static func transcriptDelta(_ data: Data) -> TranscriptDelta {
    guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
      return TranscriptDelta(
        consumed: 0, steps: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, model: nil,
        lastStepAt: nil, lastPrompt: nil)
    }
    let whole = data[data.startIndex...lastNewline]
    var steps = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var model: String?
    var lastStepAt: Date?
    var lastPrompt: String?
    for line in whole.split(separator: UInt8(ascii: "\n")) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      steps += 1
      func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
      input += int("input_tokens")
      output += int("output_tokens")
      cacheRead += int("cache_read_tokens")
      if let name = object["model"] as? String, !name.isEmpty { model = name }
      if let created = (object["created_at"] as? String).flatMap(UsageSnapshot.parseTimestamp) {
        lastStepAt = created
      }
      if object["type"] as? String == "USER_INPUT", let content = object["content"] as? String {
        let prompt = promptText(content)
        if !prompt.isEmpty { lastPrompt = prompt }
      }
    }
    return TranscriptDelta(
      consumed: whole.count, steps: steps, inputTokens: input, outputTokens: output,
      cacheReadTokens: cacheRead, model: model, lastStepAt: lastStepAt, lastPrompt: lastPrompt)
  }

  /// A `USER_INPUT`'s prompt: what is inside `<USER_REQUEST>…</USER_REQUEST>`, without the
  /// `<ADDITIONAL_METADATA>` and `<USER_SETTINGS_CHANGE>` blocks after it.
  static func promptText(_ content: String) -> String {
    guard let open = content.range(of: "<USER_REQUEST>") else {
      return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let rest = content[open.upperBound...]
    let end = rest.range(of: "</USER_REQUEST>")?.lowerBound ?? rest.endIndex
    return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One quota bucket from `agy`'s `statusLine` JSON payload.
  ///
  /// Measured on `agy` 1.5.18 (2026-11-27): four keys under `quota` — `gemini-5h`,
  /// `gemini-weekly`, `3p-5h` and `3p-weekly` — each carrying `remaining_fraction` (0…1),
  /// `reset_time` (ISO 8601 UTC) and `reset_in_seconds`. An untouched bucket reports
  /// `remaining_fraction: 1`, `reset_time: "1970-01-01T00:00:00Z"` and `reset_in_seconds: 0`,
  /// which means its window has not started ticking yet (`resetsAt == nil`), never that it
  /// rolled over in 1970.
  struct Bucket: Sendable, Hashable, Identifiable {
    /// The bucket key as `agy` names it: `"gemini-5h"`, `"gemini-weekly"`, `"3p-5h"`,
    /// `"3p-weekly"`.
    let id: String
    /// Percentage spent (`0…100`), converted from `remaining_fraction` to match Armada's
    /// spent-quota convention across Claude Code, Codex and Grok Build.
    let utilization: Int
    /// When this bucket resets, or nil when the window has not started yet.
    let resetsAt: Date?

    var length: UsageWindowLength? {
      if id == "5h" || id.hasSuffix("-5h") { return .fiveHour }
      if id == "weekly" || id.hasSuffix("-weekly") || id.hasSuffix("-7d") { return .sevenDay }
      return nil
    }

    /// The model group this bucket governs: `"Gemini"` or `"Partner models"` for the measured
    /// prefixes, or the raw prefix for anything `agy` adds later.
    var groupName: String {
      if id.hasPrefix("gemini-") { return "Gemini" }
      if id.hasPrefix("3p-") { return "Partner models" }
      for suffix in ["-5h", "-weekly", "-7d"] where id.hasSuffix(suffix) {
        let prefix = String(id.dropLast(suffix.count))
        if !prefix.isEmpty { return prefix.capitalized }
      }
      return id
    }

    var title: String { groupName }

    var subtitle: String {
      switch length {
      case .fiveHour: "5 hours"
      case .sevenDay: "7 days"
      case nil: ""
      }
    }

    var window: UsageWindow { UsageWindow(utilization: utilization, resetsAt: resetsAt) }

    /// Gemini first (5h, then 7d), then partner models (5h, then 7d), then anything new by id.
    var sortRank: (Int, String) {
      let rank =
        switch id {
        case "gemini-5h": 0
        case "gemini-weekly": 1
        case "3p-5h": 2
        case "3p-weekly": 3
        default: 4
        }
      return (rank, id)
    }
  }

  /// The account's plan limits, read from `agy`'s `statusLine` JSON payload.
  ///
  /// Narrowly decoded: `email`, `context_window`, `workspace` and `cost` in the same payload are
  /// ignored, matching `UsageProbe` and `GrokFiles.Limits`.
  struct Limits: Sendable, Hashable {
    let buckets: [Bucket]
    /// `"Google AI Pro"`, `"Google AI Ultra"`: `plan_tier` when reported.
    let tier: String?
    let observedAt: Date

    var isEmpty: Bool { buckets.isEmpty }

    /// The highest-utilization bucket for a window length (Gemini first on ties), for compact
    /// glance surfaces (`SidebarUsage`, `AntigravitySummary`) where only two lines fit and
    /// whichever pool is closer to its cap is the one worth flagging.
    func peakWindow(_ length: UsageWindowLength) -> UsageWindow? {
      let matching = buckets.filter { $0.length == length }
      guard var best = matching.first else { return nil }
      for candidate in matching.dropFirst() where candidate.utilization > best.utilization {
        best = candidate
      }
      return best.window
    }

    /// The primary bucket for a window length — Gemini's when present, else the first bucket of
    /// that length — kept consistent over time for `WeeklyChart` and `UsageHistory` so the
    /// charted curve does not jump between pools.
    func primaryWindow(_ length: UsageWindowLength) -> UsageWindow? {
      let preferredID = length == .fiveHour ? "gemini-5h" : "gemini-weekly"
      if let preferred = buckets.first(where: { $0.id == preferredID }) {
        return preferred.window
      }
      return buckets.first { $0.length == length }?.window
    }

    /// The bucket matching a `MenuBarLimit` entry (by window length and group name, or the
    /// primary bucket when `model` is nil).
    func window(length: UsageWindowLength, model: String?) -> UsageWindow? {
      if let model {
        return buckets.first { $0.length == length && $0.groupName == model }?.window
      }
      return peakWindow(length)
    }

    var asSnapshot: UsageSnapshot {
      UsageSnapshot(
        fiveHour: primaryWindow(.fiveHour), sevenDay: primaryWindow(.sevenDay), limits: [],
        fetchedAt: observedAt, source: .antigravity)
    }
  }

  static func limits(_ data: Data, observedAt: Date) -> Limits? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return limits(object, observedAt: observedAt)
  }

  static func limits(_ object: [String: Any], observedAt: Date) -> Limits? {
    guard let quota = object["quota"] as? [String: Any], !quota.isEmpty else { return nil }
    var buckets: [Bucket] = []
    for (id, value) in quota {
      guard let entry = value as? [String: Any] else { continue }
      if entry["disabled"] as? Bool == true { continue }
      guard let remaining = (entry["remaining_fraction"] as? NSNumber)?.doubleValue else {
        continue
      }
      let clamped = min(max(remaining, 0), 1)
      let utilization = Int(((1.0 - clamped) * 100.0).rounded())
      let resetInSeconds = (entry["reset_in_seconds"] as? NSNumber)?.doubleValue
      let parsedReset = (entry["reset_time"] as? String).flatMap(UsageSnapshot.parseTimestamp)
      // Untouched pools report `"1970-01-01T00:00:00Z"` with `reset_in_seconds: 0`. Treating
      // epoch 0 as a past reset would make `UsageWindow.hasRolled` void a fresh 0% pool.
      let resetsAt: Date? =
        if let seconds = resetInSeconds, seconds <= 0 {
          nil
        } else if let parsedReset, parsedReset.timeIntervalSince1970 <= 1 {
          nil
        } else {
          parsedReset
        }
      buckets.append(Bucket(id: id, utilization: utilization, resetsAt: resetsAt))
    }
    guard !buckets.isEmpty else { return nil }
    buckets.sort { $0.sortRank < $1.sortRank }
    let tier = (object["plan_tier"] as? String)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .flatMap { $0.isEmpty ? nil : $0 }
    return Limits(buckets: buckets, tier: tier, observedAt: observedAt)
  }
}

/// What an Antigravity conversation appears to be doing: Grok Build's vocabulary, because
/// `agy` answers the same halves of the question. The row says whether a turn runs, the
/// presence lock whether a process still owns the conversation.
nonisolated enum AntigravitySessionState: String, Sendable {
  /// Held, and its row says a turn is running.
  case working
  /// Held, with no turn running: an idle TUI, or one not prompted yet.
  case awaitingInput
  /// No `agy` process holds its lock, whatever the row says.
  case ended

  var label: String {
    switch self {
    case .working: "Working"
    case .awaitingInput: "Waiting for input"
    case .ended: "Ended"
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .awaitingInput: .blue
    case .ended: .secondary
    }
  }

  var isLive: Bool { self != .ended }

  /// The lock decides liveness: a crashed `agy` leaves its row at `_RUNNING`, and that is
  /// ended, not working.
  static func of(
    holder: AntigravityPresence.Holder?, summary: AntigravityFiles.Summary?
  ) -> AntigravitySessionState {
    guard holder != nil else { return .ended }
    return summary?.isRunning == true ? .working : .awaitingInput
  }
}
