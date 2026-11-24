import BuildSlotCore
import Foundation

/// `buildslot status [--json]`: the queue as any reader sees it, with the settings and the
/// memory pressure that decide it. A refused lock folder is reported, with the reason, rather
/// than failing: it is the one thing that silently turns every build unqueued.
enum StatusCommand {
  static func run(json: Bool) -> Int32 {
    let paths = BuildSlotPaths.standard()
    let settings = BuildSlotSettings.load(from: paths.settingsFile)
    let pressure = MemoryPressure.current()
    var state = QueueState(holders: [], waiters: [], freeSlots: Array(0..<settings.slots))
    var problem: String?
    do {
      try paths.ensureDirectories()
      state = QueueReader.read(paths, slotCount: settings.slots)
    } catch {
      problem = "cannot use the lock folder \(paths.lockRoot.path) (\(describe(error)))"
    }

    if json {
      let report = Report(
        settings: settings, pressure: pressure.word,
        holders: state.holders.map(Entry.init), waiters: state.waiters.map(Entry.init),
        problem: problem)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard let data = try? encoder.encode(report) else { return 70 }  // EX_SOFTWARE
      FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
      print(text(settings: settings, pressure: pressure, state: state, problem: problem))
    }
    return 0
  }

  private static func text(
    settings: BuildSlotSettings, pressure: MemoryPressure, state: QueueState, problem: String?
  ) -> String {
    let now = Date.now
    let plural = settings.slots == 1 ? "" : "s"
    var lines = [
      "\(settings.slots) slot\(plural), memory rule \(settings.memoryRule.rawValue), memory "
        + "pressure \(pressure.word)."
    ]
    if let problem { lines.append("Not queueing: \(problem).") }
    var held: [Int: SlotRecord] = [:]
    for holder in state.holders { if let slot = holder.slot { held[slot] = holder.record } }
    let highest = max(settings.slots - 1, held.keys.max() ?? -1)
    if problem == nil {
      for slot in 0...max(highest, 0) {
        let what =
          if let record = held[slot] {
            WaitMessages.describe(record, now: now)
          } else if state.freeSlots.contains(slot) {
            "free"
          } else {
            "busy (its record cannot be read)"
          }
        lines.append("Slot \(slot): \(what)")
      }
    }
    for waiter in state.waiters {
      lines.append("Waiting: \(WaitMessages.describe(waiter.record, now: now))")
    }
    return lines.joined(separator: "\n")
  }

  private struct Report: Encodable {
    var settings: BuildSlotSettings
    var pressure: String
    var holders: [Entry]
    var waiters: [Entry]
    var problem: String?
  }

  /// A record with its slot beside its own fields; a waiter has no slot.
  private struct Entry: Encodable {
    var slot: Int?
    var record: SlotRecord

    init(_ entry: QueueEntry) {
      slot = entry.slot
      record = entry.record
    }

    private enum CodingKeys: String, CodingKey { case slot }

    func encode(to encoder: any Encoder) throws {
      try record.encode(to: encoder)
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(slot, forKey: .slot)
    }
  }
}
