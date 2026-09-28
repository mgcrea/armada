import ArmadaMCP
import Foundation
import UserNotifications

/// The one notification a schedule written over MCP posts.
///
/// **Why every time.** A schedule outlives the conversation that made it and runs with nobody
/// watching. A session talked into planting one is found out the moment it happens, and the
/// person never has to open anything to check. It cannot name the client: a tool handler
/// receives only its arguments.
nonisolated enum ScheduleNotifier {
  /// `nonisolated` because the bridge calls it off the main actor. Only `Sendable` strings cross
  /// into the task; the content object is built inside it.
  static func post(verb: String, change: ScheduleChange) {
    let title =
      change.summary.isEmpty
      ? "An agent \(verb) \(change.name), on Codex"
      : "An agent \(verb) \(change.name), \(change.summary), on Codex"
    let status =
      verb == "deleted"
      ? "Codex will not run it again."
      : change.status == "paused" ? "Paused." : "Codex runs it unattended."
    let body = "Account: \(change.account). \(status)"
    let identifier = "schedule-\(change.id)-\(UUID().uuidString)"
    Task {
      let center = UNUserNotificationCenter.current()
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.threadIdentifier = "schedules"
      try? await center.add(
        UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
  }
}
