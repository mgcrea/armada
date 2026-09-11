import Foundation

/// Which plan window a forecast is about, and how long it runs.
///
/// The length is not in the data — `cachedUsageUtilization` gives a percentage and a
/// `resets_at` and nothing else — but it is in the key's name, which is the whole
/// reason a forecast needs no history: `start = resets_at - length`, and everything
/// else follows from one snapshot.
nonisolated enum UsageWindowLength: Sendable, Hashable {
  case fiveHour
  case sevenDay

  /// When the window containing `resetsAt` began.
  ///
  /// The weekly one steps back seven *calendar* days rather than 604800 seconds, so
  /// that a window spanning a clock change still starts at the same wall-clock time
  /// it will reset at. The five-hour one is short enough that the distinction cannot
  /// arise.
  func start(before resetsAt: Date, calendar: Calendar) -> Date? {
    switch self {
    case .fiveHour: resetsAt.addingTimeInterval(-5 * 3600)
    case .sevenDay: calendar.date(byAdding: .day, value: -7, to: resetsAt)
    }
  }

  /// Only the weekly window is weighted.
  ///
  /// A five-hour window sits inside one day, so there is no weekday to weight it by;
  /// the analogous idea would be an hours-of-day profile, which is a second settings
  /// section to buy a marker on a bar that resets four times a working day.
  var isWeighted: Bool { self == .sevenDay }
}

/// What a plan window is on course to do before it resets.
///
/// **Everything here is arithmetic on one snapshot.** Given `resets_at` and the
/// window's length, the elapsed share of the window is known, and a percentage
/// against it gives pace, a projection, an exhaustion time and the share that will
/// go unspent. No history is involved, so this works on the first launch.
///
/// The value of that is also the risk: the arithmetic is happy to produce a
/// confident number from a reading that cannot support one. `init` returns nil in
/// the four cases below rather than letting the caller decide, because a forecast
/// that is merely *shown less prominently* is still a forecast someone will act on.
nonisolated struct UsageForecast: Sendable, Hashable {
  /// The share of the window's expected effort that had elapsed at `asOf`, 0…1.
  let expected: Double
  /// The share of the allowance spent at `asOf`, 0…1 (and beyond, in principle).
  let used: Double
  /// Where the window lands at reset if the current rate holds. 1.0 is the limit.
  let projected: Double
  let resetsAt: Date
  /// When the allowance runs out, if it is on course to. Nil when it is not.
  let exhaustsAt: Date?
  let length: UsageWindowLength

  /// Percentage points ahead of (positive) or behind (negative) the pace marker.
  var deltaPoints: Double { (used - expected) * 100 }

  /// Percentage points that will go unspent at this rate — allowance that does not
  /// carry over and is simply lost at the reset.
  ///
  /// Only meaningful on the weekly window, which is a budget. The five-hour window
  /// is a rate limiter: it resets mostly unspent on any normal day, that is what it
  /// is for, and there is nothing to bank. See `verdict`, which never reports it.
  var forfeitPoints: Double { max(0, (1 - projected) * 100) }

  /// Below this share of the window elapsed, `used / expected` is noise: at 2%
  /// elapsed a single expensive prompt projects past 400%. Ten percent of a
  /// five-hour window is half an hour, which is about when the ratio settles.
  static let minimumElapsed = 0.10

  /// How old the reading may be, as a share of the window it describes.
  ///
  /// **Proportional, not a flat hour, and that is the whole point.** Because
  /// `expected` is measured to `asOf` rather than to `now`, a stale reading still
  /// yields an arithmetically sound rate for the period it actually covers. What
  /// staleness costs is knowledge of what happened *since* — and an hour is a fifth
  /// of a five-hour window but under one percent of a seven-day one.
  ///
  /// A flat hour was tried first and made the feature invisible: measured on this Mac
  /// on 2026-09-11, both folders' caches were an hour or more old at the same moment,
  /// with one of them driving a session that was talking to the API continuously. The
  /// cache simply does not refresh on the cadence a flat threshold assumes. Same 10%
  /// as `minimumElapsed`, at the other end of the window.
  static let staleFraction = 0.10

  /// Points ahead of pace before it is worth a caption.
  static let significantDelta = 8.0

  /// Points of forfeit worth warning about, and how close the reset has to be.
  static let significantForfeit = 25.0
  static let forfeitHorizon: TimeInterval = 24 * 60 * 60

  /// - Parameters:
  ///   - asOf: when the percentage was true — `UsageSnapshot.fetchedAt`, never
  ///     `now`. The figure is a cache written on the API's cadence, so measuring
  ///     elapsed time to the present stretches the denominator by the cache's age
  ///     and reports a slower rate than the real one.
  init?(
    window: UsageWindow,
    length: UsageWindowLength,
    weights: DayWeights,
    asOf: Date?,
    now: Date,
    calendar: Calendar = .current
  ) {
    guard let resetsAt = window.resetsAt, let asOf else { return nil }

    // The window has already rolled. Observed on 2026-09-10: `~/.claude`'s
    // `five_hour` reset at 23:00:00.431Z and the cache was written at 23:02:37Z, so
    // the 17% it carried belonged to a window that no longer existed.
    guard resetsAt > asOf, resetsAt > now else { return nil }

    guard let start = length.start(before: resetsAt, calendar: calendar), asOf > start
    else { return nil }

    let span = resetsAt.timeIntervalSince(start)
    guard now.timeIntervalSince(asOf) <= span * Self.staleFraction else { return nil }

    let profile = length.isWeighted ? weights : .even
    let total = profile.consumed(from: start, to: resetsAt, calendar: calendar)
    guard total > 0 else { return nil }

    let expected = profile.consumed(from: start, to: asOf, calendar: calendar) / total
    guard expected >= Self.minimumElapsed else { return nil }

    let used = Double(window.utilization) / 100
    let projected = used / expected

    self.expected = expected
    self.used = used
    self.projected = projected
    self.resetsAt = resetsAt
    self.length = length
    // The curve reaches the limit at the weighted fraction `expected / used`, which
    // is inside the window exactly when the projection is over it.
    self.exhaustsAt =
      projected > 1
      ? profile.date(
        reaching: total * (expected / used), from: start, limit: resetsAt, calendar: calendar)
      : nil
  }

  /// The one thing worth saying about this window, or nothing.
  ///
  /// A single verdict rather than every true statement: the caption sits under a
  /// meter in a 280pt popover and a header strip, and "12 points ahead of pace,
  /// projected 147%, resets Monday" is three facts nobody finishes reading. Ordered
  /// by what changes a decision — running out first, then drifting, then wasting.
  enum Verdict: Sendable, Hashable {
    case exhausting(Date)
    case ahead(Double)
    case forfeiting(Double)
    case onPace
  }

  var verdict: Verdict {
    if let exhaustsAt { return .exhausting(exhaustsAt) }
    if deltaPoints > Self.significantDelta { return .ahead(deltaPoints) }
    // Weekly only, and only once the reset is close enough to be the last word on
    // it. A five-hour window reports 40 points unspent most of the time — true,
    // useless, and said so often it would teach people to stop reading the line.
    if length == .sevenDay, forfeitPoints > Self.significantForfeit,
      resetsAt.timeIntervalSinceNow <= Self.forfeitHorizon
    {
      return .forfeiting(forfeitPoints)
    }
    return .onPace
  }

  /// Whether this is worth interrupting someone with — the popover shows a caption
  /// only for these, because "on pace" in a menu is a line of chrome.
  var isNoteworthy: Bool { verdict != .onPace }
}
