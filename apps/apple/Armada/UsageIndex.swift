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

  @ObservationIgnored private var indexer: UsageIndexer?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var activity = false
  @ObservationIgnored private var isPassing = false
  @ObservationIgnored private var memo: Memo?
  /// When a pass last read the transcript archive through to its end.
  @ObservationIgnored private var archiveReadAt: Date?

  /// **The archive joins a pass at most once a day:** the first after launch, then the first
  /// a day after the last that read it. A copy only adds a use once its live original is
  /// gone, 30 days after its last write, so a day late costs nothing, and listing a NAS every
  /// few minutes would. One that was not mounted, or a pass cancelled or failed, is tried
  /// again next pass.
  ///
  /// **A pass without it folds none of its files.** The archive's sources are not in the
  /// pass, so their listing is never in `listed`, and the indexer folds only what a listed
  /// root no longer holds.
  private var archiveIsDue: Bool {
    archiveReadAt.map { Date().timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
  }

  private struct Memo {
    let generation: Int
    let candidates: [ProjectPath.Candidate]
    let day: Int
    let value: [String: ProjectUsage]
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

  // MARK: - The loop

  private func run(_ indexer: UsageIndexer) async {
    if let saved = await indexer.loadSnapshot() { ledger = saved }
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
    // Stored values only: whatever touches the archive's disk runs in the task below.
    let archive = archiveIsDue ? TranscriptArchiver.shared.skillTarget : nil
    let calendar = Calendar.current
    let work = Task.detached(priority: .background) {
      // The archive's copies, for skill uses older than the transcripts on this Mac.
      let archived =
        archive.map {
          TranscriptArchive.skillSources(target: $0.target, volume: $0.volume)
        } ?? []
      let snapshot = await indexer.runPass(
        sources: sources + archived, calendar: calendar,
        progress: { progress in Task { @MainActor in UsageIndex.shared.receive(progress) } },
        publish: { snapshot in Task { @MainActor in UsageIndex.shared.receive(snapshot) } })
      let readArchive = snapshot != nil && !archived.isEmpty && !Task.isCancelled
      return (snapshot: snapshot, readArchive: readArchive)
    }
    let (snapshot, readArchive) = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    if readArchive { archiveReadAt = Date() }
    if let snapshot { receive(snapshot) }
    isPassing = false
    progress = nil
    lastPassAt = Date()
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
