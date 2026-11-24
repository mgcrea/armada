import SwiftUI

/// A session's build in its row's caption line: `building · 2 min`, `waiting for a slot · 40 s`,
/// `waiting on memory · 40 s`.
///
/// Plain caption text like the project and the other items beside it, not a capsule: a filled
/// shape in that line would outweigh the title above it. It reads the row's selection itself and
/// turns white there, for `SessionRowFigures`' reason: the muted styles all but vanish on the
/// accent-coloured highlight.
struct BuildSlotBadge: View {
  let entry: MonitoredEntry
  let now: Date
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    Text([Self.state(entry), entry.age(at: now)].filter { !$0.isEmpty }.joined(separator: " · "))
      .monospacedDigit()
      .foregroundStyle(
        prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
      )
      .help(entry.slot.map { "\(entry.command), slot \($0)" } ?? entry.command)
  }

  private static func state(_ entry: MonitoredEntry) -> String {
    if entry.isHolding { return "building" }
    return entry.waitsOnMemory ? "waiting on memory" : "waiting for a slot"
  }
}

/// A session's build in its detail pane: `Building  swift test (slot 1, 6 min)`,
/// `Waiting for a slot  swift test (40 s)`.
struct BuildSlotDetailLine: View {
  let entry: MonitoredEntry
  let now: Date

  var body: some View {
    LabeledContent(label, value: detail.isEmpty ? entry.command : "\(entry.command) (\(detail))")
  }

  private var label: String {
    if entry.isHolding { return "Building" }
    return entry.waitsOnMemory ? "Waiting on memory" : "Waiting for a slot"
  }

  private var detail: String {
    let age = entry.age(at: now)
    // As stored, the number the shim prints in "got slot N".
    guard let slot = entry.slot else { return age }
    return age.isEmpty ? "slot \(slot)" : "slot \(slot), \(age)"
  }
}
