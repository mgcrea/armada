import Foundation

/// One line of a headless `claude`'s `--output-format stream-json`, reduced to what the voice
/// overlay acts on.
///
/// Shapes measured against 2.1.270 on 2026-09-15:
///
/// - **`system`/`init` opens every turn**, not only the process. It carries `session_id`,
///   `tools` and `mcp_servers`, so a failed MCP connection is visible before the first word.
/// - **Text arrives as `stream_event` deltas** under `--include-partial-messages`:
///   `content_block_delta` with a `text_delta`. `thinking_delta` and `signature_delta` arrive
///   the same way on a reasoning turn and are not speech.
/// - **The complete `assistant` message repeats the text**, one content block per line. Only
///   its `tool_use` blocks and its `error` are read here, so no text is ever counted twice.
/// - **`result` ends the turn**, success or not. An interrupt ends it as
///   `error_during_execution` with `terminal_reason: aborted_streaming`, after a
///   `control_response` for the interrupt request.
///
/// Decoding never throws: a line that is not JSON, or JSON of a shape not listed here, is
/// `.other`. The CLI adds event types between releases, and none of them should stop a reply.
public enum StreamEvent: Equatable, Sendable {
  case initialized(sessionID: String, tools: [String], mcpServers: [MCPServer])
  case textDelta(String)
  case toolUse(name: String)
  case apiError(String)
  case retry(attempt: Int)
  case controlResponse(requestID: String, succeeded: Bool)
  case turnEnded(TurnEnd)
  case other

  public struct MCPServer: Equatable, Sendable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
      self.name = name
      self.status = status
    }
  }

  public struct TurnEnd: Equatable, Sendable {
    public let isError: Bool
    public let subtype: String
    public let terminalReason: String?
    /// The whole reply, as the CLI assembled it. Nil on an error turn.
    public let text: String?

    public init(isError: Bool, subtype: String, terminalReason: String?, text: String?) {
      self.isError = isError
      self.subtype = subtype
      self.terminalReason = terminalReason
      self.text = text
    }

    /// The turn stopped because an interrupt was sent, which is not a failure to report.
    public var wasInterrupted: Bool { terminalReason == "aborted_streaming" }
  }

  public static func decode(_ line: some StringProtocol) -> StreamEvent {
    decode(Data(line.utf8))
  }

  public static func decode(_ line: Data) -> StreamEvent {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String
    else { return .other }

    switch type {
    case "system":
      return system(object)
    case "stream_event":
      guard let event = object["event"] as? [String: Any],
        event["type"] as? String == "content_block_delta",
        let delta = event["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta",
        let text = delta["text"] as? String
      else { return .other }
      return .textDelta(text)
    case "assistant":
      if let error = object["error"] as? String { return .apiError(error) }
      let message = object["message"] as? [String: Any]
      let blocks = message?["content"] as? [[String: Any]] ?? []
      let tool = blocks.first { $0["type"] as? String == "tool_use" }
      guard let name = tool?["name"] as? String else { return .other }
      return .toolUse(name: name)
    case "control_response":
      guard let response = object["response"] as? [String: Any],
        let requestID = response["request_id"] as? String
      else { return .other }
      return .controlResponse(
        requestID: requestID, succeeded: response["subtype"] as? String == "success")
    case "result":
      let isError = object["is_error"] as? Bool ?? true
      return .turnEnded(
        TurnEnd(
          isError: isError,
          subtype: object["subtype"] as? String ?? "",
          terminalReason: object["terminal_reason"] as? String,
          text: isError ? nil : object["result"] as? String))
    default:
      return .other
    }
  }

  private static func system(_ object: [String: Any]) -> StreamEvent {
    switch object["subtype"] as? String {
    case "init":
      guard let sessionID = object["session_id"] as? String else { return .other }
      let servers = (object["mcp_servers"] as? [[String: Any]] ?? []).compactMap {
        server -> MCPServer? in
        guard let name = server["name"] as? String else { return nil }
        return MCPServer(name: name, status: server["status"] as? String ?? "")
      }
      return .initialized(
        sessionID: sessionID, tools: object["tools"] as? [String] ?? [], mcpServers: servers)
    case "api_retry":
      return .retry(attempt: object["attempt"] as? Int ?? 0)
    default:
      return .other
    }
  }
}
