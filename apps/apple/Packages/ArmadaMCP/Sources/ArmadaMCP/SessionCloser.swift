import Foundation

/// The one door from a tool to ending a session. `FleetSource` only reads.
///
/// **Only reachable past the kit's write gate**, like `SessionStarter`. The tool has already
/// found the session, refused Codex and refused a busy session without `force` by the time a
/// request arrives; the app checks the session and its state again, because the snapshot can be
/// seconds old and this is the side that sends the signal.
public protocol SessionCloser: Sendable {
  func closeSession(_ request: CloseSessionRequest) async -> CloseSessionOutcome
}

public struct CloseSessionRequest: Sendable, Equatable {
  /// A Claude Code session id, exact: the tool has already resolved any prefix or name.
  public let sessionID: String
  /// Close it even while it is working or probably running a tool.
  public let force: Bool

  public init(sessionID: String, force: Bool) {
    self.sessionID = sessionID
    self.force = force
  }
}

public struct ClosedSession: Sendable, Equatable {
  public let name: String
  public let project: String
  /// `SessionState.rawValue` when the signal went.
  public let state: String
  /// The process ignored `SIGTERM` for the grace period and was killed.
  public let killed: Bool
  /// The process was gone when the bridge stopped watching. False only for one that survived
  /// even `SIGKILL`'s wait, which a session in uninterruptible I/O can.
  public let exited: Bool

  public init(name: String, project: String, state: String, killed: Bool, exited: Bool) {
    self.name = name
    self.project = project
    self.state = state
    self.killed = killed
    self.exited = exited
  }
}

public enum CloseSessionOutcome: Sendable, Equatable {
  case closed(ClosedSession)
  /// A sentence for the caller, passed back word for word.
  case refused(String)
}
