import Foundation
import SQLite3

/// The smallest SQLite wrapper the usage index needs: statements, bindings, rows and a
/// transaction.
///
/// **SQLite because the ledger has to keep three things in step across a crash**: how far
/// each file has been read, which messages have been counted, and the totals they added.
/// One transaction commits all three or none, which is the whole of the recovery story.
/// The library is the one macOS ships; nothing is added to the build.
///
/// Not thread-safe and not `Sendable`: `UsageIndexer` owns the only instance and every
/// call is on that actor.
nonisolated final class UsageDatabase {
  nonisolated enum Value {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
  }

  nonisolated struct Failure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  nonisolated struct Row {
    let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String? {
      sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
  }

  private var handle: OpaquePointer?
  private var statements: [String: OpaquePointer] = [:]

  /// `SQLITE_TRANSIENT`, which the C header spells as a cast Swift does not import.
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(url: URL) throws {
    var opened: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(url.path(percentEncoded: false), &opened, flags, nil) == SQLITE_OK,
      let opened
    else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
      sqlite3_close(opened)
      throw Failure(message: message)
    }
    handle = opened
    sqlite3_busy_timeout(opened, 5_000)
    // WAL so a reader never waits on the pass, and NORMAL because a power cut may lose the
    // last commit but never corrupts the file — and a lost commit is re-read next pass.
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA synchronous = NORMAL")
  }

  deinit { close() }

  func close() {
    for statement in statements.values { sqlite3_finalize(statement) }
    statements = [:]
    if let handle { sqlite3_close(handle) }
    handle = nil
  }

  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? lastError
      sqlite3_free(error)
      throw Failure(message: message)
    }
  }

  func run(_ sql: String, _ values: [Value] = []) throws {
    let statement = try prepared(sql, values)
    defer { sqlite3_reset(statement) }
    var code = sqlite3_step(statement)
    while code == SQLITE_ROW { code = sqlite3_step(statement) }
    guard code == SQLITE_DONE else { throw Failure(message: lastError) }
  }

  func query(_ sql: String, _ values: [Value] = [], _ each: (Row) throws -> Void) throws {
    let statement = try prepared(sql, values)
    defer { sqlite3_reset(statement) }
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return }
      guard code == SQLITE_ROW else { throw Failure(message: lastError) }
      try each(Row(statement: statement))
    }
  }

  /// Rows the last statement inserted, updated or deleted.
  var changes: Int { Int(sqlite3_changes(handle)) }

  var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

  func begin() throws { try execute("BEGIN IMMEDIATE") }
  func commit() throws { try execute("COMMIT") }
  func rollback() throws { try execute("ROLLBACK") }

  func userVersion() throws -> Int {
    var version = 0
    try query("PRAGMA user_version") { version = Int($0.int(0)) }
    return version
  }

  func setUserVersion(_ version: Int) throws {
    try execute("PRAGMA user_version = \(version)")
  }

  /// Prepared once per distinct SQL text, and reused: a pass runs the same few statements
  /// hundreds of thousands of times.
  private func prepared(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
    let statement: OpaquePointer
    if let cached = statements[sql] {
      statement = cached
      sqlite3_clear_bindings(statement)
    } else {
      var fresh: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &fresh, nil) == SQLITE_OK, let fresh else {
        throw Failure(message: lastError)
      }
      statements[sql] = fresh
      statement = fresh
    }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32 =
        switch value {
        case .int(let number): sqlite3_bind_int64(statement, index, number)
        case .double(let number): sqlite3_bind_double(statement, index, number)
        case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
        case .null: sqlite3_bind_null(statement, index)
        }
      guard code == SQLITE_OK else { throw Failure(message: lastError) }
    }
    return statement
  }

  private var lastError: String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "the database is closed"
  }
}
