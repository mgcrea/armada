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
/// There is no supported alternative. `docs/limits-accounts-and-terms.md` checked:
/// the documented status-line JSON almost certainly never runs under the VS Code
/// extension, and the Admin API does not cover Pro/Max 5-hour and 7-day windows.
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

  var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

  static func read(from url: URL) -> UsageSnapshot? {
    guard let root = ClaudeConfigDocument.read(url) else { return nil }
    return decode(root: root)
  }

  static func decode(root: [String: Any]) -> UsageSnapshot? {
    guard let cached = root["cachedUsageUtilization"] as? [String: Any] else { return nil }

    let utilization = cached["utilization"] as? [String: Any] ?? [:]
    let fetchedAtMs = cached["fetchedAtMs"] as? Double

    return UsageSnapshot(
      fiveHour: window(utilization["five_hour"]),
      sevenDay: window(utilization["seven_day"]),
      limits: limits(utilization["limits"]),
      fetchedAt: fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
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
