import Foundation

/// One assistant response's usage, read from a Claude Code transcript line.
///
/// **Lenient where `TranscriptContext.reading` is strict, and for the opposite reason.**
/// That parser answers "how full is the window", where a usage missing its cache fields is
/// no reading at all. This one answers "what was spent", where the same message still
/// spent its input and output, so absent fields count as zero rather than losing it.
///
/// Returns nil for every line that is not an assistant response with an id, a model and a
/// timestamp — and for `<synthetic>` ones, which Claude Code writes for errors and
/// interruptions without any request behind them.
nonisolated enum ClaudeUsageLine {
  struct Event: Equatable, Sendable {
    let messageID: String
    let model: String
    let tokens: TokenTally
    let at: Date
    let cwd: String?
  }

  private static let assistantMarker = Data(#""type":"assistant""#.utf8)
  private static let usageMarker = Data(#""usage""#.utf8)
  private static let cwdMarker = Data(#""cwd""#.utf8)

  static func parse(_ line: Data) -> Event? {
    // Cheap rejects first: nearly every line in a transcript is not an assistant turn.
    guard line.range(of: usageMarker) != nil, line.range(of: assistantMarker) != nil,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "assistant",
      let message = object["message"] as? [String: Any],
      let id = message["id"] as? String, !id.isEmpty,
      let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>",
      let usage = message["usage"] as? [String: Any],
      let stamp = object["timestamp"] as? String,
      let at = UsageSnapshot.parseTimestamp(stamp)
    else { return nil }

    let tokens = TokenTally(
      fresh: usage["input_tokens"] as? Int ?? 0,
      cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
      cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
      output: usage["output_tokens"] as? Int ?? 0)
    return Event(messageID: id, model: model, tokens: tokens, at: at, cwd: object["cwd"] as? String)
  }

  /// The `cwd` a line carries, for finding the folder a session started in.
  static func cwd(in line: Data) -> String? {
    guard line.range(of: cwdMarker) != nil,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let cwd = object["cwd"] as? String, !cwd.isEmpty
    else { return nil }
    return cwd
  }
}

/// A Codex session's running totals, as one `token_count` event reports them.
///
/// **Cumulative, so a session's spend is the change between events.** And `input_tokens`
/// already includes the cached and cache-written parts — measured: `total_tokens` is exactly
/// input plus output — so fresh input is what is left after taking those out.
nonisolated struct CodexCumulative: Codable, Hashable, Sendable {
  var input = 0
  var cached = 0
  var cacheWrite = 0
  var output = 0
  var reasoning = 0

  /// What was spent since `previous`, or nil when any figure went down, which is a
  /// restart of the count rather than negative spend.
  func delta(from previous: CodexCumulative?) -> TokenTally? {
    let base = previous ?? CodexCumulative()
    let input = input - base.input
    let cached = cached - base.cached
    let cacheWrite = cacheWrite - base.cacheWrite
    let output = output - base.output
    let reasoning = reasoning - base.reasoning
    guard input >= 0, cached >= 0, cacheWrite >= 0, output >= 0, reasoning >= 0 else { return nil }
    return TokenTally(
      fresh: max(0, input - cached - cacheWrite), cacheWrite: cacheWrite, cacheRead: cached,
      output: output, reasoning: reasoning)
  }

  /// The stored form, and the text the dedupe key is hashed from.
  var encoded: String { "\(input),\(cached),\(cacheWrite),\(output),\(reasoning)" }

  init(input: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0) {
    self.input = input
    self.cached = cached
    self.cacheWrite = cacheWrite
    self.output = output
    self.reasoning = reasoning
  }

  init?(encoded: String) {
    let parts = encoded.split(separator: ",").compactMap { Int($0) }
    guard parts.count == 5 else { return nil }
    self.init(
      input: parts[0], cached: parts[1], cacheWrite: parts[2], output: parts[3],
      reasoning: parts[4])
  }

  /// **Why a total is a dedupe key.** A forked rollout re-writes its parent's earlier
  /// `token_count` events, with no marker, before its own work begins. Measured across every
  /// rollout on this Mac, no two rollouts that are not a fork and its parent share a total,
  /// so a total already counted is a replay.
  var hashKey: UInt64 { StableHash.key(tag: UInt8(ascii: "x"), encoded) }
}

/// The three kinds of Codex rollout line the ledger reads.
nonisolated enum CodexUsageLine: Equatable, Sendable {
  case meta(cwd: String, isChild: Bool)
  case turnContext(model: String)
  case tokenCount(CodexCumulative, at: Date)

  private static let metaMarker = Data("session_meta".utf8)
  private static let turnMarker = Data("turn_context".utf8)
  private static let countMarker = Data("token_count".utf8)

  static func parse(_ line: Data) -> CodexUsageLine? {
    guard
      line.range(of: countMarker) != nil || line.range(of: turnMarker) != nil
        || line.range(of: metaMarker) != nil,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let payload = object["payload"] as? [String: Any]
    else { return nil }

    switch object["type"] as? String {
    case "session_meta":
      let parent = payload["parent_thread_id"] as? String
      return .meta(cwd: payload["cwd"] as? String ?? "", isChild: !(parent ?? "").isEmpty)
    case "turn_context":
      guard let model = payload["model"] as? String, !model.isEmpty else { return nil }
      return .turnContext(model: model)
    case "event_msg" where payload["type"] as? String == "token_count":
      guard let info = payload["info"] as? [String: Any],
        let usage = info["total_token_usage"] as? [String: Any],
        let stamp = object["timestamp"] as? String,
        let at = UsageSnapshot.parseTimestamp(stamp)
      else { return nil }
      return .tokenCount(
        CodexCumulative(
          input: usage["input_tokens"] as? Int ?? 0,
          cached: usage["cached_input_tokens"] as? Int ?? 0,
          cacheWrite: usage["cache_write_input_tokens"] as? Int ?? 0,
          output: usage["output_tokens"] as? Int ?? 0,
          reasoning: usage["reasoning_output_tokens"] as? Int ?? 0),
        at: at)
    default:
      return nil
    }
  }
}
