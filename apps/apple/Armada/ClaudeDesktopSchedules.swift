import Foundation

/// The Claude desktop app's scheduled tasks, read and never written.
///
/// **Read-only by design, not by omission.** The app holds these tasks in memory and writes the
/// whole file back on every change, so an outside edit is lost; and each task carries the tool
/// approvals the person granted it in the app, which a write from here would be forging.
/// Sessions running inside the Claude app have tools to change them.
///
/// **Field names are read off the app's code** (Claude.app 2.9939.2, 2026-09-28): the store keys
/// tasks on `id`, and a task has `cronExpression` or a one-time `fireAt`. No real task had been
/// seen on this Mac when this was written, so every field is optional and a task with neither
/// schedule is still listed. The prompt lives in a separate task file and is not read.
nonisolated enum ClaudeDesktopSchedules {
  struct ScheduledTask: Sendable, Equatable {
    let id: String
    /// `<account>/<org>`, from the folder names: Armada opens no Claude credential to say more.
    let account: String
    let cronExpression: String?
    let fireAt: Date?
    let lastRunAt: Date?
    let enabled: Bool
  }

  static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(
        path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory
      )
  }

  static func read(root: URL) -> [ScheduledTask] {
    let fm = FileManager.default
    var out: [ScheduledTask] = []
    for account in ((try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [])
      .sorted()
    {
      let accountURL = root.appending(path: account, directoryHint: .isDirectory)
      for org
        in ((try? fm.contentsOfDirectory(atPath: accountURL.path(percentEncoded: false))) ?? [])
        .sorted()
      {
        let file = accountURL.appending(path: org).appending(path: "scheduled-tasks.json")
        guard let data = try? Data(contentsOf: file),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tasks = object["scheduledTasks"] as? [[String: Any]]
        else { continue }
        for task in tasks {
          guard let id = (task["id"] as? String) ?? (task["taskId"] as? String) else { continue }
          out.append(
            ScheduledTask(
              id: id, account: "\(account)/\(org)",
              cronExpression: task["cronExpression"] as? String,
              fireAt: date(task["fireAt"]), lastRunAt: date(task["lastRunAt"]),
              enabled: (task["enabled"] as? Bool) ?? true))
        }
      }
    }
    return out
  }

  /// Epoch milliseconds, or an ISO 8601 string: the app's code writes numbers, but a string costs
  /// nothing to accept. JavaScript's `toISOString()` produces fractional seconds.
  private static func date(_ value: Any?) -> Date? {
    if let ms = value as? NSNumber { return Date(timeIntervalSince1970: ms.doubleValue / 1000) }
    if let text = value as? String {
      let withFractional = ISO8601DateFormatter()
      withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = withFractional.date(from: text) { return date }
      return ISO8601DateFormatter().date(from: text)
    }
    return nil
  }
}
