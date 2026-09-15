import Foundation

/// Tokens spent, by kind, the same for both vendors.
///
/// **Four kinds that add up, and one that does not.** `total` is fresh input, cache writes,
/// cache reads and output: every token a request was billed or counted for. `reasoning`
/// is Codex's own breakdown of its output and is already inside `output`, so it is carried
/// for display and never added.
///
/// Cache reads dominate any long session — the whole prefix is re-read on every turn —
/// which is why the four are kept apart rather than folded into one number early.
nonisolated struct TokenTally: Hashable, Sendable {
  var fresh = 0
  var cacheWrite = 0
  var cacheRead = 0
  var output = 0
  var reasoning = 0

  var total: Int { fresh + cacheWrite + cacheRead + output }

  var isZero: Bool { self == TokenTally() }

  static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
    TokenTally(
      fresh: lhs.fresh + rhs.fresh, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
      cacheRead: lhs.cacheRead + rhs.cacheRead, output: lhs.output + rhs.output,
      reasoning: lhs.reasoning + rhs.reasoning)
  }

  static func += (lhs: inout TokenTally, rhs: TokenTally) {
    lhs = lhs + rhs
  }
}

/// Which vendor a figure came from. Stored as its raw value.
nonisolated enum UsageVendor: Int, Hashable, Sendable, CaseIterable {
  case claude = 0
  case codex = 1

  var name: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }
}

/// FNV-1a, 64 bits: the key the indexer deduplicates on.
///
/// **Not `Hasher`.** Swift seeds `Hasher` differently in every process, so a hash stored by
/// one launch would match nothing in the next and every message would count again.
nonisolated enum StableHash {
  static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  static let prime: UInt64 = 0x0000_0100_0000_01b3

  static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
    var hash = offsetBasis
    for byte in bytes {
      hash ^= UInt64(byte)
      hash &*= prime
    }
    return hash
  }

  /// `tag` first, so a Claude message id and a Codex total can never be the same key.
  static func key(tag: UInt8, _ text: String) -> UInt64 {
    var hash = offsetBasis
    hash ^= UInt64(tag)
    hash &*= prime
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash &*= prime
    }
    return hash
  }
}

/// A calendar day as `yyyymmdd`, in the person's time zone at the moment it was counted.
///
/// **Fixed when the line is read.** A day is where the work showed up on the person's
/// calendar; travelling later does not move history into a different day.
nonisolated enum LocalDay {
  static func key(_ date: Date, calendar: Calendar) -> Int {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
  }

  static func date(_ key: Int, calendar: Calendar) -> Date? {
    calendar.date(from: DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100))
  }

  static func adding(_ days: Int, to key: Int, calendar: Calendar) -> Int {
    guard let start = date(key, calendar: calendar),
      let moved = calendar.date(byAdding: .day, value: days, to: start)
    else { return key }
    return Self.key(moved, calendar: calendar)
  }
}

/// One day of one model's tokens, in one folder, on one account.
nonisolated struct UsageRow: Hashable, Sendable {
  let day: Int
  let cwd: String
  let account: String
  let vendor: UsageVendor
  let model: String
  let tokens: TokenTally
}

/// One session the ledger has seen spend tokens, and the folder it started in.
nonisolated struct UsageSessionRow: Hashable, Sendable {
  let account: String
  let vendor: UsageVendor
  let sessionID: String
  let cwd: String
  let firstAt: Date
  let lastAt: Date
  /// A Codex subagent: its tokens count, and it is not counted as a session of its own.
  let isChild: Bool
}

/// Everything the ledger holds, summed, as a value the main actor and the MCP bridge can
/// hold without touching the database.
nonisolated struct UsageLedgerSnapshot: Sendable {
  /// Bumped on every commit, so a view can memoise on it.
  let generation: Int
  let rows: [UsageRow]
  let sessions: [UsageSessionRow]
  /// The oldest day anything was counted for: where "all time" starts.
  let earliestDay: Int?
  /// True once one complete pass over every transcript has finished.
  let firstPassDone: Bool

  static let empty = UsageLedgerSnapshot(
    generation: 0, rows: [], sessions: [], earliestDay: nil, firstPassDone: false)
}
