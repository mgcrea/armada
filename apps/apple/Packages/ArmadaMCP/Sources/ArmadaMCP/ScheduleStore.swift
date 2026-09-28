import Foundation

/// The one door from the schedule tools into the app, for reading and for writing.
///
/// `schedules()` is its own hop, as `FleetSource.projects()` is: only one tool wants it, and it
/// reads the disk. `save` and `delete` are only reachable past the kit's write gate; the tool has
/// already found the project by the time a request arrives, and the app finds it again, because
/// it is the side that writes.
public protocol ScheduleStore: Sendable {
  func schedules() async -> SchedulesSnapshot
  func save(_ request: SaveScheduleRequest) async -> ScheduleOutcome
  func delete(_ request: DeleteScheduleRequest) async -> ScheduleOutcome
}

public struct SchedulesSnapshot: Sendable {
  public let takenAt: Date
  public let isEntitled: Bool
  public let rows: [ScheduleRow]

  public init(takenAt: Date, isEntitled: Bool, rows: [ScheduleRow]) {
    self.takenAt = takenAt
    self.isEntitled = isEntitled
    self.rows = rows
  }
}

/// One scheduled task, from any vendor. `status` is `active`, `paused`, or `unknown` for a row
/// (`editable: false`) whose file Armada could not fully read.
public struct ScheduleRow: Sendable, Equatable {
  public let vendor: String
  public let accountID: String
  public let account: String
  public let id: String
  public let name: String
  public let status: String
  public let rrule: String?
  public let cronExpression: String?
  public let fireAt: Date?
  public let summary: String
  public let cwd: String?
  public let model: String?
  public let reasoningEffort: String?
  public let lastRunAt: Date?
  public let nextRunAt: Date?
  public let prompt: String?
  public let editable: Bool
  public let readOnlyReason: String?

  public init(
    vendor: String, accountID: String, account: String, id: String, name: String, status: String,
    rrule: String? = nil, cronExpression: String? = nil, fireAt: Date? = nil, summary: String,
    cwd: String? = nil, model: String? = nil, reasoningEffort: String? = nil,
    lastRunAt: Date? = nil, nextRunAt: Date? = nil, prompt: String? = nil, editable: Bool,
    readOnlyReason: String? = nil
  ) {
    self.vendor = vendor
    self.accountID = accountID
    self.account = account
    self.id = id
    self.name = name
    self.status = status
    self.rrule = rrule
    self.cronExpression = cronExpression
    self.fireAt = fireAt
    self.summary = summary
    self.cwd = cwd
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.lastRunAt = lastRunAt
    self.nextRunAt = nextRunAt
    self.prompt = prompt
    self.editable = editable
    self.readOnlyReason = readOnlyReason
  }
}

/// A create when `id` is nil, else an update of that id where every nil field is kept.
public struct SaveScheduleRequest: Sendable, Equatable {
  public let id: String?
  public let name: String?
  public let prompt: String?
  public let rrule: String?
  /// A saved project's exact id: the tool has already resolved it.
  public let projectID: String?
  /// A Codex account id or name; nil for the project's own, or the only one.
  public let account: String?
  public let model: String?
  public let reasoningEffort: String?
  public let status: String?

  public init(
    id: String? = nil, name: String? = nil, prompt: String? = nil, rrule: String? = nil,
    projectID: String? = nil, account: String? = nil, model: String? = nil,
    reasoningEffort: String? = nil, status: String? = nil
  ) {
    self.id = id
    self.name = name
    self.prompt = prompt
    self.rrule = rrule
    self.projectID = projectID
    self.account = account
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.status = status
  }
}

public struct DeleteScheduleRequest: Sendable, Equatable {
  public let id: String
  public let account: String?

  public init(id: String, account: String? = nil) {
    self.id = id
    self.account = account
  }
}

public struct ScheduleChange: Sendable, Equatable {
  public let id: String
  public let name: String
  public let account: String
  public let summary: String
  public let status: String
  public let created: Bool
  /// Why Codex may run it once outside its rule after this save; nil when nothing says it will.
  public let earlyRun: EarlyRun?
  /// Whether macOS took the notification: false when notifications for Armada are off.
  public var notificationPosted: Bool

  /// Codex keeps a task's stored next run time while the task stays active in its database, and
  /// Armada writes neither database, so a save can leave that time behind (docs/implementation.md,
  /// "Codex automations written from outside the app").
  public enum EarlyRun: Sendable, Equatable {
    /// Resumed with a stored run time that passed while it was paused.
    case dueWhilePaused
    /// A new rule on an active task, with a run time still stored from the old one.
    case oldTime

    /// Said in the tool's answer and in the notification alike.
    public var sentence: String {
      switch self {
      case .dueWhilePaused: "Codex may run it once right away: it came due while paused."
      case .oldTime: "Codex may run it once more at its old time."
      }
    }
  }

  public init(
    id: String, name: String, account: String, summary: String, status: String, created: Bool,
    earlyRun: EarlyRun? = nil, notificationPosted: Bool = true
  ) {
    self.id = id
    self.name = name
    self.account = account
    self.summary = summary
    self.status = status
    self.created = created
    self.earlyRun = earlyRun
    self.notificationPosted = notificationPosted
  }
}

public enum ScheduleOutcome: Sendable, Equatable {
  case saved(ScheduleChange)
  case deleted(ScheduleChange)
  /// A sentence for the caller, passed back word for word.
  case refused(String)
}
