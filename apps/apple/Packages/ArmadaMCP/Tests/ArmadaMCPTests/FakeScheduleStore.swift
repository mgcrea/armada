import Foundation

@testable import ArmadaMCP

/// A store that touches no disk: rows as given, and every write recorded and answered as told.
final class FakeScheduleStore: ScheduleStore, @unchecked Sendable {
  private let lock = NSLock()
  private var saved: [SaveScheduleRequest] = []
  private var deleted: [DeleteScheduleRequest] = []

  var isEntitled = true
  var rows: [ScheduleRow] = [
    ScheduleRow(
      vendor: "codex", accountID: "/Users/me/.codex", account: "Codex", id: "daily-intel",
      name: "Daily intel", status: "active",
      rrule: "RRULE:FREQ=WEEKLY;BYHOUR=7;BYMINUTE=0;BYDAY=SU,MO,TU,WE,TH,FR,SA",
      summary: "daily at 07:00", cwd: "/work/armada", model: "gpt-5.5",
      lastRunAt: Date(timeIntervalSince1970: 1_790_000_000),
      nextRunAt: Date(timeIntervalSince1970: 1_790_086_400),
      prompt: String(repeating: "p", count: 3_000), editable: true),
    ScheduleRow(
      vendor: "claude", accountID: "acct/org1", account: "acct/org1", id: "morning",
      name: "morning", status: "active", cronExpression: "0 7 * * *", summary: "0 7 * * *",
      editable: false,
      readOnlyReason: "Claude desktop tasks change from a session in the Claude app."),
  ]
  var outcome: ScheduleOutcome = .saved(
    ScheduleChange(
      id: "daily-intel", name: "Daily intel", account: "Codex", summary: "daily at 07:00",
      status: "active", created: true))

  var saveRequests: [SaveScheduleRequest] { lock.withLock { saved } }
  var deleteRequests: [DeleteScheduleRequest] { lock.withLock { deleted } }

  func schedules() async -> SchedulesSnapshot {
    SchedulesSnapshot(
      takenAt: Date(timeIntervalSince1970: 1_790_000_100), isEntitled: isEntitled, rows: rows)
  }

  func save(_ request: SaveScheduleRequest) async -> ScheduleOutcome {
    lock.withLock { saved.append(request) }
    return outcome
  }

  func delete(_ request: DeleteScheduleRequest) async -> ScheduleOutcome {
    lock.withLock { deleted.append(request) }
    return outcome
  }
}
