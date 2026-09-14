import Foundation

/// The end of a session's transcript, condensed to what a supervisor reads.
///
/// **Pure functions over a buffer**, beside one bounded read. A transcript runs to 50MB and a
/// rollout to 13MB; nothing here reads more than the caller asked for, and the condenser never
/// sees a file, so the tests hand it lines rather than fixtures on disk.
///
/// **Lossy on purpose.** Thinking blocks are dropped (empty on the models that write them),
/// meta and sidechain entries are dropped (injected context and subagent chatter), and every
/// text is cut to a length. What survives is who said what, which tool ran, and when.
public enum TranscriptTail {

  public enum Vendor: Sendable {
    case claude
    case codex
  }

  public struct Read: Sendable {
    public let chunk: Data
    /// True when the read started mid-file, so its first line is a fragment and must be
    /// dropped before decoding. The same flag `TranscriptTitle.tail(of:)` carries in the app.
    public let droppingFirstLine: Bool

    public init(chunk: Data, droppingFirstLine: Bool) {
      self.chunk = chunk
      self.droppingFirstLine = droppingFirstLine
    }
  }

  public struct Entry: Sendable, Hashable {
    public enum Kind: String, Sendable {
      case user
      case assistant
      case toolUse = "tool_use"
      case toolResult = "tool_result"
      case system
    }

    public let kind: Kind
    /// The entry's own timestamp, passed through as written.
    public let at: String?
    public let text: String?
    public let tool: String?
    public let model: String?
    public let truncated: Bool

    public init(
      kind: Kind, at: String?, text: String?, tool: String? = nil, model: String? = nil,
      truncated: Bool = false
    ) {
      self.kind = kind
      self.at = at
      self.text = text
      self.tool = tool
      self.model = model
      self.truncated = truncated
    }
  }

  /// A tool call's input is summarised, never shown whole: an `Edit` carries two copies of a
  /// file region, and the call's name plus its first arguments is what says what happened.
  static let toolInputChars = 300

  /// The last `maxBytes` of a file.
  public static func read(at url: URL, maxBytes: Int) -> Read? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? handle.seek(toOffset: start)
    guard let chunk = try? handle.readToEnd() else { return nil }
    return Read(chunk: chunk, droppingFirstLine: start > 0)
  }

  /// Every readable entry in the buffer, oldest first.
  ///
  /// Never throws on a bad line: a fragment, a line caught mid-write or a shape this build
  /// has never seen costs that line and nothing else.
  public static func condense(_ read: Read, vendor: Vendor, maxChars: Int) -> [Entry] {
    var lines = read.chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
    if read.droppingFirstLine, !lines.isEmpty { lines.removeFirst() }
    var entries: [Entry] = []
    var codexModel: String?
    for line in lines {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      switch vendor {
      case .claude:
        entries += claude(object, maxChars: maxChars)
      case .codex:
        if object["type"] as? String == "turn_context",
          let model = (object["payload"] as? [String: Any])?["model"] as? String
        {
          codexModel = model
        }
        entries += codex(object, model: codexModel, maxChars: maxChars)
      }
    }
    return entries
  }

  // MARK: - Claude Code

  /// One transcript line. An assistant turn is written one content block per line, so this
  /// usually returns one entry, and a user line carrying several tool results returns each.
  static func claude(_ object: [String: Any], maxChars: Int) -> [Entry] {
    guard let type = object["type"] as? String else { return [] }
    // Injected context (skill bodies, hook output, reminders) and a subagent's own turns.
    // Neither is the conversation a person had with this session.
    if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true { return [] }
    let at = object["timestamp"] as? String
    let message = object["message"] as? [String: Any]

    switch type {
    case "assistant":
      let model = message?["model"] as? String
      return blocks(message?["content"]).compactMap { block in
        switch block["type"] as? String {
        case "text":
          return entry(.assistant, at: at, text: block["text"] as? String, model: model, maxChars)
        case "tool_use":
          return entry(
            .toolUse, at: at, text: summary(block["input"]), tool: block["name"] as? String,
            model: model, min(maxChars, toolInputChars))
        default:
          // `thinking` and `redacted_thinking`: empty text on the models that write them.
          return nil
        }
      }
    case "user":
      if let text = message?["content"] as? String {
        return [entry(.user, at: at, text: text, maxChars)].compactMap { $0 }
      }
      return blocks(message?["content"]).compactMap { block in
        switch block["type"] as? String {
        case "text":
          return entry(.user, at: at, text: block["text"] as? String, maxChars)
        case "tool_result":
          return entry(.toolResult, at: at, text: resultText(block["content"]), maxChars)
        case "image":
          return Entry(kind: .user, at: at, text: "[image]")
        default:
          return nil
        }
      }
    case "system":
      return [entry(.system, at: at, text: object["content"] as? String, maxChars)]
        .compactMap { $0 }
    default:
      // `ai-title`, `attachment`, `file-history-snapshot`, `last-prompt`, …
      return []
    }
  }

  // MARK: - Codex

  static func codex(_ object: [String: Any], model: String?, maxChars: Int) -> [Entry] {
    guard let type = object["type"] as? String, let payload = object["payload"] as? [String: Any]
    else { return [] }
    let at = object["timestamp"] as? String

    switch (type, payload["type"] as? String) {
    case ("response_item", "message"):
      let role = payload["role"] as? String
      guard role == "user" || role == "assistant" else { return [] }  // `developer` is setup
      let text = blocks(payload["content"])
        .compactMap { $0["text"] as? String }
        .joined(separator: "\n")
      if role == "user", isInjectedContext(text) { return [] }
      let kind: Entry.Kind = role == "user" ? .user : .assistant
      return [entry(kind, at: at, text: text, model: role == "assistant" ? model : nil, maxChars)]
        .compactMap { $0 }
    case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
      let input = payload["arguments"] as? String ?? payload["input"] as? String
      return [
        entry(
          .toolUse, at: at, text: input, tool: payload["name"] as? String,
          min(maxChars, toolInputChars))
      ].compactMap { $0 }
    case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
      return [entry(.toolResult, at: at, text: resultText(payload["output"]), maxChars)]
        .compactMap { $0 }
    case ("event_msg", "task_complete"):
      return [Entry(kind: .system, at: at, text: "Turn complete")]
    default:
      // `reasoning`, `token_count`, `turn_context`, and the `event_msg` copies of messages
      // already read from their `response_item`.
      return []
    }
  }

  /// The environment and instruction blocks Codex sends as a user message at the start of
  /// every thread. They are the harness talking, not the person.
  static func isInjectedContext(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS.md") else { return false }
    return trimmed.hasPrefix("# AGENTS.md") || trimmed.contains("_context>")
      || trimmed.contains("instructions>")
  }

  // MARK: - Shared

  static func blocks(_ value: Any?) -> [[String: Any]] {
    value as? [[String: Any]] ?? []
  }

  /// A tool result's text: a string, or a list of text blocks.
  static func resultText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    let texts = blocks(value).compactMap { $0["text"] as? String }
    if !texts.isEmpty { return texts.joined(separator: "\n") }
    guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
    return serialized(value)
  }

  static func summary(_ input: Any?) -> String? {
    guard let input, JSONSerialization.isValidJSONObject(input) else { return nil }
    return serialized(input)
  }

  static func serialized(_ value: Any) -> String? {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// An entry, or nil when there is no text worth showing. A tool call with no readable
  /// input still counts: its name is the information.
  static func entry(
    _ kind: Entry.Kind, at: String?, text: String?, tool: String? = nil, model: String? = nil,
    _ maxChars: Int
  ) -> Entry? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty, tool == nil { return nil }
    let (clipped, truncated) = clip(trimmed, to: maxChars)
    return Entry(
      kind: kind, at: at, text: clipped.isEmpty ? nil : clipped, tool: tool, model: model,
      truncated: truncated)
  }

  static func clip(_ text: String, to maxChars: Int) -> (String, Bool) {
    guard text.count > maxChars else { return (text, false) }
    return (String(text.prefix(maxChars)) + "…", true)
  }
}
