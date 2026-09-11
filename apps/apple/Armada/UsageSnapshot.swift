import Foundation

/// One plan-limit window: how much of it is used, and when it resets.
struct UsageWindow: Sendable, Hashable {
  let utilization: Int
  let resetsAt: Date?
}

/// What `~/.claude.json` says about this account's plan limits.
///
/// **Undocumented, and deliberately decoded as narrowly as possible.**
/// `cachedUsageUtilization` is an internal cache that can change shape in any
/// release — the live object also carries `limit_dollars`, `locked_reason`, a
/// `limits` array, `extra_usage`, `spend` and a dozen code-named windows, none of
/// which this reads. A hand-written `init(from:)` that looks only at the four
/// values it needs is the whole point: an unrelated key changing shape cannot
/// break it, and a missing one degrades to an empty pane rather than a crash.
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
      fetchedAt: fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
    )
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
