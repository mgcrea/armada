import Foundation

/// A request Anthropic actually refused for hitting a plan limit.
///
/// The one rate-limit fact on this Mac that is not a cache. `cachedUsageUtilization`
/// is a figure Claude Code copies down when it feels like it — measured on
/// 2026-09-11, both config folders' copies were 95 minutes old while sessions in both
/// were running — whereas this is written at the moment of the refusal, by the
/// process it happened to, and it carries the exact instant the window turns over.
///
/// **Rejection-only, and that is the whole of its value and its limit.** There is no
/// running commentary here: one occurrence in a 657-message transcript, and nothing
/// at all in a session that never hit a wall. It cannot say you are at 60%. It can
/// say you are at the end, which is the reading the cache is least able to give and
/// the one that changes what someone does next.
nonisolated struct QuotaHit: Sendable, Hashable {
  /// When the request was refused.
  let at: Date
  /// When the window that refused it turns over.
  let resetsAt: Date
  /// Which window. Nil for a `rateLimitType` this build does not know.
  let length: UsageWindowLength?

  /// Whether this still describes the window someone is in.
  ///
  /// A hit is spent the moment its window rolls: at 13:01 the fact that 12:44 was
  /// refused says nothing about the allowance now. Nothing downstream should show a
  /// rejection past its own reset.
  func isLive(at now: Date) -> Bool { resetsAt > now }
}

/// Reading the refusal out of a transcript.
///
/// `nonisolated` so a background task can call it, which is all that keyword buys —
/// see `TranscriptTitle` for why it does not decide the thread. And tail-only: the
/// files run to 13MB, and nothing here may read a whole one on a write.
///
/// **No full-scan fallback, unlike the titles.** A rejection that has scrolled out
/// of the 64KB tail is a rejection from long enough ago that its window has almost
/// certainly rolled, and `QuotaHit.isLive` would throw it away the moment it
/// arrived. The measured case makes the point: this repo's own session was refused
/// at 10:44 and carried on to 14:10, leaving the record megabytes from the end — and
/// by then that five-hour window had been over for an hour. Paying for a full scan
/// to find something that is discarded on arrival is work for nothing.
nonisolated enum TranscriptQuota {
  /// The newest rejection in a buffer of newline-delimited JSON.
  ///
  /// The record, as written on 2026-09-11:
  ///
  /// ```json
  /// {"type":"assistant","timestamp":"2026-09-11T10:44:34.121Z", …,
  ///  "quotaLimits":{"status":"rejected","resetsAt":1789124400,
  ///    "unifiedRateLimitFallbackAvailable":false,"rateLimitType":"five_hour",
  ///    "overageStatus":"rejected","overageDisabledReason":"org_level_disabled",
  ///    "isUsingOverage":false},"error":"rate_limit","isApiErrorMessage":true}
  /// ```
  ///
  /// Decoded as narrowly as the usage cache is, and for the same reason: this is an
  /// undocumented shape in a file that belongs to another program. Four fields are
  /// read and the rest — the overage trio, the fallback flag — are left alone.
  static func newestHit(inChunk chunk: Data, droppingFirstLine: Bool) -> QuotaHit? {
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      // Cheap reject before paying for a JSON parse, as the title scan does. Almost
      // no line in a transcript carries this key.
      guard line.range(of: Data("quotaLimits".utf8)) != nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let quota = object["quotaLimits"] as? [String: Any],
        // Only an actual refusal. The same object appears with other statuses, and a
        // window that merely reported itself is what the cache is for.
        quota["status"] as? String == "rejected",
        // Seconds since the epoch here, against milliseconds in `fetchedAtMs` two
        // files over. Reading one as the other puts the reset in 1970 or in the
        // year 58000, and neither shows up as an error.
        let resetsAtSeconds = quota["resetsAt"] as? Double,
        let at = (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp)
      else { continue }

      return QuotaHit(
        at: at,
        resetsAt: Date(timeIntervalSince1970: resetsAtSeconds),
        length: length(of: quota["rateLimitType"] as? String))
    }
    return nil
  }

  /// `rateLimitType` names the window in the same vocabulary as the usage cache's
  /// flat keys, so the mapping is the obvious one. An unknown name yields nil rather
  /// than a guess: a hit that cannot be attributed to a window must not be allowed
  /// to correct one.
  private static func length(of rateLimitType: String?) -> UsageWindowLength? {
    switch rateLimitType {
    case "five_hour": .fiveHour
    case "seven_day": .sevenDay
    default: nil
    }
  }
}
