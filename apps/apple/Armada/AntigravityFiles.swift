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
    /// The first of `workspace_uris`, the folder `agy` ran in. Empty when it listed none.
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

  /// The rows last modified at or after `since`, newest first, or none when the database
  /// cannot be read. Opened read-only, as `CodexQueue` opens Codex's: every `agy` process
  /// writes it. The times are compared once parsed, since their text is not ISO 8601.
  static func summaries(databaseAt url: URL, since: Date) -> [Summary] {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK,
      let db
    else {
      sqlite3_close(db)
      return []
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
    else { return [] }
    defer { sqlite3_finalize(statement) }
    func text(_ column: Int32) -> String {
      sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    func nonEmpty(_ column: Int32) -> String? {
      let value = text(column)
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
    var rows: [Summary] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = text(0).lowercased()
      guard !id.isEmpty, let modified = date(text(4)), modified >= since else { continue }
      rows.append(
        Summary(
          id: id, title: nonEmpty(1), preview: nonEmpty(2), cwd: cwd(workspaceURIs: text(5)),
          status: text(6), stepCount: Int(sqlite3_column_int64(statement, 3)),
          lastModified: modified, lastUserInput: date(text(8)),
          parentId: nonEmpty(7)?.lowercased()))
    }
    return rows.sorted {
      ($0.lastModified ?? .distantPast, $0.id) > ($1.lastModified ?? .distantPast, $1.id)
    }
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
}

/// What an Antigravity conversation appears to be doing: Grok Build's vocabulary, because
/// `agy` answers the same halves of the question. The row says whether a turn runs, the
/// presence lock whether a process still owns the conversation.
enum AntigravitySessionState: String, Sendable {
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
