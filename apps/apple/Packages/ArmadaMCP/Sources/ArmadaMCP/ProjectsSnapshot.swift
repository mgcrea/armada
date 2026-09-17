import Foundation

/// The person's saved projects at one instant, with what has been spent in each.
///
/// **A second hop, not a field of `FleetSnapshot`.** Every other tool reads the fleet, and
/// none of them should pay for rolling a token ledger up into projects it never shows. The
/// app reads its stored projects, ledger and live sessions in one main-actor hop and does the
/// roll-up after it, so this arrives finished.
///
/// **Tokens only.** The figures come from transcripts, which record what was used, never
/// what it cost.
public struct ProjectsSnapshot: Sendable {
  public let takenAt: Date
  /// False while Armada has neither a licence nor a running trial; see `FleetSnapshot`.
  public let isEntitled: Bool
  public let index: Index
  public let projects: [Project]

  public init(takenAt: Date, isEntitled: Bool, index: Index, projects: [Project]) {
    self.takenAt = takenAt
    self.isEntitled = isEntitled
    self.index = index
    self.projects = projects
  }

  /// How far the ledger has read.
  public struct Index: Sendable {
    /// True once every transcript on the Mac has been read at least once. Before that the
    /// totals are low, and the newest days are the most complete.
    public let complete: Bool
    public let filesRead: Int?
    public let filesTotal: Int?
    /// The oldest day anything was counted for: where "all time" starts.
    public let earliestDay: Date?

    public init(complete: Bool, filesRead: Int?, filesTotal: Int?, earliestDay: Date?) {
      self.complete = complete
      self.filesRead = filesRead
      self.filesTotal = filesTotal
      self.earliestDay = earliestDay
    }
  }

  public struct Project: Sendable {
    public let id: String
    public let name: String
    public let path: String
    /// False when the folder has moved or been deleted. Its history is still here.
    public let exists: Bool
    public let defaultAgent: Agent
    public let live: [LiveSession]
    public let lastActive: Date?
    /// `7d`, `30d` and `all`.
    public let windows: [Window]
    public let byModel: [Slice]
    public let byAccount: [Slice]

    public init(
      id: String, name: String, path: String, exists: Bool, defaultAgent: Agent,
      live: [LiveSession], lastActive: Date?, windows: [Window], byModel: [Slice],
      byAccount: [Slice]
    ) {
      self.id = id
      self.name = name
      self.path = path
      self.exists = exists
      self.defaultAgent = defaultAgent
      self.live = live
      self.lastActive = lastActive
      self.windows = windows
      self.byModel = byModel
      self.byAccount = byAccount
    }
  }

  /// The agent and account a project starts on.
  public struct Agent: Sendable {
    /// `claude`, `codex` or `grok`.
    public let vendor: String
    public let accountID: String
    /// Nil when that account is not on this Mac any more.
    public let accountName: String?

    public init(vendor: String, accountID: String, accountName: String?) {
      self.vendor = vendor
      self.accountID = accountID
      self.accountName = accountName
    }
  }

  public struct LiveSession: Sendable {
    public let id: String
    public let vendor: String
    public let name: String
    /// The vendor's own state vocabulary, as in `FleetSnapshot`.
    public let state: String
    public let cwd: String

    public init(id: String, vendor: String, name: String, state: String, cwd: String) {
      self.id = id
      self.vendor = vendor
      self.name = name
      self.state = state
      self.cwd = cwd
    }
  }

  public struct Window: Sendable {
    public let key: String
    public let tokens: Tokens
    public let sessions: Int

    public init(key: String, tokens: Tokens, sessions: Int) {
      self.key = key
      self.tokens = tokens
      self.sessions = sessions
    }
  }

  public struct Tokens: Sendable {
    public let fresh: Int
    public let cacheWrite: Int
    public let cacheRead: Int
    public let output: Int
    /// Codex only, and already part of `output`.
    public let reasoning: Int

    public var total: Int { fresh + cacheWrite + cacheRead + output }

    public init(fresh: Int, cacheWrite: Int, cacheRead: Int, output: Int, reasoning: Int) {
      self.fresh = fresh
      self.cacheWrite = cacheWrite
      self.cacheRead = cacheRead
      self.output = output
      self.reasoning = reasoning
    }
  }

  /// One model's or one account's share of a project.
  public struct Slice: Sendable {
    /// The model id, or the account id.
    public let key: String
    /// What to call it: the model id again, or the account's name.
    public let label: String
    public let vendor: String?
    public let windows: [Window]

    public init(key: String, label: String, vendor: String?, windows: [Window]) {
      self.key = key
      self.label = label
      self.vendor = vendor
      self.windows = windows
    }
  }
}
