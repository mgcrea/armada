import Foundation
import SQLite3

/// Putting a message in front of an open Codex thread, through `codex queue`.
///
/// **What Codex does with one** (codex-cli 0.163.0, measured 2026-11-15, docs/codex-sessions.md):
/// `codex queue --thread <id> --message <text>` returns at once, printing `Queued message <item>
/// for thread <thread>.`, and adds a row to `queued_items` in `$CODEX_HOME/queue_1.sqlite`. A
/// client that has the thread open takes the row and runs it as a turn: an idle TUI at once
/// (under 200 ms as Armada's watch saw it), a busy one once its turn ends, several in the order
/// queued. A client that
/// resumes the thread later runs whatever is waiting as soon as it opens it. Nobody holding the
/// thread, the row just stays.
///
/// So "delivered" is read the way the Claude Code inbox reads it: the row is gone, which means a
/// client took it.
///
/// Running `codex queue` is `CodexQueueSubmit.swift`'s, apart from this file so that `make unit`
/// compiles the parsers and the queue reads here without the package that runs it.
nonisolated enum CodexQueue {
  enum Submission: Equatable {
    /// The queued item's id, as `codex queue` printed it.
    case queued(item: String)
    /// This `codex` predates `codex queue`; another copy on the Mac may not.
    case tooOld
    /// A sentence for the caller.
    case failed(String)
  }

  static let tooOldSentence =
    "This Mac's codex is too old to queue a message: `codex queue` came with codex-cli 0.163."

  /// An older Codex has no `queue` command: its interactive CLI takes `queue` as a prompt and
  /// refuses `--thread` (clap's wording; not measured against an old copy).
  static func isTooOld(stderr: String) -> Bool {
    stderr.contains("unexpected argument '--thread'")
  }

  /// The item id out of `Queued message <item> for thread <thread>.`, or nil for anything else.
  static func queuedItem(in output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      let words = line.split(separator: " ")
      guard words.count >= 3, words[0] == "Queued", words[1] == "message" else { continue }
      let item = String(words[2])
      guard UUID(uuidString: item) != nil else { continue }
      return item
    }
    return nil
  }

  /// A sentence from what the CLI printed on a failure.
  static func failure(stderr: String) -> String {
    if isTooOld(stderr: stderr) { return tooOldSentence }
    let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
    let reason = lines.first { $0.lowercased().contains("error") } ?? lines.last
    guard let reason, !reason.isEmpty else { return "codex did not queue the message." }
    return "codex did not queue the message: \(reason.trimmingCharacters(in: .whitespaces))"
  }

  /// Whether `item` is still waiting in `home`'s queue: in any `queue_<n>.sqlite`, so a `codex`
  /// writing an older schema's file than the newest one there is still seen. Nil when no queue
  /// can be read, which the caller treats as not knowing rather than as delivered. Ids are
  /// compared without case, so a change in how Codex spells them cannot read as delivered.
  static func isPending(item: String, home: String) -> Bool? {
    var readAny = false
    for url in databases(in: URL(filePath: home, directoryHint: .isDirectory)) {
      switch contains(item, in: url) {
      case true?: return true
      case false?: readAny = true
      case nil: continue
      }
    }
    return readAny ? false : nil
  }

  private static func contains(_ item: String, in url: URL) -> Bool? {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK,
      let db
    else {
      sqlite3_close(db)
      return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 500)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db, "SELECT 1 FROM queued_items WHERE lower(id) = lower(?1)", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, item, -1, transient)
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: return nil
    }
  }

  /// Every `queue_<n>.sqlite` in `home`, newest schema first. Codex numbers its databases by
  /// schema version (`state_5`, `logs_2`), so a new version would be a new file beside the old.
  static func databases(in home: URL) -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: home.path(percentEncoded: false)))
      ?? []
    return names.compactMap { name -> (Int, String)? in
      guard name.hasPrefix("queue_"), name.hasSuffix(".sqlite") else { return nil }
      let number = name.dropFirst("queue_".count).dropLast(".sqlite".count)
      return Int(number).map { ($0, name) }
    }
    .sorted { $0.0 > $1.0 }
    .map { home.appending(path: $0.1, directoryHint: .notDirectory) }
  }
}
