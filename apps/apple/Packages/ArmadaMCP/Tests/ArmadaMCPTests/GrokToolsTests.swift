import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

/// Grok Build through every tool, on a fleet of its own so the counts the other suites assert
/// over `FakeFleetSource.fleet()` stay as they are.
@Suite("Grok Build in the tools")
struct GrokToolsTests {
  static let open = "01a0af67-f521-75d2-b771-920a03e5fdf9"
  static let headless = "01a0af59-ee50-7b73-a473-2f2bcf56012e"
  static let ended = "01a0aed0-c99b-7cd1-a1ac-b6fd20ac67a6"

  static func session(
    _ id: String, name: String, state: String, pid: Int32?, headless: Bool = false
  ) -> FleetSnapshot.GrokSession {
    FleetSnapshot.GrokSession(
      id: id, pid: pid, name: name, title: name, project: "cadence", cwd: "/work/cadence",
      state: state, stateLabel: state, isLive: state != "ended", isHeadless: headless,
      startedAt: FakeFleetSource.now, lastActivity: FakeFleetSource.now, model: "grok-4.6",
      context: FleetSnapshot.Context(
        total: 11_790, limit: 500_000, limitNote: "measured", cacheRead: 0, cacheCreation: 0,
        freshInput: 0, output: 0, at: nil, hasCompacted: false),
      totalTokens: 72_175, costUSD: 0.0196, updatesPath: "/work/updates.jsonl")
  }

  static func source() -> FakeFleetSource {
    FakeFleetSource(
      FleetSnapshot(
        takenAt: FakeFleetSource.now, isEntitled: true, claude: [], codex: [],
        grok: [
          FleetSnapshot.GrokAccount(
            id: "/Users/me/.grok", name: "Grok Build", plan: "X Premium",
            usage: FleetSnapshot.Usage(
              fiveHour: nil,
              sevenDay: FleetSnapshot.Window(
                utilization: 13, resetsAt: FakeFleetSource.now.addingTimeInterval(86_400),
                refusedAt: nil),
              limits: [], fetchedAt: FakeFleetSource.now, source: "live"),
            sessions: [
              session(open, name: "French greeting", state: "awaitingInput", pid: 33_135),
              session(
                headless, name: "Read the README", state: "working", pid: nil, headless: true),
              session(ended, name: "Old one", state: "ended", pid: nil),
            ])
        ]))
  }

  private func call(
    _ name: String, _ arguments: JSONValue = .object([:]), closer: FakeSessionCloser = .init(),
    sender: FakeMessageSender = .init()
  ) async -> ToolResult {
    await Tools.table(
      source: Self.source(), starter: FakeSessionStarter(), closer: closer, sender: sender,
      focuser: FakeSessionFocuser()
    ).call(name: name, arguments: arguments, allowWrites: true)
  }

  @Test("The fleet lists Grok Build's account and live sessions, and ended ones only when asked")
  func fleet() async throws {
    let result = await call("armada_get_fleet")
    let ids = try #require(result.structuredContent?["sessions"]?.arrayValue).compactMap {
      $0["id"]?.stringValue
    }
    #expect(Set(ids) == [Self.open, Self.headless])
    #expect(result.structuredContent?["accounts"]?[0]?["vendor"] == "grok")

    let all = await call("armada_get_fleet", ["vendor": "grok", "include_ended": true])
    #expect(all.structuredContent?["sessions"]?.arrayValue?.count == 3)
    let none = await call("armada_get_fleet", ["vendor": "codex"])
    #expect(none.structuredContent?["sessions"]?.arrayValue?.isEmpty == true)
  }

  @Test("What needs the person leaves Grok Build out and says how many are open")
  func needsAttention() async {
    let result = await call("armada_needs_attention")
    #expect(result.structuredContent?["sessions"]?.arrayValue?.isEmpty == true)
    #expect(result.structuredContent?["grok"]?["openSessions"] == .int(2))
  }

  @Test("One session is found by name, with its pid, cost and log path")
  func session() async {
    let result = await call("armada_get_session", ["session": "French greeting"])
    #expect(!result.isError)
    let detail = result.structuredContent?["session"]
    #expect(detail?["vendor"] == "grok")
    #expect(detail?["pid"] == .int(33_135))
    #expect(detail?["updatesPath"] == "/work/updates.jsonl")
  }

  @Test("The weekly allowance is reported under Grok Build's name")
  func usage() async {
    let result = await call("armada_get_usage")
    #expect(result.text.contains("Grok Build (Grok Build): 7d 13%"))
  }

  @Test("Close, message and focus refuse a Grok Build session and reach nothing")
  func refusals() async {
    let closer = FakeSessionCloser()
    let closed = await call("armada_close_session", ["session": .string(Self.open)], closer: closer)
    #expect(closed.isError && closed.text.contains("Grok Build"))
    #expect(closer.requests.isEmpty)

    let sender = FakeMessageSender()
    let sent = await call(
      "armada_send_message", ["session": .string(Self.open), "text": "hi"], sender: sender)
    #expect(sent.isError && sent.text.contains("Grok Build"))

    let focused = await call("armada_focus_session", ["session": .string(Self.open)])
    #expect(focused.isError && focused.text.contains("Grok Build"))
  }

  @Test("armada_wait watches live Grok Build sessions, never as wanting attention")
  func watched() {
    let all = Tools.watched(Self.source().fleet)
    #expect(Set(all.keys) == [Self.open, Self.headless])
    #expect(all[Self.open]?.vendor == "grok")
    #expect(all.values.allSatisfy { !$0.wantsAttention })
  }

  @Test("A Grok Build log condenses to the conversation, with chunks joined")
  func transcript() {
    let lines = [
      #"{"timestamp":1789648302,"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"hook_execution","event_name":"user_prompt_submit"}}}"#,
      #"{"timestamp":1789648302,"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Read README.md "},"_meta":{"modelId":"grok-4.6"}}}}"#,
      #"{"timestamp":1789648302,"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"please."}}}}"#,
      #"{"timestamp":1789648305,"method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}}"#,
      #"{"timestamp":1789648305,"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"read_file","rawInput":{"target_file":"README.md"}}}}"#,
      #"{"timestamp":1789648305,"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","kind":"read"}}}"#,
      #"{"timestamp":1789648307,"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","rawOutput":{"type":"ReadFile","FileContent":{"raw_output":"hello\n"}}}}}"#,
      #"{"timestamp":1789648307,"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hel"}}}}"#,
      #"{"timestamp":1789648307,"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}}}"#,
      #"{"timestamp":1789648307,"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}}}"#,
    ]
    let entries = TranscriptTail.condense(
      TranscriptFixtures.read(lines), vendor: .grok, maxChars: 2_000)
    #expect(entries.map(\.kind) == [.user, .toolUse, .toolResult, .assistant, .system])
    #expect(entries[0].text == "Read README.md please.")
    #expect(entries[0].model == "grok-4.6")
    #expect(entries[1].tool == "read_file")
    #expect(entries[2].text?.contains("hello") == true)
    #expect(entries[3].text == "hello")
    #expect(entries[3].at == Date(timeIntervalSince1970: 1_789_648_307).formatted(.iso8601))
  }
}
