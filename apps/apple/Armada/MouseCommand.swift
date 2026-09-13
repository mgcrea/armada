import AppKit

/// The fleet actions a mouse binding can fire.
///
/// Separate from `MouseTap` because the tap is a transport: it decides that a button
/// was pressed and nothing about what the press means. This is the half that knows
/// what a session is, and it is the half that can afford to be slow — `MouseTap`
/// dispatches to it rather than calling it inline, because reaching LaunchServices
/// from inside an event-tap callback is how a tap gets itself disabled.
@MainActor
enum MouseCommand {
  /// The session the last press landed on, so a held-down thumb walks the list
  /// instead of returning to the top of it every time.
  ///
  /// A session id rather than an index: the list is rebuilt from live state on each
  /// press and a session can end, appear or move between two of them, so an index
  /// would silently come to mean a different row. An id that is no longer in the list
  /// falls through to the first entry, which is the right answer for "the session I
  /// was cycling through has finished".
  private static var cursor: String?

  static func run(_ action: MouseAction) {
    switch action {
    case .showArmada:
      AppDelegate.shared?.showMain()
    case .focusNextWaiting:
      advance(through: waiting())
    case .focusNextSession:
      advance(through: fleet())
    case .focusPreviousSession:
      advance(through: fleet().reversed())
    default:
      // The keystroke half never arrives here; `MouseTap` posts those itself.
      break
    }
  }

  /// One focusable row, flattened across the two vendors.
  ///
  /// Deliberately not a protocol over `Session` and `CodexSession`. `SessionListItem`
  /// exists for sorting and grouping and stops exactly where the vendors stop
  /// agreeing; *focusing* is where they disagree most — a Claude session has a host
  /// application to raise and a Codex session has never had one — so the shared thing
  /// here is a closure, not a shape.
  private struct Target {
    let id: String
    let activity: Date?
    let focus: @MainActor () -> Void
  }

  /// Every live session, newest activity first — the order the session list is in by
  /// default, so cycling walks the rows in the order they are on screen.
  private static func fleet() -> [Target] {
    (claudeTargets() + codexTargets())
      .sorted { ($0.activity ?? .distantPast, $0.id) > ($1.activity ?? .distantPast, $1.id) }
  }

  /// Sessions that look like they want you.
  ///
  /// **The same definition as `Accounts.blockedSessionCount`, and so the same rung as
  /// the menu bar halo's `.blocked`** — `.waiting`, which Claude Code now reports
  /// outright, plus `.runningTool`, which is inferred and over-fires. Matching the
  /// halo matters more than being stricter than it: the button people will press is
  /// the one the lit halo just prompted them to press, and a button that skipped a
  /// session the halo was lit for would read as broken.
  ///
  /// **Codex contributes nothing here, and cannot.** Its equivalent state is
  /// `awaitingInput`, which means "alive and not busy" — that is every Codex session
  /// anyone has open, so folding it in would make this command walk the whole fleet
  /// under a name that promises triage. `MenuBarHalo.waiting` documents the same
  /// limitation from the other end. Codex sessions stay reachable through
  /// `focusNextSession`.
  private static func waiting() -> [Target] {
    var rows: [(session: Session, account: Account)] = []
    for account in Accounts.shared.all {
      for session in account.sessions.sessions
      where session.state == .waiting || session.state == .runningTool {
        rows.append((session, account))
      }
    }
    // `stateRank` before recency, which is `SessionOrder`'s reading of these same two
    // states: a session stopped on a permission prompt is the one you can actually do
    // something about, so it leads every session that merely has a tool outstanding,
    // however recently that one moved.
    return
      rows
      .sorted { lhs, rhs in
        if lhs.session.stateRank != rhs.session.stateRank {
          return lhs.session.stateRank < rhs.session.stateRank
        }
        let left = lhs.session.lastActivity ?? .distantPast
        let right = rhs.session.lastActivity ?? .distantPast
        if left != right { return left > right }
        return lhs.session.id > rhs.session.id
      }
      .map { target(for: $0.session, in: $0.account) }
  }

  private static func claudeTargets() -> [Target] {
    Accounts.shared.all.flatMap { account in
      account.sessions.sessions.map { target(for: $0, in: account) }
    }
  }

  private static func codexTargets() -> [Target] {
    CodexAccounts.shared.all.flatMap { account in
      account.sessions.liveSessions.map { session in
        // No host, and never was: a Codex session's destination is Armada's own pane.
        // `CodexPane` makes the same call for the same reason.
        Target(id: session.id, activity: session.lastEventAt) {
          MainWindowRoute.shared.open(.codex(account.id), session: session.id)
        }
      }
    }
  }

  private static func target(for session: Session, in account: Account) -> Target {
    Target(id: session.id, activity: session.lastActivity) {
      // **Looked up on the press, which is the sanctioned time to do it.**
      // `SessionHostLookup` forbids this from a row body because nineteen rows
      // resolving on every redraw is fifty-seven round-trips a frame; once per
      // deliberate button press is the same cost as building a menu, and the result
      // is cached anyway.
      if let host = SessionHostLookup.host(for: session.registry) {
        FocusSession.focus(host, cwd: session.registry.cwd)
      } else {
        // A session with no host — `claude -p` in CI, over ssh, inside tmux — has
        // nothing to raise, so the window that knows about it is Armada's own.
        MainWindowRoute.shared.open(.account(account.id), session: session.id)
      }
    }
  }

  private static func advance(through targets: [Target]) {
    guard !targets.isEmpty else {
      // Nothing to go to. Silent rather than beeping: the common case is a thumb
      // reaching for the next waiting session when nothing is waiting, which is good
      // news and not worth an alert.
      return
    }
    let next: Target
    if let cursor, let index = targets.firstIndex(where: { $0.id == cursor }) {
      next = targets[(index + 1) % targets.count]
    } else {
      next = targets[0]
    }
    cursor = next.id
    next.focus()
  }
}
