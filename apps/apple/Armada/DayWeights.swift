import Foundation

/// How much of a week's effort each weekday is expected to carry.
///
/// Pace only means something against an expectation, and the flat one is wrong for
/// most people: a linear curve reports "behind pace" every Saturday to someone who
/// does not work weekends, and the warning stops being read by Monday. These are
/// **relative weights, not limits** — they change where the pace marker sits and
/// nothing else, and an even profile is exactly the linear curve.
///
/// Indexed by `Calendar.component(.weekday:)` minus one, so 0 is Sunday. That is
/// Foundation's numbering rather than a local Monday-first convention, because the
/// index is also what gets written to defaults: a second ordering would be one
/// silent off-by-one between the slider and the curve.
nonisolated struct DayWeights: Sendable, Hashable {
  let values: [Double]

  static let defaultsKey = "armada.dayWeights"

  private static let evenValues = [Double](repeating: 1, count: 7)
  static let even = DayWeights(values: evenValues)
  static let evenStored = "100,100,100,100,100,100,100"

  /// Anything that is not seven usable weights degrades to even.
  ///
  /// An all-zero profile is rejected along with a short array: it is a legal thing
  /// to drag every slider to, and it would divide the expected curve by zero.
  init(values: [Double]) {
    let clamped = values.map { max(0, $0) }
    self.values =
      clamped.count == 7 && clamped.contains(where: { $0 > 0 }) ? clamped : Self.evenValues
  }

  /// Seven integer percents, comma-joined — `"25,100,100,50,100,100,25"`.
  ///
  /// A string rather than encoded `Data` so the profile stays readable and fixable
  /// under `defaults read io.mgcrea.armada armada.dayWeights`, and so a value
  /// written by a future version that adds a field cannot fail to decode: anything
  /// unparseable lands on even.
  init(stored: String) {
    self.init(values: stored.split(separator: ",").compactMap { Double($0) }.map { $0 / 100 })
  }

  var stored: String {
    values.map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")
  }

  var isEven: Bool { Set(values).count == 1 }

  func weight(on date: Date, calendar: Calendar) -> Double {
    values[calendar.component(.weekday, from: date) - 1]
  }

  /// Expected effort between two instants, in weight-seconds.
  ///
  /// Unnormalised on purpose: every caller divides one of these by another, so the
  /// unit cancels and there is no scale to get wrong. Walks midnight boundaries —
  /// at most eight segments for a seven-day window — rather than sampling, so a
  /// window that starts at 14:00 gets ten hours of Monday and not a whole day of it.
  func consumed(from start: Date, to end: Date, calendar: Calendar) -> Double {
    guard end > start else { return 0 }
    var total: Double = 0
    var cursor = start
    while cursor < end {
      let segmentEnd = min(Self.nextMidnight(after: cursor, calendar: calendar) ?? end, end)
      // A calendar that cannot advance would spin here forever. It cannot happen
      // with a Gregorian calendar and a real date, which is exactly why it is worth
      // one line to make sure it stays impossible.
      guard segmentEnd > cursor else { break }
      total += weight(on: cursor, calendar: calendar) * segmentEnd.timeIntervalSince(cursor)
      cursor = segmentEnd
    }
    return total
  }

  /// The inverse: when the curve reaches `target` weight-seconds measured from
  /// `start`, or nil if it never does before `limit`.
  ///
  /// Interpolates inside the segment it lands in, so the answer is a time of day
  /// rather than a date. A zero-weight day is skipped rather than divided by — on a
  /// profile with Sunday at 0 the curve is flat all Sunday and the crossing belongs
  /// to Monday morning.
  func date(reaching target: Double, from start: Date, limit: Date, calendar: Calendar) -> Date? {
    guard target > 0 else { return start }
    var accumulated: Double = 0
    var cursor = start
    while cursor < limit {
      let segmentEnd = min(Self.nextMidnight(after: cursor, calendar: calendar) ?? limit, limit)
      guard segmentEnd > cursor else { break }
      let weight = weight(on: cursor, calendar: calendar)
      let segment = weight * segmentEnd.timeIntervalSince(cursor)
      if weight > 0, accumulated + segment >= target {
        return cursor.addingTimeInterval((target - accumulated) / weight)
      }
      accumulated += segment
      cursor = segmentEnd
    }
    return nil
  }

  /// The next midnight strictly after `date`.
  ///
  /// `startOfDay` plus one calendar day rather than plus 86400 seconds: on the two
  /// days a year the clocks move, the arithmetic version lands at 23:00 or 01:00 and
  /// every later segment is misaligned by an hour.
  private static func nextMidnight(after date: Date, calendar: Calendar) -> Date? {
    calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
  }
}
