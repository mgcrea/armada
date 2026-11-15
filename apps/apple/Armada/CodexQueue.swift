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
nonisolated enum CodexQueue {
  static let timeout: TimeInterval = 15

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

  /// `submit` with each copy in turn while the copy is too old, so an old `codex` early on the
  /// search path does not hide a newer one in ChatGPT or VS Code.
  static func submit(thread: String, text: String, home: String, executables: [URL])
    -> Submission
  {
    for executable in executables {
      let submission = submit(thread: thread, text: text, home: home, executable: executable)
      if submission != .tooOld { return submission }
    }
    return executables.isEmpty ? .failed("Armada cannot find codex on this Mac.") : .tooOld
  }

  /// Runs `codex queue` against `home`. Blocks for as long as the CLI does, which is a fraction
  /// of a second, and never longer than `timeout`.
  static func submit(thread: String, text: String, home: String, executable: URL) -> Submission {
    let process = Process()
    process.executableURL = executable
    // `--message=` rather than `--message` and a separate argument: a text that starts with a
    // dash would otherwise be read as a flag.
    process.arguments = ["queue", "--thread", thread, "--message=\(text)"]
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = home
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors

    do { try process.run() } catch {
      return .failed("Armada could not run codex: \(error.localizedDescription)")
    }
    // To the process group, which a `Process` child leads, so anything it started that holds
    // the pipes goes too and the reads below can end. Only while the leader is unreaped.
    let pid = process.processIdentifier
    let group = getpgid(pid) == pid && pid != getpgrp() ? -pid : pid
    let watchdog = DispatchWorkItem {
      guard process.isRunning else { return }
      kill(group, SIGTERM)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
        if process.isRunning { kill(group, SIGKILL) }
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

    // stderr on another thread while this one reads stdout, so a CLI that fills one pipe while
    // Armada waits on the other cannot stall.
    nonisolated(unsafe) var stderr = Data()
    let drained = DispatchGroup()
    drained.enter()
    DispatchQueue.global(qos: .utility).async {
      stderr = errors.fileHandleForReading.readDataToEndOfFile()
      drained.leave()
    }
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    watchdog.cancel()

    if let item = queuedItem(in: String(decoding: stdout, as: UTF8.self)) {
      return .queued(item: item)
    }
    let message = String(decoding: stderr, as: UTF8.self)
    return isTooOld(stderr: message) ? .tooOld : .failed(failure(stderr: message))
  }

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
