import Foundation

/// The one door from a tool to bringing a session's window to the front.
///
/// **Only reachable past the kit's write gate**, like `SessionCloser`: raising a window changes
/// nothing in a session, but it takes the screen from whatever the person was doing. The tool has
/// already found the session and refused Codex; the app finds the application the session runs
/// in and raises it.
public protocol SessionFocuser: Sendable {
  func focusSession(_ request: FocusSessionRequest) async -> FocusSessionOutcome
}

public struct FocusSessionRequest: Sendable, Equatable {
  /// A Claude Code session id, exact: the tool has already resolved any prefix or name.
  public let sessionID: String

  public init(sessionID: String) {
    self.sessionID = sessionID
  }
}

public struct FocusedSession: Sendable, Equatable {
  /// How close to the session the raise got.
  public enum Reach: String, Sendable, Equatable {
    /// The session's own tab in VS Code.
    case tab
    /// The window titled with the session's folder.
    case window
    /// The application only: no window matched, or Armada has no Accessibility grant.
    case application
  }

  public let name: String
  public let project: String
  /// The application's name, "VS Code" or "Terminal".
  public let app: String
  public let reach: Reach
  /// False when Armada lacks Accessibility, which is why `reach` stopped at the application.
  public let accessibilityGranted: Bool

  public init(name: String, project: String, app: String, reach: Reach, accessibilityGranted: Bool)
  {
    self.name = name
    self.project = project
    self.app = app
    self.reach = reach
    self.accessibilityGranted = accessibilityGranted
  }
}

public enum FocusSessionOutcome: Sendable, Equatable {
  case focused(FocusedSession)
  /// A sentence for the caller, passed back word for word.
  case refused(String)
}
