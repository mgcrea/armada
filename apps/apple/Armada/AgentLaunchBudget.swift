import Foundation

/// How many sessions agents may start through `armada_start_session` in a short time.
///
/// **A budget, not a cooldown.** It used to be one launch every ten seconds, which made a room's
/// seats wait in line: three seats took twenty seconds and two refusals. What it protects
/// against is a supervisor stuck in a loop, filling the screen with windows, and a cap per
/// minute stops that just as well. The cap is a full room (`RoomRules.maxSeats`, kept equal
/// here because this file compiles without ArmadaMCP), so a room can start all its seats at once.
nonisolated struct AgentLaunchBudget: Equatable {
  static let window: TimeInterval = 60
  static let limit = 8

  /// Launches inside the window, oldest first.
  private(set) var launches: [Date] = []

  /// Why a launch at `now` is refused, or nil when it may go ahead.
  func refusal(at now: Date) -> String? {
    let recent = launches.filter { now.timeIntervalSince($0) < Self.window }
    guard recent.count >= Self.limit, let oldest = recent.first else { return nil }
    let wait = max(1, Int((Self.window - now.timeIntervalSince(oldest)).rounded(.up)))
    return "Agents started \(recent.count) sessions in the last minute, the most Armada allows. "
      + "Try again in \(wait) seconds."
  }

  /// Count a launch that went ahead, forgetting those the window has passed.
  mutating func record(_ date: Date) {
    launches = launches.filter { date.timeIntervalSince($0) < Self.window } + [date]
  }
}
