import Foundation

/// One Grok Build home, and everything Armada knows about it.
///
/// Thinner than `CodexAccount`: Grok reports no plan limits anywhere on disk, and its identity
/// lives only in `auth.json`, which Armada does not open. The row is labelled by its folder.
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

  var displayName: String { home.displayName }
  var displayPath: String { home.displayPath }
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

  func start() {
    guard !isStarted else { return }
    isStarted = true
    all = GrokHome.discoverAll().map(GrokAccount.init(home:))
    for account in all { account.start() }
  }

  func stop() {
    for account in all { account.sessions.stop() }
    all = []
    isStarted = false
  }

  var workingCount: Int { all.reduce(0) { $0 + $1.sessions.workingCount } }
  var liveCount: Int { all.reduce(0) { $0 + $1.sessions.liveSessions.count } }
}
