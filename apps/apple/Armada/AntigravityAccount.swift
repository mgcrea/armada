import Foundation

/// The Antigravity CLI home, and everything Armada knows about it.
///
/// No usage and no probe: `agy` writes no plan limits to disk, and its identity sits in the
/// files Armada does not open, so the row is labelled by its folder.
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

  func start() {
    guard !isStarted else { return }
    isStarted = true
    all = AntigravityHome.discover().map { [AntigravityAccount(home: $0)] } ?? []
    for account in all { account.sessions.start() }
  }

  /// Pick up the home once `agy` has written its first conversation, which may be after
  /// `start()`. Additions only, for `Accounts.rediscover()`'s reasons; nothing while stopped.
  /// Called from `Accounts`' tick, beside Grok's.
  func rediscover() {
    guard isStarted, all.isEmpty, let home = AntigravityHome.discover() else { return }
    let account = AntigravityAccount(home: home)
    account.sessions.start()
    all = [account]
  }

  func stop() {
    for account in all { account.sessions.stop() }
    all = []
    isStarted = false
  }

  var workingCount: Int { all.reduce(0) { $0 + $1.sessions.workingCount } }
  var awaitingInputCount: Int { all.reduce(0) { $0 + $1.sessions.awaitingInputCount } }
  var liveCount: Int { all.reduce(0) { $0 + $1.sessions.liveSessions.count } }
}

#if DEBUG
  extension AntigravityAccounts {
    /// A capture's Antigravity home. `start()` is never called. See `DemoSeed`.
    func demoInstall(_ accounts: [AntigravityAccount]) { all = accounts }
  }
#endif
