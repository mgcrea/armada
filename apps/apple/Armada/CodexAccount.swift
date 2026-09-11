import Foundation

/// One Codex home, and everything Armada knows about it.
///
/// The counterpart to `Account`, and thinner than it, because Codex hands over
/// less. There is no `oauthAccount` to read — the only identity Armada can have
/// without opening `auth.json` is the `plan_type` that rides along with the rate
/// limits, so a Codex row is labelled by its folder and its plan rather than by an
/// organization.
@MainActor
@Observable
final class CodexAccount: Identifiable {
  let home: CodexHome
  let sessions: CodexWatcher

  var id: String { home.id }

  init(home: CodexHome) {
    self.home = home
    sessions = CodexWatcher(home: home)
  }

  func start() { sessions.start() }

  var displayName: String { home.displayName }
  var displayPath: String { home.displayPath }

  /// The plan limits, which for Codex arrive inside a session log rather than from
  /// a file of their own. Nil until a scan has read a `token_count` event.
  var usage: CodexRateLimits? { sessions.rateLimits }

  /// "Plus", "Pro" — nil until the first `token_count` is read.
  var planLabel: String? { usage?.planLabel }
}

/// Every Codex home on this Mac.
///
/// A separate singleton from `Accounts` rather than a second array inside it.
/// The two vendors share no data, no refresh cadence and no file layout, and the
/// only thing the app wants across both is "is anything working", which is one
/// computed property rather than a reason to merge them.
@MainActor
@Observable
final class CodexAccounts {
  static let shared = CodexAccounts()

  private(set) var all: [CodexAccount] = []

  /// True when this Mac has no Codex home at all, so the UI can leave Codex out
  /// entirely rather than showing an empty section to someone who does not use it.
  var isEmpty: Bool { all.isEmpty }

  func account(id: String) -> CodexAccount? { all.first { $0.id == id } }

  func start() {
    guard all.isEmpty else { return }
    all = CodexHome.discoverAll().map(CodexAccount.init(home:))
    for account in all { account.start() }
  }

  var allSessions: [CodexSession] {
    all.flatMap(\.sessions.sessions)
      .sorted {
        ($0.lastEventAt ?? .distantPast, $0.id) > ($1.lastEventAt ?? .distantPast, $1.id)
      }
  }

  /// Rescan every home now — the Codex half of what the popover asks for when it
  /// opens. The watchers coalesce, so a scan arriving mid-scan costs a flag.
  func refreshAll() {
    for account in all { account.sessions.scheduleScan() }
  }

  var workingCount: Int { all.reduce(0) { $0 + $1.sessions.workingCount } }
  var liveCount: Int { all.reduce(0) { $0 + $1.sessions.liveSessions.count } }
}
