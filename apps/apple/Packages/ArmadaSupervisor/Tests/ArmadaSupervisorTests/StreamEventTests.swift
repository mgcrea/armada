import Foundation
import Testing

@testable import ArmadaSupervisor

/// Lines in the shapes `claude` 2.1.270 wrote on 2026-09-15, driven over stream-json with
/// `--include-partial-messages`, trimmed to the keys that matter and with ids shortened.
///
/// Measured: `initialized`, `status`, `textDelta`, `thinkingDelta`, `assistantText`,
/// `rateLimit`, `resultSuccess`, `controlResponse`, `interruptedUser`, `resultInterrupted`.
/// Constructed from the CLI's own schema until a live capture replaces them: `toolUse`,
/// `assistantError`, `apiRetry` (the Armada endpoint could not read its token that day).
enum StreamFixtures {
  static let initialized =
    #"{"type":"system","subtype":"init","cwd":"/tmp/voice","session_id":"bff5bff9-9c08-4006-b9df-518b82a4db88","tools":["mcp__armada__armada_needs_attention","mcp__armada__armada_get_fleet"],"mcp_servers":[{"name":"armada","status":"connected"}],"model":"claude-opus-5[1m]","permissionMode":"default","apiKeySource":"none"}"#
  static let initializedWithoutServer =
    #"{"type":"system","subtype":"init","session_id":"5f401944-82e0-494f-91b0-972f0ae9871b","tools":[],"mcp_servers":[{"name":"armada","status":"failed"}]}"#
  static let status =
    #"{"type":"system","subtype":"status","status":"requesting","session_id":"bff5bff9","uuid":"4e4ec9ed"}"#
  static let messageStart =
    #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-opus-5","role":"assistant","content":[]}},"parent_tool_use_id":null,"session_id":"bff5bff9","ttft_ms":1022}"#
  static let textDelta =
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Two sessions need you."}},"parent_tool_use_id":null,"session_id":"bff5bff9"}"#
  static let thinkingDelta =
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The person asked"}},"parent_tool_use_id":null,"session_id":"5f401944"}"#
  static let assistantText =
    #"{"type":"assistant","message":{"model":"claude-opus-5","id":"msg_011","type":"message","role":"assistant","content":[{"type":"text","text":"ok."}]},"parent_tool_use_id":null,"session_id":"bff5bff9"}"#
  static let toolUse =
    #"{"type":"assistant","message":{"model":"claude-opus-5","id":"msg_012","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"mcp__armada__armada_needs_attention","input":{}}]},"parent_tool_use_id":null,"session_id":"bff5bff9"}"#
  static let assistantError =
    #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Invalid API key"}]},"error":"authentication_failed","parent_tool_use_id":null,"session_id":"bff5bff9"}"#
  static let apiRetry =
    #"{"type":"system","subtype":"api_retry","attempt":2,"error_status":529,"error":"overloaded","session_id":"bff5bff9"}"#
  static let rateLimit =
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"},"session_id":"bff5bff9"}"#
  static let resultSuccess =
    #"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"ok.","stop_reason":"end_turn","terminal_reason":"completed","session_id":"bff5bff9"}"#
  static let controlResponse =
    #"{"type":"control_response","response":{"subtype":"success","request_id":"spike-interrupt","response":{"still_queued":[]}}}"#
  static let interruptedUser =
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"session_id":"5f401944"}"#
  static let resultInterrupted =
    #"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":2,"stop_reason":null,"terminal_reason":"aborted_streaming","session_id":"5f401944"}"#
}

@Suite("Stream events")
struct StreamEventTests {
  @Test("init carries the session id, the tools and the MCP server's status")
  func initialized() {
    #expect(
      StreamEvent.decode(StreamFixtures.initialized)
        == .initialized(
          sessionID: "bff5bff9-9c08-4006-b9df-518b82a4db88",
          tools: ["mcp__armada__armada_needs_attention", "mcp__armada__armada_get_fleet"],
          mcpServers: [.init(name: "armada", status: "connected")]))
    #expect(
      StreamEvent.decode(StreamFixtures.initializedWithoutServer)
        == .initialized(
          sessionID: "5f401944-82e0-494f-91b0-972f0ae9871b", tools: [],
          mcpServers: [.init(name: "armada", status: "failed")]))
  }

  @Test("only text deltas are speech; thinking and the repeated assistant text are not")
  func text() {
    #expect(StreamEvent.decode(StreamFixtures.textDelta) == .textDelta("Two sessions need you."))
    #expect(StreamEvent.decode(StreamFixtures.thinkingDelta) == .other)
    #expect(StreamEvent.decode(StreamFixtures.messageStart) == .other)
    #expect(StreamEvent.decode(StreamFixtures.assistantText) == .other)
  }

  @Test("a tool call is named, an assistant error wins over its text")
  func toolsAndErrors() {
    #expect(
      StreamEvent.decode(StreamFixtures.toolUse)
        == .toolUse(name: "mcp__armada__armada_needs_attention"))
    #expect(StreamEvent.decode(StreamFixtures.assistantError) == .apiError("authentication_failed"))
    #expect(StreamEvent.decode(StreamFixtures.apiRetry) == .retry(attempt: 2))
  }

  @Test("result ends the turn, and an interrupt is recognisable as one")
  func turnEnd() {
    #expect(
      StreamEvent.decode(StreamFixtures.resultSuccess)
        == .turnEnded(
          .init(isError: false, subtype: "success", terminalReason: "completed", text: "ok.")))
    guard case .turnEnded(let end) = StreamEvent.decode(StreamFixtures.resultInterrupted) else {
      Issue.record("an interrupted result is still the end of the turn")
      return
    }
    #expect(end.isError)
    #expect(end.wasInterrupted)
    #expect(end.text == nil)
    #expect(
      StreamEvent.decode(StreamFixtures.controlResponse)
        == .controlResponse(requestID: "spike-interrupt", succeeded: true))
  }

  @Test("everything else is other, including lines that are not JSON")
  func other() {
    for line in [
      StreamFixtures.status, StreamFixtures.rateLimit, StreamFixtures.interruptedUser, "",
      "not json", #"{"type":"#, #"["array"]"#, #"{"no_type":true}"#,
    ] {
      #expect(StreamEvent.decode(line) == .other, "\(line)")
    }
  }
}
