import AppKit
import ArmadaMCP
import Foundation

/// `armada_focus_session`'s door into the app: the Focus action a session row has, reached by an
/// agent.
///
/// **The same `FocusSession.focus` the rows use**, so a window an agent raises is the one a click
/// would have: the window titled with the session's folder, then the session's own tab in VS Code
/// when `ExtensionTab` allows asking for it.
///
/// **Armada is usually not frontmost when this runs, and that changes activation.** Focus from a
/// row works because Armada's popover or window is active and can yield to the host. A call from
/// voice arrives while the person is in some other app, with only the non-activating voice card
/// showing, so the yield gives nothing away and the system may decline the activation. The raise
/// still lands inside the host, behind whatever is in front. So this watches for the host to
/// become frontmost and, when it has not, asks LaunchServices, which activates regardless, then
/// raises the matched window again because LaunchServices brings the host's last window instead.
///
/// **Throttled.** One focus per `throttle` seconds, so an agent caught in a loop cannot keep taking
/// the screen from the person.
nonisolated struct SessionFocuserBridge: SessionFocuser {
  static let throttle: TimeInterval = 2
  /// Half a second, in 50ms steps, for an activation to land before falling back.
  static let activationChecks = 10

  @MainActor private static var lastFocusAt: Date?

  struct Target: Sendable {
    let sessionID: String
    let host: SessionHost
    let cwd: String
    let labels: [String]?
    let name: String
    let project: String
  }

  enum Preparation {
    case ready(Target)
    case refused(String)
  }

  func focusSession(_ request: FocusSessionRequest) async -> FocusSessionOutcome {
    let target: Target
    switch await MainActor.run(body: { Self.prepare(request, now: Date()) }) {
    case .refused(let message): return .refused(message)
    case .ready(let ready): target = ready
    }

    // Off the main actor, as `FocusSession.resolve` does: a wedged host answers each
    // Accessibility message only when its timeout runs out.
    let reach = FocusSession.reach(
      inApplication: target.host.pid, cwd: target.cwd, labels: target.labels)
    let granted = HostWindow.isTrusted

    await MainActor.run {
      let session = Self.session(target.sessionID)
      FocusSession.focus(target.host, cwd: target.cwd, session: session)
    }
    if !(await Self.becomesFrontmost(target.host.pid)) {
      await MainActor.run {
        FocusSession.reopen(target.host)
        HostWindow.raise(inApplication: target.host.pid, cwd: target.cwd)
      }
    }

    return .focused(
      FocusedSession(
        name: target.name, project: target.project, app: target.host.name,
        reach: Self.reach(reach), accessibilityGranted: granted))
  }

  @MainActor
  static func prepare(_ request: FocusSessionRequest, now: Date) -> Preparation {
    guard EntitlementMonitor.shared.current.isEntitled else {
      return .refused("Armada has no licence and no trial running, so it brings nothing forward.")
    }
    guard let session = session(request.sessionID) else {
      return .refused("That session has already ended, or Armada no longer sees it.")
    }
    let name = session.displayName
    guard let host = SessionHostLookup.host(for: session.registry) else {
      return .refused(
        "\(name) has no app window to bring forward: it runs inside tmux, over ssh or headless.")
    }

    if let last = lastFocusAt, now.timeIntervalSince(last) < throttle {
      return .refused("A session was brought forward a moment ago. Wait a moment and ask again.")
    }
    lastFocusAt = now

    return .ready(
      Target(
        sessionID: session.id, host: host, cwd: session.registry.cwd,
        labels: ExtensionTab(session, host: host)?.labels, name: name,
        project: session.registry.projectName))
  }

  @MainActor
  private static func session(_ id: String) -> Session? {
    Accounts.shared.all.lazy.compactMap { account in
      account.sessions.sessions.first { $0.id == id }
    }.first
  }

  private static func becomesFrontmost(_ pid: pid_t) async -> Bool {
    for _ in 0..<activationChecks {
      if await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
        == pid
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  private static func reach(_ reach: FocusReach) -> FocusedSession.Reach {
    switch reach {
    case .tab: .tab
    case .window: .window
    case .application: .application
    }
  }
}
