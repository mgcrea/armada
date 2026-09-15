import Foundation

/// The spans a project's figures are shown over.
nonisolated enum StatsWindow: String, CaseIterable, Hashable, Sendable {
  case week = "7d"
  case month = "30d"
  case all

  var title: String {
    switch self {
    case .week: "7 days"
    case .month: "30 days"
    case .all: "All time"
    }
  }

  /// Today and the days before it that the window covers; nil for all time.
  var days: Int? {
    switch self {
    case .week: 7
    case .month: 30
    case .all: nil
    }
  }
}

/// What has been spent in one project.
nonisolated struct ProjectUsage: Equatable, Sendable {
  /// One model's, one account's or one subfolder's share.
  struct Slice: Equatable, Sendable, Identifiable {
    /// The model id, the account id, or the folder relative to the project ("" for itself).
    let key: String
    let vendor: UsageVendor?
    var tokens: [StatsWindow: TokenTally] = [:]

    var id: String { key }
  }

  var tokens: [StatsWindow: TokenTally] = [:]
  var sessions: [StatsWindow: Int] = [:]
  var byModel: [Slice] = []
  var byAccount: [Slice] = []
  var byFolder: [Slice] = []
  var lastActive: Date?
}

/// Rolls the ledger up into projects.
///
/// **At query time, from folders, never stored per project.** The ledger is keyed by the
/// folder a session started in, so adding, removing or nesting a project changes these
/// figures immediately and needs no rescan. Each distinct folder is matched to its deepest
/// project once, which is a few hundred matches however many rows there are.
nonisolated enum ProjectStats {
  static func compute(
    projects: [ProjectPath.Candidate], ledger: UsageLedgerSnapshot, today: Date,
    calendar: Calendar
  ) -> [String: ProjectUsage] {
    guard !projects.isEmpty else { return [:] }

    let todayKey = LocalDay.key(today, calendar: calendar)
    var floors: [StatsWindow: Int] = [:]
    for window in StatsWindow.allCases {
      floors[window] =
        window.days.map { LocalDay.adding(-($0 - 1), to: todayKey, calendar: calendar) } ?? .min
    }
    let keysByProject = Dictionary(
      projects.map { ($0.id, $0.keys) }, uniquingKeysWith: { first, _ in first })

    var owners: [String: (id: String, folder: String)?] = [:]
    func owner(of cwd: String) -> (id: String, folder: String)? {
      if let known = owners[cwd] { return known }
      var found: (id: String, folder: String)?
      if let id = ProjectPath.deepest(for: cwd, in: projects) {
        let path = ProjectPath.normalize(cwd)
        let root = keysByProject[id]?.map(ProjectPath.normalize)
          .filter { ProjectPath.contains($0, path) }.max { $0.count < $1.count }
        let folder = root.map { path == $0 ? "" : String(path.dropFirst($0.count + 1)) } ?? path
        found = (id, folder)
      }
      owners[cwd] = found
      return found
    }

    var usage: [String: ProjectUsage] = [:]
    var models: [String: [String: ProjectUsage.Slice]] = [:]
    var accounts: [String: [String: ProjectUsage.Slice]] = [:]
    var folders: [String: [String: ProjectUsage.Slice]] = [:]

    for row in ledger.rows {
      guard let (id, folder) = owner(of: row.cwd) else { continue }
      for window in StatsWindow.allCases where row.day >= floors[window] ?? .min {
        usage[id, default: ProjectUsage()].tokens[window, default: TokenTally()] += row.tokens
        models[id, default: [:]][
          row.model, default: ProjectUsage.Slice(key: row.model, vendor: row.vendor)
        ].tokens[window, default: TokenTally()] += row.tokens
        accounts[id, default: [:]][
          row.account, default: ProjectUsage.Slice(key: row.account, vendor: row.vendor)
        ].tokens[window, default: TokenTally()] += row.tokens
        folders[id, default: [:]][folder, default: ProjectUsage.Slice(key: folder, vendor: nil)]
          .tokens[window, default: TokenTally()] += row.tokens
      }
    }

    for session in ledger.sessions where !session.isChild {
      guard let (id, _) = owner(of: session.cwd) else { continue }
      let day = LocalDay.key(session.lastAt, calendar: calendar)
      for window in StatsWindow.allCases where day >= floors[window] ?? .min {
        usage[id, default: ProjectUsage()].sessions[window, default: 0] += 1
      }
      let latest = usage[id]?.lastActive ?? session.lastAt
      usage[id]?.lastActive = max(latest, session.lastAt)
    }

    func ordered(_ slices: [String: ProjectUsage.Slice]?) -> [ProjectUsage.Slice] {
      (slices.map { Array($0.values) } ?? []).sorted {
        let lhs = $0.tokens[.all]?.total ?? 0
        let rhs = $1.tokens[.all]?.total ?? 0
        return lhs == rhs ? $0.key < $1.key : lhs > rhs
      }
    }
    for id in usage.keys {
      usage[id]?.byModel = ordered(models[id])
      usage[id]?.byAccount = ordered(accounts[id])
      usage[id]?.byFolder = ordered(folders[id])
    }
    return usage
  }
}
