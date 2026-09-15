import ArmadaMCP
import Foundation

/// `armada_get_projects`'s hop: saved projects, the token ledger and the live sessions.
///
/// **The same rule as `FleetBridge.snapshot()`**: one main-actor hop that copies stored
/// values and does no I/O, then everything else after it. The ledger snapshot is a value the
/// usage index already holds, so copying it is free; rolling it up into projects, matching
/// sessions to projects and checking each folder still exists all happen off the main actor.
nonisolated extension FleetBridge {
  func projects() async -> ProjectsSnapshot {
    let captured = await MainActor.run { ProjectsCapture.take(now: Date()) }
    return captured.snapshot()
  }
}

/// What the hop copies.
nonisolated struct ProjectsCapture: Sendable {
  nonisolated struct Live: Sendable {
    let id: String
    let vendor: String
    let name: String
    let state: String
    let cwd: String
  }

  let takenAt: Date
  let isEntitled: Bool
  let projects: [Project]
  let candidates: [ProjectPath.Candidate]
  let ledger: UsageLedgerSnapshot
  let progress: UsageIndexer.Progress?
  let accountNames: [String: String]
  let live: [Live]

  @MainActor
  static func take(now: Date) -> ProjectsCapture {
    var names: [String: String] = [:]
    var live: [Live] = []
    for account in Accounts.shared.all {
      names[account.id] = account.displayName
      for session in account.sessions.sessions {
        live.append(
          Live(
            id: session.id, vendor: "claude", name: session.displayName,
            state: session.state.rawValue, cwd: session.registry.cwd))
      }
    }
    for account in CodexAccounts.shared.all {
      names[account.id] = account.displayName
      for session in account.sessions.liveSessions where !session.isSubagent {
        live.append(
          Live(
            id: session.id, vendor: "codex", name: session.displayName,
            state: session.state.rawValue, cwd: session.meta.cwd))
      }
    }
    return ProjectsCapture(
      takenAt: now, isEntitled: EntitlementMonitor.shared.current.isEntitled,
      projects: ProjectStore.shared.projects, candidates: ProjectStore.shared.candidates,
      ledger: UsageIndex.shared.ledger, progress: UsageIndex.shared.progress,
      accountNames: names, live: live)
  }

  func snapshot() -> ProjectsSnapshot {
    let stats = ProjectStats.compute(
      projects: candidates, ledger: ledger, today: takenAt, calendar: .current)
    let fileManager = FileManager.default

    let rows = projects.map { project -> ProjectsSnapshot.Project in
      let usage = stats[project.id]
      var isDirectory: ObjCBool = false
      let exists =
        fileManager.fileExists(atPath: project.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
      let vendor =
        switch project.agent {
        case .claude: "claude"
        case .codex: "codex"
        }
      return ProjectsSnapshot.Project(
        id: project.id, name: project.displayName, path: project.path, exists: exists,
        defaultAgent: .init(
          vendor: vendor, accountID: project.agent.accountID,
          accountName: accountNames[project.agent.accountID]),
        live: live.filter {
          !$0.cwd.isEmpty && ProjectPath.deepest(for: $0.cwd, in: candidates) == project.id
        }.map {
          ProjectsSnapshot.LiveSession(
            id: $0.id, vendor: $0.vendor, name: $0.name, state: $0.state, cwd: $0.cwd)
        },
        lastActive: usage?.lastActive,
        windows: Self.windows(usage?.tokens ?? [:], sessions: usage?.sessions ?? [:]),
        byModel: (usage?.byModel ?? []).map {
          ProjectsSnapshot.Slice(
            key: $0.key, label: $0.key, vendor: $0.vendor.map(Self.vendorKey),
            windows: Self.windows($0.tokens, sessions: [:]))
        },
        byAccount: (usage?.byAccount ?? []).map {
          ProjectsSnapshot.Slice(
            key: $0.key,
            label: accountNames[$0.key] ?? ($0.key as NSString).abbreviatingWithTildeInPath,
            vendor: $0.vendor.map(Self.vendorKey), windows: Self.windows($0.tokens, sessions: [:]))
        })
    }

    return ProjectsSnapshot(
      takenAt: takenAt, isEntitled: isEntitled,
      index: .init(
        complete: ledger.firstPassDone, filesRead: progress?.filesDone,
        filesTotal: progress?.filesTotal,
        earliestDay: ledger.earliestDay.flatMap { LocalDay.date($0, calendar: .current) }),
      projects: rows)
  }

  private static func windows(_ tokens: [StatsWindow: TokenTally], sessions: [StatsWindow: Int])
    -> [ProjectsSnapshot.Window]
  {
    StatsWindow.allCases.map { window in
      let tally = tokens[window] ?? TokenTally()
      return ProjectsSnapshot.Window(
        key: window.rawValue,
        tokens: .init(
          fresh: tally.fresh, cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead,
          output: tally.output, reasoning: tally.reasoning),
        sessions: sessions[window] ?? 0)
    }
  }

  private static func vendorKey(_ vendor: UsageVendor) -> String {
    switch vendor {
    case .claude: "claude"
    case .codex: "codex"
    }
  }
}
