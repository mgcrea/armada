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
  /// `nonisolated` because the bridge calls it off the main actor. Only `Sendable` values cross
  /// in; the content object is built here.
  ///
  /// **Awaited, not fired and forgotten**, so the tool claims a notification only when macOS took
  /// one: false when notifications for Armada are off, or were never allowed, or `add` failed.
  /// `folder` is the automation's working folder, named by its last component.
  static func post(verb: String, change: ScheduleChange, folder: String?) async -> Bool {
    let title =
      change.summary.isEmpty
      ? "An agent \(verb) \(change.name), on Codex"
      : "An agent \(verb) \(change.name), \(change.summary), on Codex"
    let status =
      verb == "deleted"
      ? "Codex will not run it again."
      : change.status == "paused"
        ? "Paused."
        : "Codex runs it unattended." + (change.earlyRun.map { " " + $0.sentence } ?? "")
    let project = folder.map { " Project: \(URL(filePath: $0).lastPathComponent)." } ?? ""
    let body = "Account: \(change.account).\(project) \(status)"
    let identifier = "schedule-\(change.id)-\(UUID().uuidString)"
    let center = UNUserNotificationCenter.current()
    guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
      return false
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = "schedules"
    do {
      try await center.add(
        UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
      return true
    } catch {
      return false
    }
  }
}
