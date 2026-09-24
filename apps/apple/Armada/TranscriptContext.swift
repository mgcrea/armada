import Foundation

/// How full a session's context window is, read out of its transcript.
///
/// **This is not `/context`, and the difference is the point.** Claude Code builds
/// that breakdown live, in the running process, from artifacts it never writes down:
/// the system prompt text and the contents of every CLAUDE.md are assembled into the
/// API system block and thrown away. Measured on 2026-09-12 against 2.1.267 — no
/// line of any transcript, and no file under `~/.claude`, carries a per-category
/// token count.
///
/// What *is* recorded is better than it sounds. Every `assistant` entry carries
/// `message.usage`, and `input_tokens + cache_creation_input_tokens +
/// cache_read_input_tokens` is the whole prompt — the same sum Claude Code's own
/// status line calls `total_input_tokens`. So the total is exact, the cache split is
/// exact, and only the *composition* of the fixed prefix is out of reach.
///
/// The exact breakdown does exist over the SDK control protocol, as
/// `get_context_usage`. It is unreachable from here: that request is answered by
/// whoever owns the session's stdin and stdout, which is VS Code, and the only other
/// way in is Claude's Remote Control bridge. See `docs/claude-code-sessions.md`.
nonisolated struct ContextReading: Sendable, Hashable {
  /// The whole prompt: fresh input, plus what was written into the cache this turn,
  /// plus what was read back from it. **All three, always.** `input_tokens` alone is
  /// near-zero on a warm turn — 2, on a 389k prompt — so reading any one of these as
  /// "the context" reports an empty session.
  let total: Int
  /// The warm prefix: everything the API found already cached.
  let cacheRead: Int
  /// Written into the cache on this turn — roughly, what is new since the last one.
  let cacheCreation: Int
  /// Uncached input. Small by construction on a session with a warm prefix.
  let freshInput: Int
  let output: Int
  /// `message.model`, e.g. `claude-opus-5`. **Never carries the `[1m]` suffix**, so
  /// it cannot by itself say whether this is a 200k or a 1M session. See
  /// `ContextWindow`.
  let modelID: String?
  let at: Date?
  /// Which cache this turn wrote into, from `usage.cache_creation`. Nil on a turn that
  /// wrote nothing, on a transcript too old to split the write, and always for Codex
  /// and Grok, whose logs never say how long their caches live.
  var cacheTTL: PromptCacheTTL? = nil
}

/// Reading context out of a transcript.
///
/// `nonisolated` so the detached deep scan can call it at all under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. As `TranscriptTitle` spells out, that
/// lifts the main-actor default and nothing more: which thread parses a 50MB buffer is
/// decided by the caller, and `SessionWatcher` decides it.
///
/// **Takes a buffer, never a URL.** `SessionWatcher.refreshTitle` already reads one
/// 64KB tail per transcript write and hands it to two parsers; this is the third.
/// Adding a `…(at:)` entry point here would quietly double the I/O of every write,
/// which is the exact mistake `TranscriptTitle.tail(of:)` was extracted to prevent.
nonisolated enum TranscriptContext {
  /// The newest assistant entry's usage.
  ///
  /// No `apiBlockIndex` filtering, deliberately: every block of one `requestId`
  /// repeats the same `usage` object, so the newest block and the newest request
  /// agree about the total. Only `series(…)` below has to care.
  static func newestReading(inChunk chunk: Data, droppingFirstLine: Bool) -> ContextReading? {
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      if let reading = reading(fromLine: line) { return reading }
    }
    return nil
  }

  /// The readings in this buffer, oldest first, one per API request.
  ///
  /// **Filtered to `apiBlockIndex == 0`, and that filter is load-bearing.** One
  /// request emits two or three entries carrying an identical `usage` object; left
  /// unfiltered, the series counts a single request several times and reports a
  /// growth rate two thirds too low. Measured on the last six requests of a 50MB
  /// session: 379344 → 383213 → 384317 → 386716 → 388217 → 389013, monotonic, about
  /// 1.9k per request.
  static func series(inChunk chunk: Data, droppingFirstLine: Bool) -> [ContextReading] {
    JSONLines.oldestFirst(chunk, droppingFirstLine: droppingFirstLine).compactMap {
      reading(fromLine: $0, firstBlockOnly: true)
    }
  }

  /// The model id as the session itself recorded it, with the `[1m]` suffix intact.
  ///
  /// An `attachment` entry shaped
  /// `{"type":"model","identity":{"modelId":"claude-opus-5[1m]","marketingName":"Opus 5 (1M context)"}}`.
  /// This is the only structured place the variant suffix appears, and it is the
  /// difference between a 200k window and a 1M one.
  ///
  /// **Usually absent, and that is normal rather than a failure.** Present in 10 of
  /// 60 transcripts sampled on 2026-09-12, and missing entirely from the largest file
  /// on the machine. Treat it as a bonus and fall back — `ContextWindow` does.
  ///
  /// Newest wins, as with `ai-title`: a session that ran `/model` writes another one.
  static func newestModelID(inChunk chunk: Data, droppingFirstLine: Bool) -> String? {
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      // Cheap reject before paying for a JSON parse, as every other parser here
      // does. Almost no line carries this key.
      guard line.range(of: Data("\"modelId\"".utf8)) != nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        object["type"] as? String == "attachment",
        let attachment = object["attachment"] as? [String: Any],
        attachment["type"] as? String == "model",
        let identity = attachment["identity"] as? [String: Any],
        let modelID = identity["modelId"] as? String, !modelID.isEmpty
      else { continue }
      return modelID
    }
    return nil
  }

  /// One assistant entry's usage, or nil for every other kind of line.
  static func reading(fromLine line: Data, firstBlockOnly: Bool = false) -> ContextReading? {
    // Cheap reject first: most lines in a transcript are not assistant turns.
    guard line.range(of: Data("\"usage\"".utf8)) != nil,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "assistant",
      let message = object["message"] as? [String: Any],
      let usage = message["usage"] as? [String: Any]
    else { return nil }

    if firstBlockOnly, let block = object["apiBlockIndex"] as? Int, block != 0 { return nil }

    // Absent rather than zero is the failure case worth guarding: a shape change
    // that drops these keys would otherwise render as a session with no context.
    guard let input = usage["input_tokens"] as? Int,
      let cacheCreation = usage["cache_creation_input_tokens"] as? Int,
      let cacheRead = usage["cache_read_input_tokens"] as? Int
    else { return nil }

    return ContextReading(
      total: input + cacheCreation + cacheRead,
      cacheRead: cacheRead,
      cacheCreation: cacheCreation,
      freshInput: input,
      output: usage["output_tokens"] as? Int ?? 0,
      modelID: message["model"] as? String,
      at: (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp),
      cacheTTL: (usage["cache_creation"] as? [String: Any]).flatMap(PromptCacheTTL.init))
  }
}

/// How long a prompt-cache write stays warm: Anthropic's two ephemeral lifetimes.
///
/// **Read, not guessed.** Every assistant turn splits `cache_creation_input_tokens`
/// into `cache_creation.ephemeral_5m_input_tokens` and `…ephemeral_1h_input_tokens`,
/// so the transcript says which lifetime the session is on. Measured on 2026-09-24
/// against a subscription account: every write was 1h, with 5m always 0.
nonisolated enum PromptCacheTTL: Sendable, Hashable {
  case fiveMinutes
  case oneHour

  var duration: TimeInterval {
    switch self {
    case .fiveMinutes: 5 * 60
    case .oneHour: 60 * 60
    }
  }

  /// **The shorter lifetime wins when a turn wrote to both.** The 5m part is the newest
  /// end of the prompt, and once it lapses the next turn re-writes everything after the
  /// point it starts, so the long-lived part surviving is little consolation.
  ///
  /// Nil when the turn wrote nothing: a full cache hit says nothing about which
  /// lifetime the prefix was written with.
  init?(cacheCreation: [String: Any]) {
    if cacheCreation["ephemeral_5m_input_tokens"] as? Int ?? 0 > 0 {
      self = .fiveMinutes
    } else if cacheCreation["ephemeral_1h_input_tokens"] as? Int ?? 0 > 0 {
      self = .oneHour
    } else {
      return nil
    }
  }
}

/// Whether a session's prompt cache is still warm, and until when.
///
/// **An upper bound, never a promise.** Every request that hits the cache resets its
/// clock, so the expiry is the newest request plus the lifetime — but Anthropic may
/// evict sooner, and the transcript records a turn when its response is written, not
/// when the request that refreshed the cache went out. A long response therefore makes
/// the real expiry a little earlier than this one, which is why the UI prefixes it `~`.
///
/// What going cold costs is the whole prompt: the next turn writes it all back into the
/// cache, at 1.25× the input price for 5m and 2× for 1h, where a warm turn reads it at
/// 0.1×. On a subscription that is spent from the same limits the usage panes show.
nonisolated struct PromptCache: Sendable, Hashable {
  let ttl: PromptCacheTTL
  let lastRequest: Date
  /// The prompt the next turn re-writes if the cache has lapsed.
  let tokens: Int

  var expiresAt: Date { lastRequest.addingTimeInterval(ttl.duration) }

  func isWarm(at now: Date) -> Bool { now < expiresAt }

  /// Warm, with a quarter of its lifetime or less to go: the last 15 minutes of an hour,
  /// the last 75 seconds of five minutes. Late enough that a busy fleet is not lit up
  /// with warnings, early enough to get back to the session in time.
  func isExpiringSoon(at now: Date) -> Bool {
    isWarm(at: now) && expiresAt.timeIntervalSince(now) <= ttl.duration / 4
  }
}

/// What a session was carrying before its first prompt.
///
/// The honest analogue of the top rows of `/context` — system prompt, system tools,
/// MCP tools, memory files and skills — **as one figure**, because the transcript
/// records their sum and not their parts. 47.9k on the session this was measured
/// against, which is the kind of number worth seeing before deciding a session is
/// merely "a bit full".
///
/// Read from the head of the file, once. It cannot change: nothing rewrites a
/// session's first turn.
nonisolated struct ContextBaseline: Sendable, Hashable {
  /// The first assistant turn's total prompt.
  let loadedAtStart: Int
}

/// A compaction that happened in this session.
///
/// `postTokens` is absent on some records — it was missing from the one compaction
/// found on this Mac, whose `compactMetadata` carried `trigger`, `preTokens`,
/// `durationMs` and `preCompactDiscoveredTools` and no post figure. Optional rather
/// than defaulted to zero, so the UI can say "compacted" without inventing a number.
nonisolated struct Compaction: Sendable, Hashable {
  /// `manual` for `/compact`, otherwise Claude Code's own trigger.
  let trigger: String?
  let preTokens: Int?
  let postTokens: Int?
  let at: Date?

  var wasManual: Bool { trigger == "manual" }
}

// `nonisolated` like the type it extends: under main-actor default isolation an
// extension does not inherit that from its type, and both of these run in the deep scan.
nonisolated extension TranscriptContext {
  /// The opening reading, from a head buffer.
  ///
  /// **A session shorter than `headBytes` hands the same entry to this and to
  /// `newestReading`,** and that is correct rather than a bug: a session one turn old
  /// has grown by nothing, and the derived "added since" row is legitimately zero.
  static func baseline(inChunk chunk: Data) -> ContextBaseline? {
    for line in JSONLines.oldestFirst(chunk, droppingFirstLine: false) {
      if let reading = reading(fromLine: line) {
        return ContextBaseline(loadedAtStart: reading.total)
      }
    }
    return nil
  }

  /// The newest compaction in a buffer.
  ///
  /// **Needs the whole file, not a tail.** Measured across 40 transcripts over 500KB
  /// on 2026-09-12: only 4 had compacted at all, and the newest boundary sat between
  /// 160KB and 8.7MB from the end — outside any tail worth reading on a write. So
  /// this rides the once-per-session deep scan, which already reads the file whole.
  ///
  /// A compaction that happens *after* that scan is still caught, without re-reading
  /// anything: it is the only thing that makes the running total fall between turns,
  /// and both turns are in the tail. See `Session.hasCompactedSinceBaseline`.
  static func newestCompaction(inChunk chunk: Data, droppingFirstLine: Bool) -> Compaction? {
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      guard line.range(of: Data("compact_boundary".utf8)) != nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        object["subtype"] as? String == "compact_boundary",
        let metadata = object["compactMetadata"] as? [String: Any]
      else { continue }

      return Compaction(
        trigger: metadata["trigger"] as? String,
        preTokens: metadata["preTokens"] as? Int,
        postTokens: metadata["postTokens"] as? Int,
        at: (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp))
    }
    return nil
  }
}

/// How fast a session is filling its window, and what that implies.
///
/// Derived from the readings in one 64KB tail — typically the last few dozen
/// requests — rather than from the last two, which are far too noisy: a turn that
/// reads a large file jumps by tens of thousands of tokens and the next one by a few
/// hundred.
///
/// **Per API request, not per user turn.** One prompt spans many requests, so a
/// "per turn" figure derived from this series would be wrong by whatever factor the
/// session's tool use happens to run at. The time-based projection avoids the
/// distinction entirely, which is why it is the one worth showing.
nonisolated struct ContextGrowth: Sendable, Hashable {
  let tokensPerRequest: Int
  /// Nil when the sampled requests span no measurable time.
  let tokensPerSecond: Double?
  let requests: Int

  /// When the window fills at this rate, or nil if it never does.
  func projectedFull(from total: Int, limit: Int, now: Date) -> Date? {
    guard let tokensPerSecond, tokensPerSecond > 0, total < limit else { return nil }
    return now.addingTimeInterval(Double(limit - total) / tokensPerSecond)
  }

  /// Nil unless at least two requests were seen, and nil across a compaction: a
  /// falling total makes every rate here meaningless.
  init?(series: [ContextReading]) {
    guard let first = series.first, let last = series.last, series.count >= 2,
      last.total > first.total
    else { return nil }

    let grown = last.total - first.total
    let steps = series.count - 1
    requests = steps
    tokensPerRequest = grown / steps

    if let start = first.at, let end = last.at, end > start {
      tokensPerSecond = Double(grown) / end.timeIntervalSince(start)
    } else {
      tokensPerSecond = nil
    }
  }
}
