import Foundation

/// How full a Codex session's context window is, read out of its rollout.
///
/// **The same panel as the Claude side, from far better evidence.** `TranscriptContext`
/// has to sum three fields of an assistant turn's `usage` and then guess the window
/// size from a model id that does not distinguish a 200k session from a 1M one. Codex
/// writes both figures down: every `token_count` event carries `last_token_usage` —
/// the request that just went out — and `model_context_window` beside it. So there is
/// no `ContextWindow` equivalent here and nothing to resolve; the number is stated.
///
/// **`total_token_usage` is the trap.** It sits in the same object and is *cumulative
/// across the session*: 343,343 on a session whose window is 258,400, because it has
/// been adding up every request since the first. Read as "the context", it reports a
/// session at 133% of a window it is comfortably inside. `last_token_usage` is the one
/// that describes the current prompt.
///
/// Values map onto `ContextReading` so that `ContextGrowth`, `ContextBar` and
/// `ContextPanel` are shared rather than reimplemented. One difference in the field
/// names is worth stating: Codex's `input_tokens` **includes** `cached_input_tokens`,
/// where Claude's `input_tokens` excludes its two cache figures. So the fresh input is
/// the subtraction below, and the invariant both vendors keep —
/// `freshInput + cacheRead + cacheCreation == total` — still holds.
nonisolated enum CodexContext {
  /// The newest reading in a buffer, and the window it was measured against.
  static func newestReading(inChunk chunk: Data, droppingFirstLine: Bool) -> (
    reading: ContextReading, limit: Int
  )? {
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      if let found = reading(fromLine: line) { return found }
    }
    return nil
  }

  /// Every reading in this buffer, oldest first, one per request.
  ///
  /// No `apiBlockIndex` filtering, unlike the Claude series: Codex emits one
  /// `token_count` per response rather than repeating one `usage` object across
  /// several entries. `token_usage_record` carries the same numbers a second time and
  /// is deliberately not parsed here, which is what keeps that true.
  static func series(inChunk chunk: Data, droppingFirstLine: Bool) -> [ContextReading] {
    JSONLines.oldestFirst(chunk, droppingFirstLine: droppingFirstLine).compactMap {
      reading(fromLine: $0)?.reading
    }
  }

  /// What the session was carrying on its first request.
  ///
  /// The analogue of `TranscriptContext.baseline` — system prompt, tools and the first
  /// user message as one measured figure. **It is a long way into the file**: measured
  /// at byte 332,171 of a 13.7MB rollout, because `session_meta` alone is 22KB and the
  /// first turn's reasoning and tool output come before the first `token_count`. So
  /// this reads far more than the head parse does, and the caller runs it once per
  /// session, off the main actor. A session whose first reading is past `budget`
  /// simply has no baseline, and the panel falls back to a single band exactly as the
  /// Claude one does.
  static func baseline(at url: URL, budget: Int = 1_024 * 1_024) -> ContextBaseline? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: budget) else { return nil }
    for line in JSONLines.oldestFirst(head, droppingFirstLine: false) {
      if let found = reading(fromLine: line) {
        return ContextBaseline(loadedAtStart: found.reading.total)
      }
    }
    return nil
  }

  /// One `token_count` event's usage, or nil for every other kind of line.
  static func reading(fromLine line: Data) -> (reading: ContextReading, limit: Int)? {
    // Cheap reject before paying for a JSON parse, as every other parser here does.
    guard line.range(of: Data("\"token_count\"".utf8)) != nil,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
      let info = payload["info"] as? [String: Any],
      let last = info["last_token_usage"] as? [String: Any],
      let limit = info["model_context_window"] as? Int,
      let input = last["input_tokens"] as? Int
    else { return nil }

    let cached = last["cached_input_tokens"] as? Int ?? 0
    let written = last["cache_write_input_tokens"] as? Int ?? 0

    let reading = ContextReading(
      // The prompt, matching what `ContextReading.total` means on the Claude side —
      // the response is counted separately there too.
      total: input,
      cacheRead: cached,
      cacheCreation: written,
      // `max` rather than a bare subtraction: these come from a vendor's log, and a
      // negative band would render as a bar segment running backwards.
      freshInput: max(input - cached - written, 0),
      output: last["output_tokens"] as? Int ?? 0,
      // Codex does not name the model here. `turn_context` does, and
      // `CodexSessionMeta.model` already carries it.
      modelID: nil,
      at: (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp))
    return (reading, limit)
  }
}
