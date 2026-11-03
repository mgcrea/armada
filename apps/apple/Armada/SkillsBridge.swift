import ArmadaMCP
import Foundation

/// `armada_get_skill_usage`'s hop: the skill ledger, the saved projects and what each name is.
///
/// **The same rule as `projects()`**: one main-actor hop that copies values the app already
/// holds and does no I/O, then the roll-up after it. What each name is was settled by the
/// usage index when the ledger last changed, so nothing here touches the disk.
nonisolated extension FleetBridge {
  func skills() async -> SkillsSnapshot {
    let captured = await MainActor.run { SkillsCapture.take(now: Date()) }
    return captured.snapshot()
  }
}

/// What the hop copies.
nonisolated struct SkillsCapture: Sendable {
  let takenAt: Date
  let isEntitled: Bool
  let projects: [Project]
  let candidates: [ProjectPath.Candidate]
  let ledger: UsageLedgerSnapshot
  let progress: UsageIndexer.Progress?
  /// Claude Code accounts only: Codex records no skill use.
  let accounts: [SkillsSnapshot.AccountRef]
  let sources: [String: SkillSource]

  @MainActor
  static func take(now: Date) -> SkillsCapture {
    SkillsCapture(
      takenAt: now, isEntitled: EntitlementMonitor.shared.current.isEntitled,
      projects: ProjectStore.shared.projects, candidates: ProjectStore.shared.candidates,
      ledger: UsageIndex.shared.ledger, progress: UsageIndex.shared.progress,
      accounts: Accounts.shared.all.map { .init(id: $0.id, name: $0.displayName) },
      sources: UsageIndex.shared.skillSources)
  }

  func snapshot() -> SkillsSnapshot {
    let tallies = SkillStats.compute(
      ledger.skills, projects: candidates, sources: sources, today: takenAt, calendar: .current)

    // An account whose folder is gone still has its uses, under the path it had.
    var accounts = accounts
    var known = Set(accounts.map(\.id))
    for tally in tallies where known.insert(tally.account).inserted {
      accounts.append(
        .init(id: tally.account, name: (tally.account as NSString).abbreviatingWithTildeInPath))
    }

    return SkillsSnapshot(
      takenAt: takenAt, isEntitled: isEntitled,
      index: .init(
        complete: ledger.firstPassDone && ledger.skillsPassDone,
        filesRead: progress?.filesDone, filesTotal: progress?.filesTotal,
        earliestDay: ledger.earliestSkillDay.flatMap { LocalDay.date($0, calendar: .current) }),
      projects: projects.map { .init(id: $0.id, name: $0.displayName, path: $0.path) },
      accounts: accounts,
      tallies: tallies.map {
        .init(
          projectID: $0.projectID, accountID: $0.account, skill: $0.skill,
          source: $0.source.rawValue, window: $0.window.rawValue, auto: $0.auto,
          slash: $0.slash, lastUsed: $0.lastAt)
      })
  }
}
