import Foundation

/// The parsers for what Grok Build writes, with no file system and no UI, so `make unit` can
/// check them. Every shape here was read off grok 1.0.34 on 2026-09-17; docs/grok-sessions.md
/// has the samples.
nonisolated enum GrokFiles {
  /// One entry of `active_sessions.json`.
  struct ActiveSession: Sendable, Hashable {
    let sessionId: String
    let pid: Int32
    let cwd: String
  }

  static func activeSessions(_ data: Data) -> [ActiveSession] {
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return array.compactMap { entry in
      guard let id = entry["session_id"] as? String,
        let pid = (entry["pid"] as? NSNumber)?.int32Value, pid > 0
      else { return nil }
      return ActiveSession(sessionId: id.lowercased(), pid: pid, cwd: entry["cwd"] as? String ?? "")
    }
  }

  /// The parts of a session's `summary.json` Armada shows.
  struct Summary: Sendable, Hashable {
    let sessionId: String
    let cwd: String
    /// `generated_title`, else a non-empty `session_summary`. Written after the first turn of
    /// a TUI session; a short headless session had neither.
    let title: String?
    let model: String?
    let createdAt: Date?
    let updatedAt: Date?
    /// `headless` for `grok -p`. Absent on a TUI session.
    let kind: String?
    let parentSessionId: String?

    var projectName: String {
      cwd.isEmpty ? "Unknown folder" : URL(filePath: cwd).lastPathComponent
    }
  }

  static func summary(_ data: Data) -> Summary? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let info = object["info"] as? [String: Any],
      let id = info["id"] as? String
    else { return nil }
    func text(_ key: String) -> String? {
      guard let value = object[key] as? String,
        !value.trimmingCharacters(in: .whitespaces).isEmpty
      else { return nil }
      return value
    }
    func date(_ key: String) -> Date? { text(key).flatMap(UsageSnapshot.parseTimestamp) }
    return Summary(
      sessionId: id.lowercased(), cwd: info["cwd"] as? String ?? "",
      title: text("generated_title") ?? text("session_summary"),
      model: text("current_model_id"), createdAt: date("created_at"),
      updatedAt: date("last_active_at") ?? date("updated_at"), kind: text("session_kind"),
      parentSessionId: text("parent_session_id"))
  }

  /// What the end of `updates.jsonl` says.
  struct UpdatesTail: Sendable, Hashable {
    let lastEventAt: Date?
    let isTurnRunning: Bool
  }

  /// Walks back to the newest update that settles whether a turn is running.
  ///
  /// `turn_completed` ends a turn, and so does any other `turn_*` update: an interrupted or
  /// failed turn has not been measured, and a session shown working forever is the worse
  /// mistake. The prompt, the answer, thoughts and tool calls all mean a turn is under way.
  /// Hook runs settle nothing: the `stop` hook's own record is written before
  /// `turn_completed`, and `session_end` and a second `stop` after it.
  static func updatesTail(_ buffer: Data, droppingFirstLine: Bool) -> UpdatesTail {
    var lastEventAt: Date?
    for line in JSONLines.newestFirst(buffer, droppingFirstLine: droppingFirstLine) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      if lastEventAt == nil, let seconds = (object["timestamp"] as? NSNumber)?.doubleValue {
        lastEventAt = Date(timeIntervalSince1970: seconds)
      }
      let update = (object["params"] as? [String: Any])?["update"] as? [String: Any]
      switch update?["sessionUpdate"] as? String {
      case let kind? where kind.hasPrefix("turn_") && kind != "turn_started":
        return UpdatesTail(lastEventAt: lastEventAt, isTurnRunning: false)
      case "turn_started", "user_message_chunk", "agent_message_chunk", "agent_thought_chunk",
        "tool_call", "tool_call_update", "plan":
        return UpdatesTail(lastEventAt: lastEventAt, isTurnRunning: true)
      case "hook_execution" where update?["event_name"] as? String == "user_prompt_submit":
        return UpdatesTail(lastEventAt: lastEventAt, isTurnRunning: true)
      default:
        continue
      }
    }
    return UpdatesTail(lastEventAt: lastEventAt, isTurnRunning: false)
  }

  /// `usage.json`'s session totals: the same JSON `grok usage <id>` prints.
  struct Usage: Sendable, Hashable {
    let totalTokens: Int
    /// `costUsdTicks`, of which there are 1e10 to the dollar.
    let costUSD: Double
    let turnCount: Int
  }

  static let ticksPerDollar = 10_000_000_000.0

  static func usage(_ data: Data) -> Usage? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let session = object["session"] as? [String: Any]
    else { return nil }
    func int(_ key: String) -> Int { (session[key] as? NSNumber)?.intValue ?? 0 }
    let ticks = (session["costUsdTicks"] as? NSNumber)?.doubleValue ?? 0
    return Usage(
      totalTokens: int("totalTokens"), costUSD: ticks / ticksPerDollar, turnCount: int("turnCount"))
  }

  /// The context figures in `signals.json`, as Grok itself measured them.
  struct Context: Sendable, Hashable {
    let used: Int
    let window: Int
  }

  static func context(_ data: Data) -> Context? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let used = (object["contextTokensUsed"] as? NSNumber)?.intValue,
      let window = (object["contextWindowTokens"] as? NSNumber)?.intValue, window > 0
    else { return nil }
    return Context(used: used, window: window)
  }

  /// A session directory's name is its id, a UUID. Anything else under a project directory is
  /// not a session.
  static func isSessionId(_ name: String) -> Bool {
    UUID(uuidString: name) != nil
  }
}
