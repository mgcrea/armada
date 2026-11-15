import Foundation

/// The one door from a tool to putting text in front of a running session.
///
/// **Only reachable past the kit's write gate**, like `SessionStarter` and `SessionCloser`, and
/// in the app only while Settings ▸ Supervisor delivers messages, which installs the hook that
/// picks them up in Claude Code. The tool has already found the session, refused a Grok Build TUI
/// session or one mid-turn and a Codex thread that is closed or a subagent, and vetted the text; the app checks again, because
/// it is the side that writes the message.
public protocol MessageSender: Sendable {
  func sendMessage(_ request: SendMessageRequest) async -> SendMessageOutcome
}

public struct SendMessageRequest: Sendable, Equatable {
  /// Which vendor's session `sessionID` names, and so which way the message travels: Claude
  /// Code's through Armada's own hook and inbox, Codex's through `codex queue`, and a headless
  /// Grok Build session's as the next headless turn, which Armada runs itself.
  public enum Vendor: String, Sendable, Equatable {
    case claude
    case codex
    case grok
  }

  /// A Claude Code session id or a Codex thread id, exact: the tool has already resolved any
  /// prefix or name.
  public let sessionID: String
  /// Trimmed and vetted by `Tools.messageRefusal`. The app adds the label the recipient sees.
  public let text: String
  public let vendor: Vendor

  public init(sessionID: String, text: String, vendor: Vendor = .claude) {
    self.sessionID = sessionID
    self.text = text
    self.vendor = vendor
  }
}

public enum SendMessageOutcome: Sendable, Equatable {
  /// The session's hook picked the message up, so a turn is starting on it.
  case delivered(name: String, project: String)
  /// Written, and waiting for the hook: `reason` says why it has not been picked up yet and when
  /// it will be, as a sentence for the caller.
  case queued(name: String, project: String, reason: String)
  /// A sentence for the caller, passed back word for word.
  case refused(String)
}
