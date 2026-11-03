import Foundation
import Observation

/// The token ledger as the app sees it, and when it is read.
///
/// **Behind the entitlement gate, like the watchers.** `EntitlementMonitor.apply()` starts
/// and stops it, so a locked Armada reads nothing.
///
/// **When.** The first pass waits a minute after launch, so it does not compete with the
/// watchers' own first reads. After that a pass runs every five minutes while any session is
/// working and every thirty otherwise, and a minute after a watcher reports a write. Low
/// Power Mode and a hot Mac put it off. A pass after the first reads only what changed, so
/// the steady state is a few stats and a few kilobytes.
///
/// **At background priority.** The pass runs in a detached background task, so macOS gives it
/// the efficiency cores and throttled I/O; the first one reads every transcript on the Mac.
@MainActor
@Observable
final class UsageIndex {
  static let shared = UsageIndex()

  static let fileName = "usage-index.sqlite"

  private(set) var ledger: UsageLedgerSnapshot = .empty
  /// Nil between passes.
  private(set) var progress: UsageIndexer.Progress?
  private(set) var lastPassAt: Date?
  /// What each name in the skill ledger is on disk: a skill, a command, a plugin's, or a
  /// built-in. A name missing here rolls up as a built-in.
  private(set) var skillSources: [String: SkillSource] = [:]

  @ObservationIgnored private var indexer: UsageIndexer?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var activity = false
  @ObservationIgnored private var isPassing = false
  @ObservationIgnored private var memo: Memo?
  @ObservationIgnored private var skillMemo: SkillMemo?
  /// Bumped each time `skillSources` is replaced, so `projectSkills` can memoise on it.
  /// Observed, so a view whose memo hit still redraws when classifying finishes.
  private var skillSourcesVersion = 0
  @ObservationIgnored private var classifying: Task<Void, Never>?
  /// When an archive pass last read the transcript archive through to its end.
  @ObservationIgnored private var archiveReadAt: Date?

  /// How much of the archive one pass reads before it stops starting files. The first read
  /// of a big archive over Wi-Fi spreads over several passes rather than one long one.
  static let archiveByteBudget: Int64 = 2 << 30

  /// **The archive is read at most once a day:** after the first live pass after launch,
  /// then a day after the last archive pass that reached its end. A copy only adds a use once
  /// its live original is gone, 30 days after its last write, so a day late costs nothing,
  /// and listing a NAS every few minutes would. One that was not mounted, or a pass
  /// cancelled, failed or stopped on its budget, is tried again after the next live pass.
  ///
  /// **In a pass of its own, after the live one,** so a slow share never holds up the live
  /// figures. Each pass lists only its own sources, and the indexer folds only what a listed
  /// root no longer holds, so neither folds the other's files.
  private var archiveIsDue: Bool {
    archiveReadAt.map { Date().timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
  }

  private struct Memo {
    let generation: Int
    let candidates: [ProjectPath.Candidate]
    let day: Int
    let value: [String: ProjectUsage]
  }

  private struct SkillMemo {
    let generation: Int
    let candidates: [ProjectPath.Candidate]
    let day: Int
    let sourcesVersion: Int
    let value: [SkillTally]
  }

  private init() {}

  func start() {
    guard loop == nil, let directory = AppInfo.supportDirectory else { return }
    let indexer = self.indexer ?? UsageIndexer(url: directory.appending(path: Self.fileName))
    self.indexer = indexer
    loop = Task { await run(indexer) }
  }

  /// Cancels a pass in flight. What it committed stays; the rest is read next time.
  func stop() {
    loop?.cancel()
    loop = nil
    classifying?.cancel()
    classifying = nil
    isPassing = false
    progress = nil
  }

  /// A watcher saw a transcript or rollout written. Only sets a flag, here and in the archive,
  /// which follows the same writes.
  func noteActivity() {
    activity = true
    TranscriptArchiver.shared.noteActivity()
  }

  /// Every saved project's figures, recomputed only when the ledger, the projects or the
  /// day changed. Called from view bodies.
  func projectUsage(store: ProjectStore) -> [String: ProjectUsage] {
    let candidates = store.candidates
    let now = AppClock.now
    let day = LocalDay.key(now, calendar: .current)
    if let memo, memo.generation == ledger.generation, memo.day == day,
      memo.candidates == candidates
    {
      return memo.value
    }
    let value = ProjectStats.compute(
      projects: candidates, ledger: ledger, today: now, calendar: .current)
    memo = Memo(generation: ledger.generation, candidates: candidates, day: day, value: value)
    return value
  }

  /// Every skill tally, per project, account and window, recomputed only when the ledger,
  /// the projects, the day or what each name is changed. Called from view bodies.
  func projectSkills(store: ProjectStore) -> [SkillTally] {
    let candidates = store.candidates
    let now = AppClock.now
    let day = LocalDay.key(now, calendar: .current)
    if let skillMemo, skillMemo.generation == ledger.generation, skillMemo.day == day,
      skillMemo.sourcesVersion == skillSourcesVersion, skillMemo.candidates == candidates
    {
      return skillMemo.value
    }
    let value = SkillStats.compute(
      ledger.skills, projects: candidates, sources: skillSources, today: now,
      calendar: .current)
    skillMemo = SkillMemo(
      generation: ledger.generation, candidates: candidates, day: day,
      sourcesVersion: skillSourcesVersion, value: value)
    return value
  }

  /// The Skills pane's recent uses, read off the main actor. 20 at most.
  ///
  /// **Beside the indexer, never through it**: a pass holds that actor for as long as it
  /// runs, so this opens a read-only connection of its own (`UsageIndexer.recentSkillUses`).
  /// Empty before the ledger exists, and reading never creates it.
  func recentSkillUses(skill: String, window: StatsWindow) async -> [SkillUseRecord] {
    guard let directory = AppInfo.supportDirectory else { return [] }
    let url = directory.appending(path: Self.fileName)
    let sinceDay = window.floor(today: AppClock.now, calendar: .current)
    return await Task.detached(priority: .userInitiated) {
      UsageIndexer.recentSkillUses(at: url, skill: skill, sinceDay: sinceDay, limit: 20)
    }.value
  }

  // MARK: - The loop

  private func run(_ indexer: UsageIndexer) async {
    if let saved = await indexer.loadSnapshot() { receive(saved) }
    try? await Task.sleep(for: .seconds(60))
    while !Task.isCancelled {
      if !Self.shouldDefer { await pass(indexer) }
      await idle()
    }
  }

  private func pass(_ indexer: UsageIndexer) async {
    activity = false
    isPassing = true
    let sources =
      Accounts.shared.all.map {
        UsageIndexer.Source(account: $0.id, vendor: .claude, root: $0.folder.projectsDir)
      }
      + CodexAccounts.shared.all.map {
        UsageIndexer.Source(account: $0.id, vendor: .codex, root: $0.home.base)
      }
    // Stored values only: whatever touches the archive's disk runs in its own task below.
    let archive = archiveIsDue ? TranscriptArchiver.shared.skillTarget : nil
    let calendar = Calendar.current
    let live = Task.detached(priority: .background) {
      await indexer.runPass(
        sources: sources, calendar: calendar,
        progress: { progress in Task { @MainActor in UsageIndex.shared.receive(progress) } },
        publish: { snapshot in Task { @MainActor in UsageIndex.shared.receive(snapshot) } })
    }
    let result = await withTaskCancellationHandler {
      await live.value
    } onCancel: {
      live.cancel()
    }
    if let result { receive(result.snapshot) }
    // The progress shown is the live pass's alone: the archive pass reports none, and a
    // report of this one that lands late is dropped.
    isPassing = false
    progress = nil
    lastPassAt = Date()

    guard let archive, result != nil, !Task.isCancelled else { return }
    let budget = Self.archiveByteBudget
    let archived = Task.detached(priority: .background) { () -> UsageIndexer.PassResult? in
      // The archive's copies, for skill uses older than the transcripts on this Mac.
      let sources = TranscriptArchive.skillSources(target: archive.target, volume: archive.volume)
      guard !sources.isEmpty else { return nil }
      return await indexer.runPass(
        sources: sources, calendar: calendar, byteBudget: budget, progress: { _ in },
        publish: { snapshot in Task { @MainActor in UsageIndex.shared.receive(snapshot) } })
    }
    let archiveResult = await withTaskCancellationHandler {
      await archived.value
    } onCancel: {
      archived.cancel()
    }
    if let archiveResult {
      receive(archiveResult.snapshot)
      if archiveResult.reachedEnd { archiveReadAt = Date() }
    }
  }

  /// Hops arrive in no particular order, so a progress report that lands after the pass
  /// ended is dropped, and so is a snapshot older than the one already shown.
  private func receive(_ report: UsageIndexer.Progress) {
    guard isPassing else { return }
    progress = report
  }

  private func receive(_ snapshot: UsageLedgerSnapshot) {
    guard snapshot.generation > ledger.generation else { return }
    ledger = snapshot
    classify(snapshot)
  }

  /// Settles what each name in a new ledger is, off the main actor: names only ever typed
  /// are looked for on disk. The config folders are read here, before the hop.
  ///
  /// **The newest ledger wins.** A result lands only while its ledger is still the one
  /// shown, so a slow classify of an older ledger never overwrites a newer one's.
  private func classify(_ snapshot: UsageLedgerSnapshot) {
    let rows = snapshot.skills
    let generation = snapshot.generation
    let configs = Accounts.shared.all.map(\.folder.base)
    let home = NSHomeDirectory()
    classifying?.cancel()
    classifying = Task.detached(priority: .background) { [weak self] in
      let sources = SkillCatalog.classify(rows, configs: configs, home: home)
      guard !Task.isCancelled else { return }
      await self?.install(sources, generation: generation)
    }
  }

  private func install(_ sources: [String: SkillSource], generation: Int) {
    guard generation == ledger.generation else { return }
    skillSources = sources
    skillSourcesVersion += 1
  }

  private func idle() async {
    let busy = Accounts.shared.workingSessionCount + CodexAccounts.shared.workingCount > 0
    let interval: TimeInterval = busy ? 5 * 60 : 30 * 60
    let started = Date()
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(15))
      let waited = Date().timeIntervalSince(started)
      if waited >= interval || (activity && waited >= 60) { return }
    }
  }

  private static var shouldDefer: Bool {
    let info = ProcessInfo.processInfo
    return info.isLowPowerModeEnabled || info.thermalState == .serious
      || info.thermalState == .critical
  }
}

#if DEBUG
  extension UsageIndex {
    /// A capture's ledger. The indexer is never started, so no SQLite file is
    /// opened. See `DemoSeed`.
    func demoInstall(_ ledger: UsageLedgerSnapshot) { self.ledger = ledger }
  }
#endif
