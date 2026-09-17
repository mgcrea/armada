import ArmadaMCP
import Darwin
import Foundation

/// `armada_close_session`'s door into the app: one main-actor hop that finds the session and
/// checks it again, then the signal, sent and watched off the main actor.
///
/// **What closing is.** `SIGTERM` to the session's own `claude`, which is what quitting does.
/// Measured 2026-09-16 on 2.1.273 in a pty, idle and with a `!sleep` running: the registry file
/// went at 0.3s, the process exited 143 at 0.7–0.8s, and its eleven MCP server children and the
/// running command went with it. `SIGKILL` follows only a process still there after
/// `killGrace`, and takes no children down, which is why it is the fallback and not the method.
///
/// **Checks again what the tool already checked.** The snapshot the tool read can be seconds old:
/// an idle session may have started a turn since, or ended.
///
/// **Never signals a pid it cannot tie to the session.** A crashed session leaves its registry
/// file behind and pids wrap, so the registry's `startedAt` must agree with the kernel's start
/// time for that pid — the check `SessionHostLookup` makes before raising a window, made strict
/// here: a registry with no `startedAt` is refused rather than trusted, because the cost of being
/// wrong is ending a stranger's process rather than raising the wrong app.
///
/// **Throttled.** One close per `throttle` seconds, so a supervisor caught in a loop closes one
/// session and is told to wait rather than emptying the fleet.
nonisolated struct SessionCloserBridge: SessionCloser {
  static let throttle: TimeInterval = 5
  /// Ten times the measured exit, for a session tearing down many MCP servers on a busy Mac.
  static let killGrace: TimeInterval = 8
  /// How long a killed process has to be reaped before the answer says it has not exited.
  static let reapGrace: TimeInterval = 2
  /// The registry's `startedAt` and the kernel's agree to the second (see `ProcessAncestry`).
  static let startTolerance: TimeInterval = 5

  @MainActor private static var lastCloseAt: Date?

  struct Target: Sendable {
    let pid: pid_t
    let startedAt: Date
    let name: String
    let project: String
    let state: String
  }

  enum Preparation {
    case ready(Target)
    case refused(String)
  }

  func closeSession(_ request: CloseSessionRequest) async -> CloseSessionOutcome {
    switch await MainActor.run(body: { Self.prepare(request, now: Date()) }) {
    case .refused(let message): return .refused(message)
    case .ready(let target): return await Self.terminate(target)
    }
  }

  @MainActor
  static func prepare(_ request: CloseSessionRequest, now: Date) -> Preparation {
    guard EntitlementMonitor.shared.current.isEntitled else {
      return .refused("Armada has no licence and no trial running, so it closes nothing.")
    }
    guard
      let session = Accounts.shared.all.lazy.compactMap({ account in
        account.sessions.sessions.first { $0.id == request.sessionID }
      }).first
    else {
      return .refused("That session has already ended, or Armada no longer sees it.")
    }

    let name = session.displayName
    let state = session.state
    if !request.force, state == .working || state == .runningTool {
      let doing = state == .runningTool ? "probably running a tool" : "working"
      return .refused(
        "\(name) is \(doing) now, so closing it would stop that work mid-turn. Ask the person, "
          + "then pass `force: true` to close it anyway.")
    }

    let pid = session.registry.pid
    guard pid > 1, pid != getpid(),
      let claimed = session.registry.startedAtDate,
      let actual = ProcessAncestry.startTime(of: pid),
      abs(actual.timeIntervalSince(claimed)) < startTolerance
    else {
      return .refused(
        "Armada cannot confirm that process \(pid) is still \(name), so it sends it nothing.")
    }

    if let last = lastCloseAt, now.timeIntervalSince(last) < throttle {
      return .refused(
        "An agent closed a session \(Int(now.timeIntervalSince(last))) seconds ago. Wait a "
          + "moment before closing another.")
    }
    lastCloseAt = now

    return .ready(
      Target(
        pid: pid, startedAt: actual, name: name, project: session.registry.projectName,
        state: state.rawValue))
  }

  /// `SIGTERM`, a wait, and `SIGKILL` for a process that outlived it.
  ///
  /// Every signal after the first goes only to a pid whose start time still matches, so a
  /// session that exited during the wait cannot hand its pid to something that then gets killed.
  static func terminate(_ target: Target) async -> CloseSessionOutcome {
    guard kill(target.pid, SIGTERM) == 0 else {
      if errno == ESRCH { return closed(target, killed: false, exited: true) }
      return .refused("macOS refused to signal \(target.name)'s process (errno \(errno)).")
    }
    if await exits(target, within: killGrace) {
      return closed(target, killed: false, exited: true)
    }
    guard isSame(target) else { return closed(target, killed: false, exited: true) }
    kill(target.pid, SIGKILL)
    return closed(target, killed: true, exited: await exits(target, within: reapGrace))
  }

  private static func exits(_ target: Target, within seconds: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if !isSame(target) { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return !isSame(target)
  }

  /// The pid is running and is still the process that was signalled.
  ///
  /// **A zombie counts as gone.** An exited `claude` stays in the process table until its
  /// parent, the terminal's shell or VS Code's extension host, reaps it, and `sysctl` still
  /// answers for it with its start time. Without the `SZOMB` check a session that quit at once
  /// would be waited on for the whole grace, then killed, and reported as having ignored the
  /// request.
  private static func isSame(_ target: Target) -> Bool {
    guard let info = ProcessAncestry.info(of: target.pid),
      Int32(info.kp_proc.p_stat) != SZOMB
    else { return false }
    let started = info.kp_proc.p_un.__p_starttime
    let start = Date(
      timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    return abs(start.timeIntervalSince(target.startedAt)) < 1
  }

  private static func closed(_ target: Target, killed: Bool, exited: Bool) -> CloseSessionOutcome {
    .closed(
      ClosedSession(
        name: target.name, project: target.project, state: target.state, killed: killed,
        exited: exited))
  }
}
