import Foundation

/// One plan-limit window: how much of it is used, and when it resets.
///
/// `nonisolated` for the same reason `UsageSnapshot` is: the project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this pure value type
/// is main-actor isolated and cannot be read by the nonisolated types that hold one
/// — `UsageLimit` here, and the forecast arithmetic in `UsageForecast`.
nonisolated struct UsageWindow: Sendable, Hashable {
  let utilization: Int
  let resetsAt: Date?

  /// Set when this reading came from a refused request rather than from the vendor's
  /// own cached figure. Display only — see `UsageSnapshot.window(_:correctedBy:now:)`.
  var rejectedAt: Date?

  /// The reset has passed, so `utilization` describes a window that no longer exists.
  ///
  /// **Takes `now` rather than reading `Date.now`.** Every caller is a SwiftUI body,
  /// and a body that reads the clock directly is only correct at the instant it was
  /// last evaluated — which is how the menu bar popover came to show a 99% meter for
  /// a window that had rolled over an hour earlier. Threading the pane's tick in
  /// makes the staleness impossible to draw by accident.
  func hasRolled(asOf now: Date) -> Bool { resetsAt.map { $0 < now } ?? false }
}

/// One entry of the cache's `limits` array.
///
/// The same numbers as `five_hour` and `seven_day` arrive a second time in this
/// array, with three things the flat keys do not carry: `is_active` (which window is
/// currently the binding one), `severity` (the vendor's own escalation, `"normal"`
/// on both folders here), and `scope`, which is how a per-model window appears —
/// `weekly_scoped` for Fable, 16%, on this Mac on 2026-09-11.
///
/// Read for the Usage pane only. The header strip keeps using the two flat keys,
/// because this array is a newer shape in the same undocumented cache and the strip
/// should not start failing the day its name changes.
nonisolated struct UsageLimit: Sendable, Hashable, Identifiable {
  let kind: String
  let group: String
  let percent: Int
  let resetsAt: Date?
  let severity: String?
  let isActive: Bool
  /// `scope.model.display_name` — "Fable". Nil for an unscoped window.
  let scopeModelName: String?

  /// Stable across refreshes: the shape of the array is fixed and a scoped entry is
  /// identified by its model, so this survives the list being rebuilt every 30s.
  var id: String { "\(kind)-\(scopeModelName ?? "")" }

  /// How long this window runs, inferred from `group` rather than `kind` — `kind`
  /// distinguishes `weekly_all` from `weekly_scoped`, which are both seven days.
  var length: UsageWindowLength? {
    switch group {
    case "session": .fiveHour
    case "weekly": .sevenDay
    default: nil
    }
  }

  var window: UsageWindow { UsageWindow(utilization: percent, resetsAt: resetsAt) }

  var title: String {
    if let scopeModelName { return scopeModelName }
    return group == "session" ? "Session" : "Weekly"
  }

  var subtitle: String {
    switch length {
    case .fiveHour: "5 hours"
    case .sevenDay: scopeModelName == nil ? "7 days" : "7 days, this model"
    case nil: kind
    }
  }
}

/// What `~/.claude.json` says about this account's plan limits.
///
/// **Undocumented, and deliberately decoded as narrowly as possible.**
/// `cachedUsageUtilization` is an internal cache that can change shape in any
/// release — the live object also carries `limit_dollars`, `locked_reason`,
/// `extra_usage`, `spend` and a dozen code-named windows, none of which this reads.
/// A hand-written decode that looks only at the values it needs is the whole point:
/// an unrelated key changing shape cannot break it, and a missing one degrades to an
/// empty pane rather than a crash.
///
/// `limits` is read as of 2026-09-11, for the per-model windows the flat keys cannot
/// express, but it is read *additively* — see `UsageLimit`. The dollar fields stay
/// unread because they are `null` on every window of both folders on this Mac;
/// nothing here should be built on a figure that has never been observed.
///
/// **No longer the primary source.** `UsageProbe` asks the account directly, the way
/// the VS Code extension does, and this is the fallback behind it — for a Mac where
/// `claude` cannot be found, and for `oauthAccount`, which the probe does not carry.
/// It is still read on every poll, and still the thing that must never be shown
/// without its age: see `UsageSnapshot.Source`.
///
/// **Per organization, not per person.** The two config folders on this Mac are
/// one Anthropic account in two organizations, and they carry entirely separate
/// figures — 17%/69% against 4%/8%. A snapshot belongs to a folder, and there is
/// no meaningful way to add two of them together.
nonisolated struct UsageSnapshot: Sendable, Hashable {
  let fiveHour: UsageWindow?
  let sevenDay: UsageWindow?

  /// Every window the cache lists, including the per-model ones the two flat keys
  /// above cannot express. Empty when the array is missing or unreadable.
  let limits: [UsageLimit]

  /// When Claude Code last refreshed the cache.
  ///
  /// Surfaced rather than swallowed. This is a *cache* written on an unpredictable
  /// cadence tied to API responses, so a six-hour-old figure rendered as current
  /// truth is the one way this feature can actively mislead.
  let fetchedAt: Date?

  /// Which of the two readings this is.
  ///
  /// Both carry a `fetchedAt`, but it means something different in each, and the UI
  /// has to say which. A `.live` figure was asked for and answered a second ago; a
  /// `.cache` figure is a copy Claude Code left behind whenever it last felt like it,
  /// and its age is a warning rather than a timestamp.
  var source: Source = .cache

  nonisolated enum Source: Sendable, Hashable {
    /// `get_usage`, answered by the user's own `claude`. See `UsageProbe`.
    case live
    /// `cachedUsageUtilization` in `.claude.json`.
    case cache
  }

  var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

  /// One window, with a rate-limit refusal allowed to overrule the cached figure.
  ///
  /// **Three conditions, all of them narrow, because overruling the vendor's own
  /// number is not something to do on a hunch.** The hit must name this window, it
  /// must be newer than the cache it is correcting, and its own window must not have
  /// rolled yet. Miss any one and the cached figure stands untouched.
  ///
  /// When all three hold, the refusal is simply better evidence. The cache says what
  /// Claude Code last copied down; the refusal says the API turned a request away
  /// just now, which means the window is spent whatever the older figure claims.
  /// Measured on 2026-09-11: the cache read 26% while a session in the same folder
  /// had been refused eight minutes later — the correction is the difference between
  /// a green bar and the truth.
  ///
  /// `resets_at` comes from the hit too, not from the cache. They are the same
  /// instant when both are current, and when they disagree the fresher one is the
  /// one that has not been overtaken by a rollover.
  func window(_ length: UsageWindowLength, correctedBy hit: QuotaHit?, now: Date)
    -> UsageWindow?
  {
    let cached = length == .fiveHour ? fiveHour : sevenDay
    guard let hit, hit.length == length, hit.isLive(at: now),
      hit.at > (fetchedAt ?? .distantPast)
    else { return cached }
    return UsageWindow(utilization: 100, resetsAt: hit.resetsAt, rejectedAt: hit.at)
  }

  static func read(from url: URL) -> UsageSnapshot? {
    guard let root = ClaudeConfigDocument.read(url) else { return nil }
    return decode(root: root)
  }

  static func decode(root: [String: Any]) -> UsageSnapshot? {
    guard let cached = root["cachedUsageUtilization"] as? [String: Any] else { return nil }
    return decode(
      windows: cached["utilization"] as? [String: Any] ?? [:],
      // Milliseconds here. `QuotaHit` reads seconds out of a transcript two files
      // over, which is the kind of thing that is silent when got wrong.
      fetchedAt: (cached["fetchedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
      source: .cache)
  }

  /// The one decoder both sources go through.
  ///
  /// `cachedUsageUtilization.utilization` and the `rate_limits` object `get_usage`
  /// answers with are **the same shape** — same `five_hour`/`seven_day` objects, same
  /// `limits` array — which is the single reason adding a live source cost no new
  /// parsing. Keeping one function is what holds that true: a field that moves breaks
  /// both paths at once rather than leaving one of them quietly wrong.
  static func decode(windows: [String: Any], fetchedAt: Date?, source: Source) -> UsageSnapshot {
    UsageSnapshot(
      fiveHour: window(windows["five_hour"]),
      sevenDay: window(windows["seven_day"]),
      limits: limits(windows["limits"]),
      fetchedAt: fetchedAt,
      source: source
    )
  }

  /// Skips any entry it cannot read rather than failing the array, so one new
  /// `kind` with an unexpected shape costs its own row and not the pane.
  private static func limits(_ value: Any?) -> [UsageLimit] {
    guard let array = value as? [[String: Any]] else { return [] }
    return array.compactMap { entry in
      guard let kind = entry["kind"] as? String,
        let group = entry["group"] as? String,
        let percent = entry["percent"] as? Int
      else { return nil }
      let scope = entry["scope"] as? [String: Any]
      let model = scope?["model"] as? [String: Any]
      return UsageLimit(
        kind: kind,
        group: group,
        percent: percent,
        resetsAt: (entry["resets_at"] as? String).flatMap(parseTimestamp),
        severity: entry["severity"] as? String,
        isActive: entry["is_active"] as? Bool ?? false,
        scopeModelName: model?["display_name"] as? String
      )
    }
  }

  private static func window(_ value: Any?) -> UsageWindow? {
    guard let object = value as? [String: Any],
      let utilization = object["utilization"] as? Int
    else { return nil }
    return UsageWindow(
      utilization: utilization,
      resetsAt: (object["resets_at"] as? String).flatMap(parseTimestamp)
    )
  }

  /// Parse a `resets_at`.
  ///
  /// **`.withFractionalSeconds` is load-bearing.** The real value is
  /// `"2026-09-10T23:00:00.431496+00:00"` — six fractional digits and a numeric
  /// offset — and a bare `ISO8601DateFormatter()` returns nil on it. Compiled and
  /// run against the live string to confirm. The failure is silent: the percentage
  /// still renders and the reset time simply never appears.
  ///
  /// The plain formatter is kept as a fallback in case a future release drops the
  /// fractional part, which the first parser would then refuse.
  static func parseTimestamp(_ string: String) -> Date? {
    withFractional.date(from: string) ?? plain.date(from: string)
  }

  private static let withFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plain = ISO8601DateFormatter()
}
