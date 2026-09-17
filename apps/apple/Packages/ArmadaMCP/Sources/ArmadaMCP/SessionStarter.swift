import Foundation

/// The one door from a tool to starting anything. `FleetSource` only reads.
///
/// **Only reachable past the kit's write gate.** `armada_start_session` is registered with
/// `gate: .requiresWrites`, so while the person has not turned on Allow writes it is neither
/// listed nor callable, and nothing ever gets this far. The tool has already found the project
/// and checked the opening message by the time a request arrives; the app still checks both
/// again, because it is the side that opens the terminal.
public protocol SessionStarter: Sendable {
  func startSession(_ request: StartSessionRequest) async -> StartSessionOutcome
}

public struct StartSessionRequest: Sendable, Equatable {
  /// Nil when resuming: the session's own transcript says where it ran.
  public let projectID: String?
  /// `claude` or `codex`; nil for the project's own agent.
  public let vendor: String?
  /// An account id or name; nil for the project's own account.
  public let account: String?
  public let prompt: String?
  /// A Claude Code session id to continue rather than start fresh. The app refuses one that is
  /// still live anywhere: two processes on one transcript is what forking exists to avoid.
  public let resume: String?

  public init(
    projectID: String?, vendor: String?, account: String?, prompt: String?, resume: String? = nil
  ) {
    self.projectID = projectID
    self.vendor = vendor
    self.account = account
    self.prompt = prompt
    self.resume = resume
  }
}

/// What was asked of the terminal. Armada does not own the process, and the session reaches the
/// fleet through the watchers like any other; `sessionID` is what it will be found under there,
/// when Armada chose it.
public struct StartedSession: Sendable, Equatable {
  public let project: String
  public let path: String
  public let vendor: String
  public let accountID: String
  public let account: String
  public let terminal: String
  public let withPrompt: Bool
  /// The opening message was typed into the session's input rather than sent, which is what VS
  /// Code's Claude Code extension does with one. The person sends it.
  public let promptAwaitsSend: Bool
  /// The id the session will have: minted by Armada and passed as `--session-id` for a fresh
  /// Claude Code session in a terminal, or the one resumed. Nil for VS Code and Codex, which
  /// choose their own.
  public let sessionID: String?
  public let resumed: Bool

  public init(
    project: String, path: String, vendor: String, accountID: String, account: String,
    terminal: String, withPrompt: Bool, promptAwaitsSend: Bool = false, sessionID: String? = nil,
    resumed: Bool = false
  ) {
    self.project = project
    self.path = path
    self.vendor = vendor
    self.accountID = accountID
    self.account = account
    self.terminal = terminal
    self.withPrompt = withPrompt
    self.promptAwaitsSend = promptAwaitsSend
    self.sessionID = sessionID
    self.resumed = resumed
  }
}

public enum StartSessionOutcome: Sendable, Equatable {
  case started(StartedSession)
  /// A sentence for the caller, passed back word for word.
  case refused(String)
}
