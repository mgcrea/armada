import Foundation

/// The lines a shim prints on stderr, worded as the spec's "What the shim says". Every line
/// starts `buildslot: ` so it reads as the shim's, not the build's.
public enum WaitMessages {
  static let prefix = "buildslot: "

  public static func waitingForSlot(holders: [SlotRecord], busy: Int, total: Int, now: Date)
    -> String
  {
    let heldBy =
      holders.isEmpty ? "" : ", held by " + joined(holders.map { describe($0, now: now) })
    return prefix + "waiting for a slot (\(busy) of \(total) busy)\(heldBy). Queued, not hung."
  }

  public static func waitingForMemory(_ p: MemoryPressure, remaining: TimeInterval) -> String {
    prefix + "a slot is free; waiting for memory pressure (\(p.word)) to ease, runs anyway in "
      + "\(duration(remaining))."
  }

  public static func memoryCapReached(_ p: MemoryPressure, after: TimeInterval) -> String {
    prefix + "memory pressure still \(p.word) after \(duration(after)); running anyway."
  }

  public static func slotCapReached(after: TimeInterval) -> String {
    prefix + "no slot after \(duration(after)); running anyway."
  }

  /// `slot` as stored: slot 1 is `slots/1.lock`.
  public static func gotSlot(_ slot: Int, after: TimeInterval) -> String {
    prefix + "got slot \(slot) after \(duration(after))."
  }

  public static func unqueued(_ reason: String) -> String {
    prefix + "\(reason); running unqueued."
  }

  /// `40 s`, `2 min`, `3 min 12 s`, `1 h 5 min`, in whole seconds rounded down. A value that is
  /// not finite reads as 0, and one past a day as a day, so a clock jump or a corrupt record
  /// never traps converting to `Int`.
  public static func duration(_ t: TimeInterval) -> String {
    let seconds = t.isFinite ? Int(min(max(0, t), 86_400)) : 0
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 {
      let rest = seconds % 60
      return rest == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(rest) s"
    }
    let minutes = seconds % 3600 / 60
    return minutes == 0 ? "\(seconds / 3600) h" : "\(seconds / 3600) h \(minutes) min"
  }

  /// `valise/land-gate-f764fa9 (pid 17804, swift test, 2 min)`, aged from `startedAt`, or from
  /// `waitingSince` for a waiter. A record with neither leaves the age out rather than guess one.
  public static func describe(_ record: SlotRecord, now: Date) -> String {
    var details = ["pid \(record.pid)", command(record)]
    if let since = record.startedAt ?? record.waitingSince {
      details.append(duration(now.timeIntervalSince(since)))
    }
    return "\(record.label) (\(details.joined(separator: ", ")))"
  }

  /// `swift test`, `xcodebuild test`. xcodebuild's action is read as `Invocation` reads it, so
  /// an option's value (`-scheme build`) is never taken for it, and no action is its default,
  /// `build`. Anything else shows its first non-option argument.
  public static func command(_ record: SlotRecord) -> String {
    guard let first = record.argv.first else { return record.tool }
    let tool = (first as NSString).lastPathComponent
    let arguments = Array(record.argv.dropFirst())
    if tool == Tool.xcodebuild.rawValue {
      return "\(tool) \(Invocation.xcodebuildAction(arguments))"
    }
    guard let action = arguments.first(where: { !$0.hasPrefix("-") }) else { return tool }
    return "\(tool) \(action)"
  }

  /// `A`, `A and B`, `A, B and C`.
  private static func joined(_ parts: [String]) -> String {
    guard let last = parts.last, parts.count > 1 else { return parts.first ?? "" }
    return parts.dropLast().joined(separator: ", ") + " and " + last
  }
}
