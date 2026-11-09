import Foundation

/// One reading of an account's windows, at the moment Claude Code took it.
///
/// Short keys because this file is appended to for as long as the app is installed
/// and every byte is repeated per sample. `t` is the cache's `fetchedAt`, never the
/// time Armada noticed it — that is what makes the same sample recognisable across
/// launches, and what the dedupe in `UsageHistory` compares.
nonisolated struct UsageSample: Codable, Sendable, Hashable {
  let t: Date
  /// Five-hour and seven-day percentages. Optional because a window can be absent
  /// from the cache, and a sample missing one should not be a sample missing both.
  let h: Int?
  let w: Int?
}

/// What the week's chart draws from the recorded history, and when it has to draw again.
///
/// **Why it exists.** The cache is read about every two minutes, so a week is five thousand
/// samples, and the chart is a few hundred points wide. Swift Charts laid out a monotone
/// `LineMark` for every one of them, and the account pane re-renders every second for its
/// session rows' clocks: measured 2026-11-09, that was most of Armada's idle CPU with one
/// account window open.
nonisolated enum UsageChartSeries {
  /// One reading per quarter hour: 672 a week, finer than the chart can show.
  static let bucket: TimeInterval = 15 * 60

  /// The first sample, then the latest in each `bucket`, oldest first.
  ///
  /// **The latest, not an average**, so every point drawn is a reading that was taken, and
  /// the last one is the reading the projection starts from. The first is kept as well so the
  /// line still starts where the cycle's record does.
  static func thin(_ samples: [UsageSample], bucket: TimeInterval = bucket) -> [UsageSample] {
    guard samples.count > 2 else { return samples }
    var kept = [samples[0]]
    var current = slot(samples[0].t, bucket)
    var latest = samples[0]
    for sample in samples.dropFirst() {
      let next = slot(sample.t, bucket)
      if next != current {
        if latest != kept.last { kept.append(latest) }
        current = next
      }
      latest = sample
    }
    if latest != kept.last { kept.append(latest) }
    return kept
  }

  /// `date` floored to its minute: what the chart's inputs are compared by, so a clock
  /// ticking every second redraws it once a minute.
  static func minute(_ date: Date) -> Date {
    Date(
      timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
    )
  }

  private static func slot(_ date: Date, _ bucket: TimeInterval) -> Int {
    Int((date.timeIntervalSinceReferenceDate / bucket).rounded(.down))
  }
}
