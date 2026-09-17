import Foundation

/// One Grok Build home, and everything Armada knows about it.
///
/// Its limits come from `GrokControl`, which asks the person's own `grok`, since Grok writes them
/// nowhere on disk. Its identity lives only in `auth.json`, which Armada does not open, so the
/// row is labelled by its folder and its plan.
@MainActor
@Observable
final class GrokAccount: Identifiable {
  let home: GrokHome
  let sessions: GrokWatcher

  var id: String { home.id }

  init(home: GrokHome) {
    self.home = home
    sessions = GrokWatcher(home: home)
  }

  func start() { sessions.start() }

  /// Nil until the first probe answers, and kept when a later one fails.
  private(set) var usage: GrokFiles.Limits?

  /// "X Premium", "SuperGrok": the tier the billing answer names.
  var planLabel: String? { usage?.tier }

  /// Off the main actor, cancellable before the process starts. See `Account.probeUsage`.
  func probeUsage() async {
    guard let limits = await Self.probe(home), !Task.isCancelled else { return }
    usage = limits
    UsageHistory.shared.record(limits.asSnapshot, for: home.id)
  }

  @concurrent
  private nonisolated static func probe(_ home: GrokHome) async -> GrokFiles.Limits? {
    GrokControl.limits(home: home)
  }

  var displayName: String { home.displayName }
  var displayPath: String { home.displayPath }

  /// The folders this home ran in lately, for New Session menus. See `CodexAccount.recentProjects`.
  var recentProjects: [RecentProject] { RecentProject.recent(in: sessions.sessions) }
}

/// Every Grok Build home on this Mac. A singleton of its own, for `CodexAccounts`' reasons.
@MainActor
@Observable
final class GrokAccounts {
  static let shared = GrokAccounts()

  private(set) var all: [GrokAccount] = []

  /// True when this Mac has no Grok Build home, so the UI leaves Grok out entirely.
  var isEmpty: Bool { all.isEmpty }

  func account(id: String) -> GrokAccount? { all.first { $0.id == id } }

  private var isStarted = false

  /// `Accounts.probeInterval`'s cadence. A weekly window moves a point in well over an hour, so
  /// this is generous; the popover opening asks as well.
  static let probeInterval: TimeInterval = 3 * 60
  static let probeThrottle: TimeInterval = 20

  private var probeTimer: DispatchSourceTimer?
  private var lastProbe: [String: Date] = [:]
  private var probes: [String: Task<Void, Never>] = [:]

  func start() {
    guard !isStarted else { return }
    isStarted = true
    all = GrokHome.discoverAll().map(GrokAccount.init(home:))
    for account in all { account.start() }
    startProbing()
  }

  /// Pick up a home added since `start()`. Additions only, for `Accounts.rediscover()`'s
  /// reasons; nothing while stopped. The probe clock starts here when the first home arrives,
  /// since `start()` leaves it off on a Mac that had none.
  func rediscover() {
    guard isStarted else { return }
    let known = Set(all.map(\.id))
    let added = GrokHome.discoverAll().filter { !known.contains($0.id) }
    guard !added.isEmpty else { return }
    let accounts = added.map(GrokAccount.init(home:))
    for account in accounts { account.start() }
    all += accounts
    probeAll()
    startProbing()
  }

  private func startProbing() {
    guard !all.isEmpty, probeTimer == nil else { return }
    probeAll()
    let probe = DispatchSource.makeTimerSource(queue: .main)
    probe.schedule(deadline: .now() + Self.probeInterval, repeating: Self.probeInterval)
    probe.setEventHandler { MainActor.assumeIsolated { self.probeAll() } }
    probe.resume()
    probeTimer = probe
  }

  func stop() {
    probeTimer?.cancel()
    probeTimer = nil
    for task in probes.values { task.cancel() }
    probes = [:]
    lastProbe = [:]
    for account in all { account.sessions.stop() }
    all = []
    isStarted = false
  }

  /// Ask every home for its allowance, throttled per home.
  func probeAll() {
    let now = Date()
    for account in all
    where now.timeIntervalSince(lastProbe[account.id] ?? .distantPast) >= Self.probeThrottle {
      lastProbe[account.id] = now
      probes[account.id] = Task { await account.probeUsage() }
    }
  }

  var workingCount: Int { all.reduce(0) { $0 + $1.sessions.workingCount } }
  var awaitingInputCount: Int { all.reduce(0) { $0 + $1.sessions.awaitingInputCount } }
  var liveCount: Int { all.reduce(0) { $0 + $1.sessions.liveSessions.count } }
}
