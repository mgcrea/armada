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

  /// The weight of the calendar day `date` falls on. Walking the curve over time,
  /// with the working hours folded in, is `PaceProfile`'s.
  func weight(on date: Date, calendar: Calendar) -> Double {
    values[calendar.component(.weekday, from: date) - 1]
  }
}
