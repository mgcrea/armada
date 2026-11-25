import Foundation

/// The build-slot queue as marks beside the menu bar glyph: a filled dot per build running, a
/// ring per build waiting, `●●○`.
///
/// **Five marks at most, then a `+`.** Slots go up to eight and waiters have no bound, and a row
/// of a dozen dots is a number nobody reads at a glance; past five the exact count is one click
/// away, in the panel's `Build slots 2/2 · 4 waiting`. Running builds are drawn first, so a full
/// row of filled dots still says the slots are busy.
///
/// **One ring for both kinds of wait.** Waiting for a slot and waiting on memory are a
/// distinction the panel and Settings make; at 4.5pt it would be a third glyph to learn.
///
/// Nothing at all while the queue is empty, rather than a reserved gap: the status item grows
/// when a build starts and shrinks back when it ends, and that is the price of an idle menu bar
/// that looks as it always did.
nonisolated struct MenuBarBuilds: Hashable, Sendable {
  static let defaultsKey = "armada.menuBarBuilds"
  static let shownByDefault = true
  static let maxMarks = 5

  let running: Int
  let waiting: Int

  init(running: Int, waiting: Int) {
    self.running = max(running, 0)
    self.waiting = max(waiting, 0)
  }

  var isEmpty: Bool { running == 0 && waiting == 0 }

  /// Filled dots.
  var filled: Int { min(running, Self.maxMarks) }
  /// Rings, after the filled dots and within the cap.
  var rings: Int { min(waiting, Self.maxMarks - filled) }
  /// Whether a `+` follows the marks.
  var overflows: Bool { running + waiting > Self.maxMarks }

  /// What the marks draw, which is all the image cache needs to tell two apart: `3|2|+`.
  var marksKey: String { "\(filled)|\(rings)|\(overflows ? "+" : "")" }

  /// "2 builds running, 1 waiting", for VoiceOver. Nil while nothing is queued.
  var spoken: String? {
    let builds = { (count: Int) in count == 1 ? "1 build" : "\(count) builds" }
    switch (running, waiting) {
    case (0, 0): return nil
    case (_, 0): return "\(builds(running)) running"
    case (0, _): return "\(builds(waiting)) waiting"
    default: return "\(builds(running)) running, \(waiting) waiting"
    }
  }
}
