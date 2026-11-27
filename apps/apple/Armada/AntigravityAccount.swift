import Foundation

/// The Antigravity CLI home, and everything Armada knows about it.
///
/// Its quotas come from `AntigravityControl`, which asks the person's own `agy` via `--settings`
/// and its `statusLine` payload, since `agy` writes no plan limits to disk. Its encrypted files
/// and credentials are never opened.
@MainActor
@Observable
final class AntigravityAccount: Identifiable {
  let home: AntigravityHome
  let sessions: AntigravityWatcher

  var id: String { home.id }

  init(home: AntigravityHome) {
    self.home = home
    sessions = AntigravityWatcher(home: home)
  }

  func start() { sessions.start() }

  /// Nil until the first probe answers, and kept when a later one fails.
  private(set) var usage: AntigravityFiles.Limits?

  /// `"Google AI Pro"`, `"Google AI Ultra"`: the tier `agy`'s `statusLine` payload names.
  var planLabel: String? { usage?.tier }

  /// Off the main actor, cancellable before the process starts. See `GrokAccount.probeUsage`.
  func probeUsage() async {
    // Spawns `agy`, which talks to the network as whoever is signed in. The menu bar
    // panel asks for a probe on every appearance, so a capture would otherwise run it.
    guard !ScreenshotMode.isEnabled else { return }
    guard let limits = await Self.probe(), !Task.isCancelled else { return }
    usage = limits
    UsageHistory.shared.record(limits.asSnapshot, for: home.id)
  }

  @concurrent
  private nonisolated static func probe() async -> AntigravityFiles.Limits? {
    await AntigravityControl.limits()
  }

  var displayName: String { home.displayName }
  var displayPath: String { home.displayPath }

  /// The folders `agy` ran in lately, for New Session menus. See `CodexAccount.recentProjects`.
  var recentProjects: [RecentProject] { RecentProject.recent(in: sessions.sessions) }
}

/// The Antigravity CLI home on this Mac, if there is one. A singleton of its own, for
/// `CodexAccounts`' reasons. Zero or one account: `agy` has one home and no variable to move it.
@MainActor
@Observable
final class AntigravityAccounts {
  static let shared = AntigravityAccounts()

  private(set) var all: [AntigravityAccount] = []

  /// True when this Mac has no Antigravity CLI home, so the UI leaves Antigravity out.
  var isEmpty: Bool { all.isEmpty }

  func account(id: String) -> AntigravityAccount? { all.first { $0.id == id } }

  private var isStarted = false

  /// Matches `Accounts.probeInterval` and `GrokAccounts.probeInterval`.
  static let probeInterval: TimeInterval = 3 * 60
  static let probeThrottle: TimeInterval = 20

  private var probeTimer: DispatchSourceTimer?
  private var lastProbe: [String: Date] = [:]
  private var probes: [String: Task<Void, Never>] = [:]

  func start() {
    guard !isStarted else { return }
    isStarted = true
    all = AntigravityHome.discover().map { [AntigravityAccount(home: $0)] } ?? []
    for account in all { account.start() }
    startProbing()
  }

  /// Pick up the home once `agy` has written its first conversation, which may be after
  /// `start()`. Additions only, for `Accounts.rediscover()`'s reasons; nothing while stopped.
  /// Called from `Accounts`' tick, beside Grok's.
  func rediscover() {
    guard isStarted, all.isEmpty, let home = AntigravityHome.discover() else { return }
    let account = AntigravityAccount(home: home)
    account.start()
    all = [account]
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

  /// Ask the Antigravity home for its quotas, throttled per home.
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

#if DEBUG
  extension AntigravityAccount {
    /// A capture's quotas, never probed. See `DemoSeed`.
    func demoInstall(_ usage: AntigravityFiles.Limits) { self.usage = usage }
  }

  extension AntigravityAccounts {
    /// A capture's Antigravity home. `start()` is never called, so no probe timer exists.
    /// See `DemoSeed`.
    func demoInstall(_ accounts: [AntigravityAccount]) { all = accounts }
  }
#endif
