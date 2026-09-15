import Foundation

/// When in the day the work happens: one range shared by every day, and one weight for
/// the hours outside it.
///
/// **The day weights alone count 03:00 the same as 15:00**, and that is loudest exactly
/// when pace is most wanted. Five hours into a week that reset at 16:00, the marker
/// measured one working evening against a week of round-the-clock days and called it
/// six points ahead. One range is enough to fix that; a range per weekday would be
/// fourteen more controls for a difference the day weights already carry.
///
/// Whole local hours. An end before the start runs past midnight, so 22 to 2 is a
/// night shift.
nonisolated struct WorkingHours: Sendable, Hashable {
  /// The first working hour, 0…23.
  let start: Int
  /// The hour work stops, 0…23, exclusive: 9 to 17 is eight hours.
  let end: Int
  /// The weight of every hour outside the range, 0…1.
  let outside: Double

  static let defaultsKey = "armada.workingHours"

  /// Every hour the same, which is what pace assumed before this existed. The range
  /// still matters to the settings pane, which shows it as soon as the outside weight
  /// comes down, so it is a plausible working day rather than 0 to 0.
  static let flat = WorkingHours(start: 9, end: 20, outside: 1)
  static let flatStored = "9,20,100"

  init(start: Int, end: Int, outside: Double) {
    self.start = min(max(start, 0), 23)
    self.end = min(max(end, 0), 23)
    self.outside = min(max(outside, 0), 1)
  }

  /// Start hour, end hour and the outside weight in percent: `"9,20,10"`. Anything that
  /// is not three integers lands on `flat`, for the reason `DayWeights.init(stored:)`
  /// gives.
  init(stored: String) {
    let parts = stored.split(separator: ",").map { Int($0) }
    guard parts.count == 3, let start = parts[0], let end = parts[1], let outside = parts[2]
    else {
      self = .flat
      return
    }
    self.init(start: start, end: end, outside: Double(outside) / 100)
  }

  var stored: String { "\(start),\(end),\(Int((outside * 100).rounded()))" }

  /// Nothing to weight: every hour at full weight, or a range with no length.
  var isFlat: Bool { outside == 1 || start == end }

  func weight(hour: Int) -> Double {
    if isFlat { return 1 }
    let inside = start < end ? (start..<end).contains(hour) : (hour >= start || hour < end)
    return inside ? 1 : outside
  }
}

/// Expected effort over time: the day's weight times the hour's.
///
/// **The one place the pace curve is walked.** Both directions, how much effort lies
/// between two instants and when a given amount of it has gone, step from one boundary
/// to the next. A boundary is a local midnight or either end of the working hours, so
/// every segment has a single weight and the answer is exact rather than sampled.
nonisolated struct PaceProfile: Sendable, Hashable {
  let days: DayWeights
  let hours: WorkingHours

  static let even = PaceProfile(days: .even)

  init(days: DayWeights, hours: WorkingHours = .flat) {
    self.days = days
    self.hours = hours
  }

  /// From the two defaults strings, which is how every view holds them.
  init(storedDays: String, storedHours: String) {
    self.init(days: DayWeights(stored: storedDays), hours: WorkingHours(stored: storedHours))
  }

  /// Hours after midnight belong to the calendar day they fall on, so the tail of a
  /// night shift is weighted by the next day.
  func weight(at date: Date, calendar: Calendar) -> Double {
    days.weight(on: date, calendar: calendar)
      * hours.weight(hour: calendar.component(.hour, from: date))
  }

  /// Expected effort between two instants, in weight-seconds.
  ///
  /// Unnormalised on purpose: every caller divides one of these by another, so the
  /// unit cancels and there is no scale to get wrong.
  func consumed(from start: Date, to end: Date, calendar: Calendar) -> Double {
    var total: Double = 0
    var cursor = start
    for next in boundaries(from: start, to: end, calendar: calendar) {
      total += weight(at: cursor, calendar: calendar) * next.timeIntervalSince(cursor)
      cursor = next
    }
    return total
  }

  /// The inverse: when the curve reaches `target` weight-seconds measured from
  /// `start`, or nil if it never does before `limit`.
  ///
  /// Interpolates inside the segment it lands in, so the answer is a time of day. A
  /// zero-weight segment is stepped over rather than divided by: with Sunday at 0, or
  /// nights at 0, the curve is flat there and the crossing belongs to the next
  /// segment that counts.
  func date(reaching target: Double, from start: Date, limit: Date, calendar: Calendar) -> Date? {
    guard target > 0 else { return start }
    var accumulated: Double = 0
    var cursor = start
    for next in boundaries(from: start, to: limit, calendar: calendar) {
      let weight = weight(at: cursor, calendar: calendar)
      let segment = weight * next.timeIntervalSince(cursor)
      if weight > 0, accumulated + segment >= target {
        return cursor.addingTimeInterval((target - accumulated) / weight)
      }
      accumulated += segment
      cursor = next
    }
    return nil
  }

  /// Where each segment ends between `start` and `end`, in order, finishing with `end`
  /// itself. Also what the weekly chart draws the pace line through, so a night
  /// weighted down shows as the flat stretch it is.
  func boundaries(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
    var dates: [Date] = []
    var cursor = start
    while cursor < end {
      let next = min(nextBoundary(after: cursor, calendar: calendar) ?? end, end)
      // A calendar that cannot advance would spin here forever. It cannot happen with
      // a Gregorian calendar and a real date, which is exactly why it is worth one
      // line to make sure it stays impossible.
      guard next > cursor else { break }
      dates.append(next)
      cursor = next
    }
    return dates
  }

  /// The next local midnight, or either end of the working hours, strictly after
  /// `date`.
  ///
  /// Neither is arithmetic on seconds. Midnight is `startOfDay` plus one calendar day,
  /// because on the two days a year the clocks move, plus 86400 lands at 23:00 or 01:00.
  /// The working hours go through `nextDate(matching:)` with `.nextTime`, so an hour
  /// the spring change skips begins at the first instant that does exist, 03:00,
  /// rather than an hour early.
  private func nextBoundary(after date: Date, calendar: Calendar) -> Date? {
    let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    guard !hours.isFlat else { return midnight }
    let edges = [hours.start, hours.end].compactMap {
      calendar.nextDate(
        after: date, matching: DateComponents(hour: $0, minute: 0, second: 0),
        matchingPolicy: .nextTime)
    }
    return (edges + [midnight].compactMap { $0 }).min()
  }
}
