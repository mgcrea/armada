import Foundation

/// Who asked for a session to be closed.
nonisolated enum CloseOrigin: Sendable, Equatable {
  /// A tool call, through `armada_close_session`.
  case agent
  /// A click in Armada.
  case person
}

/// What differs between the two, kept apart from `SessionCloserBridge` so it can be checked
/// without the app.
///
/// **The throttle is an agent's alone.** It exists so a supervisor caught in a loop closes one
/// session rather than the fleet. A person clearing three idle rows is not a loop, and being
/// told to wait five seconds between them would read as a broken button. Their close does not
/// arm it either: a click must not be what refuses an agent's next call.
///
/// Everything that protects the process being signalled is the same for both, and stays in the
/// bridge: the pid is tied to the session by its start time whoever asked.
nonisolated enum SessionClosePolicy {
  /// How long ago the last agent close was, when that is too recent for `origin` to close
  /// another. Nil when the close may go.
  static func recentClose(
    for origin: CloseOrigin, last: Date?, now: Date, throttle: TimeInterval
  ) -> TimeInterval? {
    guard origin == .agent, let last else { return nil }
    let elapsed = now.timeIntervalSince(last)
    return elapsed < throttle ? elapsed : nil
  }

  static func armsThrottle(_ origin: CloseOrigin) -> Bool { origin == .agent }
}
