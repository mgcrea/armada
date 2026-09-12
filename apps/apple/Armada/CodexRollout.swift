import Foundation

/// One plan window as Codex reports it.
///
/// Kept beside its `window_minutes` rather than resolved to a name at parse time.
/// Codex's own field names are `primary` and `secondary`, which say nothing about
/// length; the minutes are what actually identify the window, and reading them
/// means a future third window or a changed duration shows up as itself instead of
/// being silently labelled "5 hours".
nonisolated struct CodexWindow: Sendable, Hashable {
  let usage: UsageWindow
  let minutes: Int

  /// Measured on this Mac: 300 and 10080, which are exactly Claude's two windows.
  var length: UsageWindowLength? {
    switch minutes {
    case ...600: .fiveHour
    case ...20160: .sevenDay
    default: nil
    }
  }

  var title: String {
    switch length {
    case .fiveHour: "Session"
    case .sevenDay: "Weekly"
    case nil: "\(minutes) min"
    }
  }

  var subtitle: String {
    switch length {
    case .fiveHour: "5 hours"
    case .sevenDay: "7 days"
    case nil: "\(minutes) minutes"
    }
  }
}

/// The `rate_limits` object carried by every `token_count` event.
///
/// **This is the whole plan-limit story for Codex, and it has no cache file.**
/// Claude Code writes `cachedUsageUtilization` into a document Armada can read at
/// any time; Codex only ever states its limits inside a session log, as a side
/// effect of a turn. So the newest figures are as old as the last turn anyone ran
/// — which is why `observedAt` is not optional here and why the pane leads with it.
nonisolated struct CodexRateLimits: Sendable, Hashable {
  let primary: CodexWindow?
  let secondary: CodexWindow?

  /// `"plus"`, `"pro"`, … — nil on older events. The one piece of account identity
  /// Armada gets without going near `auth.json`.
  let planType: String?

  /// The timestamp of the event this came from, not the file's mtime.
  let observedAt: Date

  var isEmpty: Bool { primary == nil && secondary == nil }

  /// The window of a given length, found by its `window_minutes` rather than by
  /// whether Codex called it `primary` or `secondary`. Those two names say nothing
  /// about duration, and the minutes do.
  func window(_ length: UsageWindowLength) -> UsageWindow? {
    [primary, secondary].compactMap { $0 }.first { $0.length == length }?.usage
  }

  /// These figures in the shape the rest of the app already knows.
  ///
  /// **The reason the Usage pane needed almost no new code.** `WindowRow`,
  /// `WeeklyChart`, `StalenessBadge` and `UsageHistory` all take a `UsageSnapshot`,
  /// and none of them cares which vendor filled it in — so Codex gets the pace line,
  /// the projection, the rolled-window handling and the recorded week for free, and
  /// any later fix to those lands on both vendors at once.
  ///
  /// `limits` is empty on purpose: that array is Claude's per-model breakdown, and
  /// Codex publishes no equivalent. The pane falls back to the two flat windows,
  /// which is exactly the path it already had for a Claude cache without the array.
  var asSnapshot: UsageSnapshot {
    UsageSnapshot(
      fiveHour: window(.fiveHour),
      sevenDay: window(.sevenDay),
      limits: [],
      fetchedAt: observedAt,
      source: .sessionLog)
  }

  var planLabel: String? {
    guard let planType, !planType.isEmpty else { return nil }
    // "plus" → "Plus". Codex sends these lowercase.
    return planType.prefix(1).uppercased() + planType.dropFirst()
  }
}

/// What the head of a rollout says about the session.
nonisolated struct CodexSessionMeta: Sendable, Hashable {
  /// **From `payload.id`, not `payload.session_id`.**
  ///
  /// Those two are the same string on every ordinary thread and *different* on a
  /// spawned one: measured on this Mac, all four `guardian_review` rollouts carry
  /// their own uuid in `id` and their **parent's** uuid in `session_id`, matching
  /// `parent_thread_id` exactly. Reading `session_id` therefore gives a subagent
  /// the identity of the thread that spawned it.
  ///
  /// This is not a cosmetic mix-up. It cost three wrong rows here: SwiftUI's
  /// `List` keys on `Identifiable`, so a subagent sharing its parent's id made the
  /// parent render the child's project and lose its title. The filename's uuid is
  /// `id`, and so is the lock file's name, so the filename is what Armada keys on
  /// and this field only has to agree with it.
  let sessionId: String
  let cwd: String
  let startedAt: Date?
  let originator: String?
  let cliVersion: String?

  /// `"user"`, `"automation"`, `"guardian_review"`. What kind of thing started this.
  let threadSource: String?

  /// Set on a subagent's rollout, naming the session that spawned it. On this Mac
  /// every `guardian_review` thread carries one and every top-level thread has
  /// null, so this is what separates the two without pattern-matching on names.
  let parentThreadId: String?

  /// From the first `turn_context`, which is a few lines further in. Optional: it
  /// is a nicety for the inspector, not something the list depends on.
  let model: String?

  var projectName: String {
    let name = (cwd as NSString).lastPathComponent
    return name.isEmpty ? cwd : name
  }
}

/// What the tail says about where the session got to.
nonisolated struct CodexRolloutTail: Sendable {
  /// The payload type of the newest event — `task_complete` when the turn is done.
  let lastEventType: String?
  let lastEventAt: Date?
  let rateLimits: CodexRateLimits?
  let totalTokens: Int?

  /// Whether a turn appears to be in flight.
  ///
  /// Everything except `task_complete` counts, including a rollout that so far has
  /// only a `session_meta` line: a session that has started and not finished a turn
  /// is running one. This is *not* the guess `TranscriptTitle.isAwaitingToolResult`
  /// has to make on the Claude side — Codex writes both edges of a turn explicitly,
  /// so there is nothing to infer.
  var isTurnRunning: Bool { lastEventType != "task_complete" }
}

/// Reading a Codex rollout without reading a Codex rollout.
///
/// Same discipline as `TranscriptTitle`, for the same reason: rollouts on this Mac
/// run to 2MB and there are 418 of them. Everything works from a bounded head read
/// and a bounded tail read.
///
/// `nonisolated` is load-bearing under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// — without it this file's I/O happens on the thread drawing the window.
nonisolated enum CodexRollout {
  /// The first line alone is ~22KB, because `session_meta` embeds the full system
  /// prompt in `base_instructions.text` (18KB of it). 64KB covers that line plus
  /// the handful after it, which is where `turn_context` sits (line 6 on this Mac).
  static let headBytes = 64 * 1024

  /// Measured across this Mac's rollouts: the last 64KB contained between 1 and 6
  /// `token_count` events in every one of them, so the tail always answers both
  /// questions asked of it. Unlike the Claude side's 64KB tail, which finds what it
  /// is looking for 16% of the time, this needs no full-scan fallback — Codex emits
  /// a `token_count` after every turn rather than once early on.
  static let tailBytes = 64 * 1024

  /// `rollout-2026-09-11T07-01-34-<uuid>.jsonl` → the uuid.
  ///
  /// The filename is the cheap path to a session id: matching a lock file to a
  /// rollout needs no read at all.
  static func sessionId(fromFilename name: String) -> String? {
    guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
    let stem = name.dropFirst("rollout-".count).dropLast(".jsonl".count)
    // The timestamp prefix is fixed-width (`2026-09-11T07-01-34`), and the uuid is
    // the 36 characters after it.
    guard stem.count > 36 else { return nil }
    let id = String(stem.suffix(36))
    return id.count == 36 && id.contains("-") ? id : nil
  }

  static func meta(at url: URL) -> CodexSessionMeta? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: headBytes) else { return nil }

    // The last line of a bounded read is almost certainly truncated; dropping it
    // costs nothing here because what is wanted sits in the first few.
    var lines = head.split(separator: 0x0A, omittingEmptySubsequences: true)
    if lines.count > 1 { lines.removeLast() }

    var meta: CodexSessionMeta?
    var model: String?

    for line in lines {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let type = object["type"] as? String,
        let payload = object["payload"] as? [String: Any]
      else { continue }

      switch type {
      case "session_meta":
        // `id` first. See `CodexSessionMeta.sessionId` for why the order matters.
        guard let sessionId = payload["id"] as? String ?? payload["session_id"] as? String
        else { continue }
        meta = CodexSessionMeta(
          sessionId: sessionId,
          cwd: payload["cwd"] as? String ?? "",
          startedAt: (payload["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp)
            ?? (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp),
          originator: payload["originator"] as? String,
          cliVersion: payload["cli_version"] as? String,
          threadSource: payload["thread_source"] as? String,
          parentThreadId: payload["parent_thread_id"] as? String,
          model: nil
        )
      case "turn_context":
        // Only the first one; a later turn can change the model and the head read
        // cannot see later turns anyway.
        if model == nil { model = payload["model"] as? String }
      default:
        continue
      }
    }

    guard let meta else { return nil }
    guard let model else { return meta }
    return CodexSessionMeta(
      sessionId: meta.sessionId, cwd: meta.cwd, startedAt: meta.startedAt,
      originator: meta.originator, cliVersion: meta.cliVersion,
      threadSource: meta.threadSource, parentThreadId: meta.parentThreadId, model: model)
  }

  static func tail(at url: URL) -> CodexRolloutTail? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let chunk = try? handle.readToEnd() else { return nil }

    var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
    // A tail read starts mid-line unless it started at byte zero.
    if start > 0, !lines.isEmpty { lines.removeFirst() }

    var lastEventType: String?
    var lastEventAt: Date?
    var rateLimits: CodexRateLimits?
    var totalTokens: Int?

    for line in lines.reversed() {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      else { continue }
      let payload = object["payload"] as? [String: Any]
      let at = (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp)

      if lastEventType == nil {
        lastEventType = payload?["type"] as? String ?? object["type"] as? String
        lastEventAt = at
      }

      if rateLimits == nil, payload?["type"] as? String == "token_count" {
        rateLimits = limits(payload?["rate_limits"], observedAt: at ?? lastEventAt ?? .now)
        let info = payload?["info"] as? [String: Any]
        let usage = info?["total_token_usage"] as? [String: Any]
        totalTokens = usage?["total_tokens"] as? Int
      }

      if lastEventType != nil, rateLimits != nil { break }
    }

    guard lastEventType != nil || rateLimits != nil else { return nil }
    return CodexRolloutTail(
      lastEventType: lastEventType, lastEventAt: lastEventAt, rateLimits: rateLimits,
      totalTokens: totalTokens)
  }

  /// Decoded as narrowly as the Claude side decodes its cache, and for the same
  /// reason: the live object also carries `credits`, `individual_limit`,
  /// `spend_control_reached`, `rate_limit_reached_type` and `limit_name`, none of
  /// which this reads. An unrelated key changing shape cannot break it.
  private static func limits(_ value: Any?, observedAt: Date) -> CodexRateLimits? {
    guard let object = value as? [String: Any] else { return nil }
    let limits = CodexRateLimits(
      primary: window(object["primary"]),
      secondary: window(object["secondary"]),
      planType: object["plan_type"] as? String,
      observedAt: observedAt
    )
    return limits.isEmpty ? nil : limits
  }

  /// **`resets_at` here is epoch seconds, an integer.** The Claude side's
  /// `resets_at` is an ISO 8601 string with six fractional digits that needs
  /// `.withFractionalSeconds` to parse at all. Same field name, same meaning,
  /// entirely different type — sharing a parser between the two would be a bug
  /// waiting for whichever vendor changes first.
  ///
  /// `used_percent` is a `Double` (`61.0`), unlike Claude's `Int`. Read as a
  /// `Double` and rounded here rather than cast, because a JSON `61.0` is not an
  /// `Int` to `JSONSerialization` and the cast would quietly produce nil.
  private static func window(_ value: Any?) -> CodexWindow? {
    guard let object = value as? [String: Any],
      let percent = object["used_percent"] as? Double,
      let minutes = object["window_minutes"] as? Int
    else { return nil }
    let resets = (object["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
    return CodexWindow(
      usage: UsageWindow(utilization: Int(percent.rounded()), resetsAt: resets),
      minutes: minutes)
  }
}
