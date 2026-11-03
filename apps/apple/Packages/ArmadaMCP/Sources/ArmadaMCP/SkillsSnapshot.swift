import Foundation

/// Each Agent Skill and custom command used in Claude Code, rolled up per project, account and
/// window, at one instant.
///
/// **A hop of its own, like `ProjectsSnapshot`.** Only `armada_get_skill_usage` reads it, and
/// no other tool should pay for rolling skill uses up. The app copies the ledger, the saved
/// projects and what each name turned out to be in one main-actor hop, and rolls them up after
/// it, so this arrives finished.
///
/// **Claude Code only.** Codex records no skill use of its own: using one is the model reading
/// a `SKILL.md` through a shell call.
public struct SkillsSnapshot: Sendable {
  public let takenAt: Date
  /// False while Armada has neither a licence nor a running trial; see `FleetSnapshot`.
  public let isEntitled: Bool
  /// `complete` once the ledger has read every transcript for tokens and for skills, and
  /// `earliestDay` the oldest day a skill use was counted for.
  public let index: ProjectsSnapshot.Index
  public let projects: [ProjectRef]
  /// Every Claude Code account on this Mac, and any account a tally names that is gone.
  public let accounts: [AccountRef]
  public let tallies: [Tally]

  public init(
    takenAt: Date, isEntitled: Bool, index: ProjectsSnapshot.Index, projects: [ProjectRef],
    accounts: [AccountRef], tallies: [Tally]
  ) {
    self.takenAt = takenAt
    self.isEntitled = isEntitled
    self.index = index
    self.projects = projects
    self.accounts = accounts
    self.tallies = tallies
  }

  public struct ProjectRef: Sendable, ProjectNaming {
    public let id: String
    public let name: String
    public let path: String

    public init(id: String, name: String, path: String) {
      self.id = id
      self.name = name
      self.path = path
    }
  }

  public struct AccountRef: Sendable {
    /// The config folder path, which is what the app keys accounts on.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  /// One name's uses in one window, in one project (or none) on one account.
  public struct Tally: Sendable {
    /// Nil for uses outside every saved project.
    public let projectID: String?
    public let accountID: String
    public let skill: String
    /// `skill`, `command`, `plugin` or `builtin`: what the name is on disk now.
    public let source: String
    /// `7d`, `30d` or `all`.
    public let window: String
    /// Loaded by Claude itself, through the `Skill` tool.
    public let auto: Int
    /// Typed by the person as `/name`.
    public let slash: Int
    public let lastUsed: Date

    public var total: Int { auto + slash }

    public init(
      projectID: String?, accountID: String, skill: String, source: String, window: String,
      auto: Int, slash: Int, lastUsed: Date
    ) {
      self.projectID = projectID
      self.accountID = accountID
      self.skill = skill
      self.source = source
      self.window = window
      self.auto = auto
      self.slash = slash
      self.lastUsed = lastUsed
    }
  }
}

/// What `Tools.lookupProject` needs of a project, so one lookup serves every snapshot that
/// names projects.
public protocol ProjectNaming {
  var id: String { get }
  var name: String { get }
  var path: String { get }
}

extension ProjectsSnapshot.Project: ProjectNaming {}
