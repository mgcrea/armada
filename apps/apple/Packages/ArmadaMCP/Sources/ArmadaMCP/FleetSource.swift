import Foundation

/// Where the tools learn about the fleet, and the only place they may.
///
/// The app's watchers are main-actor objects that change under a SwiftUI body every second.
/// A tool call arrives on the listener's connection thread. This protocol is the whole of
/// what may cross between the two, and its shape enforces the rule Almanac's bridge
/// learned: **hop once, take an immutable snapshot, leave.** Reading two properties in two
/// hops can straddle a rescan and pair one session's state with another rescan's context.
public protocol FleetSource: Sendable {
  /// Everything the read tools need, read together in one hop.
  func snapshot() async -> FleetSnapshot

  /// Which application a Claude Code session's process belongs to.
  ///
  /// A second, deliberate hop rather than a field on every session: it walks the process
  /// tree, and only `armada_get_session` asks.
  func host(forClaudeSession id: String) async -> FleetSnapshot.Host?

  /// The saved projects, their live sessions and what has been spent in each.
  ///
  /// Another deliberate hop rather than part of `snapshot()`: only `armada_get_projects`
  /// wants it, and it rolls a token ledger up into projects. Never called beside
  /// `snapshot()` in one tool, so the ids and the figures describe one instant.
  func projects() async -> ProjectsSnapshot
}

/// The fleet at one instant, as `Sendable` values.
///
/// **Each vendor keeps its own types**, for the reason the app keeps `SessionState` and
/// `CodexSessionState` apart: Claude Code reports whether a session is alive and leaves the
/// turn to be guessed, Codex reports the turn and leaves the session to be guessed. A shared
/// shape would throw away whichever half it could not express.
///
/// States travel as the app's own raw values (`waiting`, `runningTool`, `awaitingInput`),
/// never renamed, because the app's rule is to use each vendor's vocabulary rather than
/// invent a third.
public struct FleetSnapshot: Sendable {
  public let takenAt: Date
  /// False while Armada has neither a licence nor a running trial. Its watchers are
  /// stopped then, so every list below is empty by construction — which is not the same
  /// claim as an empty fleet, and the tools say so.
  public let isEntitled: Bool
  public let claude: [ClaudeAccount]
  public let codex: [CodexAccount]

  public init(takenAt: Date, isEntitled: Bool, claude: [ClaudeAccount], codex: [CodexAccount]) {
    self.takenAt = takenAt
    self.isEntitled = isEntitled
    self.claude = claude
    self.codex = codex
  }

  /// One Claude config folder: an organization with its own sessions and plan limits.
  public struct ClaudeAccount: Sendable {
    /// The folder path, which is what the app keys accounts on.
    public let id: String
    public let name: String
    public let plan: String?
    /// `settings.json`'s `model`, an alias like `opus[1m]`. The account default, not any
    /// one session's.
    public let modelID: String?
    public let usage: Usage?
    /// The newest rate-limit refusal seen in any of this account's transcripts.
    public let quotaHit: QuotaHit?
    public let sessions: [ClaudeSession]

    public init(
      id: String, name: String, plan: String?, modelID: String?, usage: Usage?,
      quotaHit: QuotaHit?, sessions: [ClaudeSession]
    ) {
      self.id = id
      self.name = name
      self.plan = plan
      self.modelID = modelID
      self.usage = usage
      self.quotaHit = quotaHit
      self.sessions = sessions
    }
  }

  public struct ClaudeSession: Sendable {
    public let id: String
    public let pid: Int32
    /// What the app's list calls it: the `ai-title`, else the registry name, else the
    /// project.
    public let name: String
    public let title: String?
    public let project: String
    public let cwd: String
    /// `SessionState.rawValue`: `waiting`, `working`, `runningTool` or `idle`.
    public let state: String
    public let stateLabel: String
    /// True for `runningTool`, the one state still inferred from the transcript.
    public let stateIsInferred: Bool
    /// The app's own definition, carried rather than recomputed here, so the tool, the
    /// menu bar halo and the mouse button's "next waiting" cannot disagree.
    public let wantsAttention: Bool
    /// Display text from the registry. Never a value to branch on.
    public let waitingFor: String?
    public let startedAt: Date?
    public let lastActivity: Date?
    public let statusChangedAt: Date?
    public let model: String?
    public let context: Context?
    public let quotaHit: QuotaHit?
    /// Nil for a session that has never been prompted, which has no transcript file.
    public let transcriptPath: String?

    public init(
      id: String, pid: Int32, name: String, title: String?, project: String, cwd: String,
      state: String, stateLabel: String, stateIsInferred: Bool, wantsAttention: Bool,
      waitingFor: String?, startedAt: Date?, lastActivity: Date?, statusChangedAt: Date?,
      model: String?, context: Context?, quotaHit: QuotaHit?, transcriptPath: String?
    ) {
      self.id = id
      self.pid = pid
      self.name = name
      self.title = title
      self.project = project
      self.cwd = cwd
      self.state = state
      self.stateLabel = stateLabel
      self.stateIsInferred = stateIsInferred
      self.wantsAttention = wantsAttention
      self.waitingFor = waitingFor
      self.startedAt = startedAt
      self.lastActivity = lastActivity
      self.statusChangedAt = statusChangedAt
      self.model = model
      self.context = context
      self.quotaHit = quotaHit
      self.transcriptPath = transcriptPath
    }
  }

  /// One Codex home.
  public struct CodexAccount: Sendable {
    public let id: String
    public let name: String
    public let plan: String?
    public let usage: Usage?
    public let sessions: [CodexSession]

    public init(id: String, name: String, plan: String?, usage: Usage?, sessions: [CodexSession]) {
      self.id = id
      self.name = name
      self.plan = plan
      self.usage = usage
      self.sessions = sessions
    }
  }

  public struct CodexSession: Sendable {
    public let id: String
    public let name: String
    public let title: String?
    public let project: String
    public let cwd: String
    /// `CodexSessionState.rawValue`: `working`, `awaitingInput` or `ended`.
    public let state: String
    public let stateLabel: String
    public let isLive: Bool
    public let isSubagent: Bool
    /// "Automation", "Guardian review". Nil for a thread a person started.
    public let kind: String?
    public let startedAt: Date?
    public let lastActivity: Date?
    public let model: String?
    public let context: Context?
    /// Cumulative across every request, so several times the window on a long session.
    public let totalTokens: Int?
    public let rolloutPath: String

    public init(
      id: String, name: String, title: String?, project: String, cwd: String, state: String,
      stateLabel: String, isLive: Bool, isSubagent: Bool, kind: String?, startedAt: Date?,
      lastActivity: Date?, model: String?, context: Context?, totalTokens: Int?,
      rolloutPath: String
    ) {
      self.id = id
      self.name = name
      self.title = title
      self.project = project
      self.cwd = cwd
      self.state = state
      self.stateLabel = stateLabel
      self.isLive = isLive
      self.isSubagent = isSubagent
      self.kind = kind
      self.startedAt = startedAt
      self.lastActivity = lastActivity
      self.model = model
      self.context = context
      self.totalTokens = totalTokens
      self.rolloutPath = rolloutPath
    }
  }

  /// How full a session's context window is.
  public struct Context: Sendable {
    public let total: Int
    public let limit: Int
    /// Where `limit` came from. Claude Code does not record the window size, so on that
    /// side it is sometimes assumed, and this sentence says when.
    public let limitNote: String
    public let cacheRead: Int
    public let cacheCreation: Int
    public let freshInput: Int
    public let output: Int
    public let at: Date?
    public let hasCompacted: Bool

    public init(
      total: Int, limit: Int, limitNote: String, cacheRead: Int, cacheCreation: Int,
      freshInput: Int, output: Int, at: Date?, hasCompacted: Bool
    ) {
      self.total = total
      self.limit = limit
      self.limitNote = limitNote
      self.cacheRead = cacheRead
      self.cacheCreation = cacheCreation
      self.freshInput = freshInput
      self.output = output
      self.at = at
      self.hasCompacted = hasCompacted
    }

    public var percent: Int {
      guard limit > 0 else { return 0 }
      return Int((Double(total) / Double(limit) * 100).rounded())
    }
  }

  /// An account's plan windows.
  public struct Usage: Sendable {
    public let fiveHour: Window?
    public let sevenDay: Window?
    public let limits: [Limit]
    public let fetchedAt: Date?
    /// `live`, `cache` or `sessionLog` — `UsageSnapshot.Source`, which the app shows as a
    /// badge because the three age differently.
    public let source: String

    public init(
      fiveHour: Window?, sevenDay: Window?, limits: [Limit], fetchedAt: Date?, source: String
    ) {
      self.fiveHour = fiveHour
      self.sevenDay = sevenDay
      self.limits = limits
      self.fetchedAt = fetchedAt
      self.source = source
    }
  }

  public struct Window: Sendable {
    public let utilization: Int
    public let resetsAt: Date?
    /// Set when a rate-limit refusal newer than the figure overruled it, as the app's own
    /// meters do.
    public let refusedAt: Date?

    public init(utilization: Int, resetsAt: Date?, refusedAt: Date?) {
      self.utilization = utilization
      self.resetsAt = resetsAt
      self.refusedAt = refusedAt
    }
  }

  /// One entry of Claude Code's per-window list, including the per-model ones.
  public struct Limit: Sendable {
    public let title: String
    public let subtitle: String
    public let percent: Int
    public let resetsAt: Date?
    public let isActive: Bool

    public init(title: String, subtitle: String, percent: Int, resetsAt: Date?, isActive: Bool) {
      self.title = title
      self.subtitle = subtitle
      self.percent = percent
      self.resetsAt = resetsAt
      self.isActive = isActive
    }
  }

  public struct QuotaHit: Sendable {
    public let at: Date
    public let resetsAt: Date
    /// `fiveHour` or `sevenDay`, or nil for a window this build does not know.
    public let window: String?

    public init(at: Date, resetsAt: Date, window: String?) {
      self.at = at
      self.resetsAt = resetsAt
      self.window = window
    }
  }

  public struct Host: Sendable {
    public let name: String
    public let bundleID: String?
    public let pid: Int32

    public init(name: String, bundleID: String?, pid: Int32) {
      self.name = name
      self.bundleID = bundleID
      self.pid = pid
    }
  }
}

extension FleetSnapshot.ClaudeSession {
  /// `Session.stateRank`'s order: stopped and wanting you, then writing, then an
  /// outstanding tool, then idle.
  var rank: Int {
    switch state {
    case "waiting": 0
    case "working": 1
    case "runningTool": 2
    default: 4
    }
  }
}

extension FleetSnapshot.CodexSession {
  /// Placed into the Claude ranking rather than given its own. `awaitingInput` sits with
  /// idle, not with `waiting`: it means open and not busy, and ranking it first would put
  /// every open Codex thread ahead of a Claude session stopped on a permission prompt.
  var rank: Int {
    switch state {
    case "working": 1
    case "awaitingInput": 4
    default: 5
    }
  }
}
