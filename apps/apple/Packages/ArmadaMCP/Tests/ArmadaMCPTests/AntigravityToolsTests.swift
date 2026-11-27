import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

/// The Antigravity CLI through every tool, on a fleet of its own so the counts the other suites
/// assert over `FakeFleetSource.fleet()` stay as they are.
@Suite("Antigravity in the tools")
struct AntigravityToolsTests {
  static let working = "657374e8-d811-4cd7-bbf5-b41c297de8f4"
  static let open = "33a760cd-88ed-464b-8f42-2051d73812ab"
  static let ended = "7bde737a-d7cc-400a-b7e0-3e628f0611d5"

  /// The four lines of a real `transcript.jsonl` (agy 1.5.18, 2026-11-27), with the scratch
  /// folder the probe ran in shortened.
  static let transcriptLines = [
    #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-27T07:56:32Z","content":"<USER_REQUEST>\nRead README.md and tell me its content in one line.\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-27T08:56:32+01:00.\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 4 Hydrogen (High). No need to comment on this change if the user doesn't ask about it. If reporting what model you are, please use a human readable name instead of the exact string.\n</USER_SETTINGS_CHANGE>"}"#,
    #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-27T07:56:32Z","model":"gemini-4-hydrogen-high","input_tokens":11635,"cache_read_tokens":0,"output_tokens":168,"tool_calls":[{"name":"read_file","args":{"Path":"\"/private/tmp/agyprobe/ws/README.md\""}}]}"#,
    #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"ERROR","error":"tool call denied by pre-tool hook: ","created_at":"2026-11-27T07:56:34Z","content":"Created At: 2026-11-27T08:56:34+01:00\nCompleted At: 2026-11-27T08:56:35+01:00\nEncountered error in step execution: tool call denied by pre-tool hook: "}"#,
    #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-27T07:56:35Z","model":"gemini-4-hydrogen-high","input_tokens":2251,"cache_read_tokens":9586,"output_tokens":747,"content":"I am blocked from reading [README.md](file:///private/tmp/agyprobe/ws/README.md) because the `read_file` tool call was denied by a pre-tool hook (`tool call denied by pre-tool hook`). As a result, I cannot view or summarize its contents.","thinking":"Direct file read blocked by pre-tool security hook.\n\n"}"#,
  ]

  static func session(
    _ id: String, name: String, state: String, pid: Int32?, transcriptPath: String? = nil
  ) -> FleetSnapshot.AntigravitySession {
    FleetSnapshot.AntigravitySession(
      id: id, pid: pid, name: name, title: nil, project: "ws", cwd: "/private/tmp/agyprobe/ws",
      state: state, stateLabel: state, isLive: state != "ended",
      startedAt: pid == nil ? nil : FakeFleetSource.now, lastActivity: FakeFleetSource.now,
      model: "gemini-4-hydrogen-high", totalTokens: 24_387, transcriptPath: transcriptPath)
  }

  static func source(transcriptPath: String? = "/work/transcript.jsonl") -> FakeFleetSource {
    FakeFleetSource(
      FleetSnapshot(
        takenAt: FakeFleetSource.now, isEntitled: true, claude: [], codex: [],
        antigravity: [
          FleetSnapshot.AntigravityAccount(
            id: "/Users/me/.gemini/antigravity-cli", name: "Antigravity",
            sessions: [
              session(
                working, name: "Read README.md", state: "working", pid: 41_002,
                transcriptPath: transcriptPath),
              session(open, name: "Say hi", state: "awaitingInput", pid: 41_100),
              session(ended, name: "Run Command Probe Ok", state: "ended", pid: nil),
            ])
        ]))
  }

  private func call(
    _ name: String, _ arguments: JSONValue = .object([:]),
    source: FakeFleetSource = AntigravityToolsTests.source(), starter: FakeSessionStarter = .init(),
    closer: FakeSessionCloser = .init(), sender: FakeMessageSender = .init(),
    focuser: FakeSessionFocuser = .init()
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: starter, closer: closer, sender: sender, focuser: focuser,
      schedules: FakeScheduleStore()
    ).call(name: name, arguments: arguments, allowWrites: true)
  }

  @Test("The fleet lists the Antigravity home and its live sessions, ended ones only when asked")
  func fleet() async throws {
    let result = await call("armada_get_fleet")
    #expect(!result.isError)
    let sessions = try #require(result.structuredContent?["sessions"]?.arrayValue)
    #expect(sessions.compactMap { $0["id"]?.stringValue } == [Self.working, Self.open])
    #expect(sessions.allSatisfy { $0["vendor"] == "antigravity" })
    #expect(sessions.compactMap { $0["state"]?.stringValue } == ["working", "awaitingInput"])
    #expect(result.structuredContent?["accounts"]?[0]?["vendor"] == "antigravity")

    let all = await call("armada_get_fleet", ["vendor": "antigravity", "include_ended": true])
    #expect(!all.isError)
    #expect(all.structuredContent?["sessions"]?.arrayValue?.count == 3)
    let none = await call("armada_get_fleet", ["vendor": "grok"])
    #expect(none.structuredContent?["sessions"]?.arrayValue?.isEmpty == true)
  }

  @Test("What needs the person leaves an Antigravity session awaiting input out")
  func needsAttention() async {
    let result = await call("armada_needs_attention")
    #expect(result.structuredContent?["sessions"]?.arrayValue?.isEmpty == true)
    #expect(result.structuredContent?["antigravity"]?["excluded"] == .bool(true))
    #expect(result.structuredContent?["antigravity"]?["openSessions"] == .int(2))
  }

  @Test("One session is found by name, with its pid, tokens and transcript path")
  func session() async {
    let result = await call("armada_get_session", ["session": "Read README.md"])
    #expect(!result.isError)
    let detail = result.structuredContent?["session"]
    #expect(detail?["vendor"] == "antigravity")
    #expect(detail?["pid"] == .int(41_002))
    #expect(detail?["totalTokens"] == .int(24_387))
    #expect(detail?["transcriptPath"] == "/work/transcript.jsonl")
  }

  @Test("A transcript.jsonl condenses to the prompt, the tool call, its error and the answer")
  func transcriptCondensed() {
    let entries = TranscriptTail.condense(
      TranscriptFixtures.read(Self.transcriptLines), vendor: .antigravity, maxChars: 2_000)
    #expect(entries.map(\.kind) == [.user, .toolUse, .toolResult, .assistant])
    #expect(entries[0].text == "Read README.md and tell me its content in one line.")
    #expect(entries[0].at == "2026-11-27T07:56:32Z")
    #expect(entries[1].tool == "read_file")
    #expect(entries[1].text?.contains("/private/tmp/agyprobe/ws/README.md") == true)
    #expect(entries[1].model == "gemini-4-hydrogen-high")
    #expect(entries[2].text?.contains("tool call denied by pre-tool hook") == true)
    #expect(entries[3].text?.hasPrefix("I am blocked from reading") == true)
    #expect(entries[3].model == "gemini-4-hydrogen-high")
  }

  @Test("armada_read_transcript reads an Antigravity transcript from disk")
  func transcript() async throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "armada-agy-\(UUID().uuidString).jsonl")
    try (Self.transcriptLines.joined(separator: "\n") + "\n").write(
      to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = await call(
      "armada_read_transcript", ["session": .string(Self.working)],
      source: Self.source(transcriptPath: file.path(percentEncoded: false)))
    #expect(!result.isError)
    let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
    #expect(entries.count == 4)
    #expect(entries[0]["text"] == "Read README.md and tell me its content in one line.")
    #expect(entries[1]["tool"] == "read_file")
    #expect(result.text.contains("I am blocked from reading"))

    let unprompted = await call("armada_read_transcript", ["session": .string(Self.open)])
    #expect(unprompted.isError && unprompted.text.contains("never been prompted"))
  }

  @Test("A message to an Antigravity session is refused and reaches nothing")
  func sendRefused() async {
    let sender = FakeMessageSender()
    let sent = await call(
      "armada_send_message", ["session": .string(Self.open), "text": "hi"], sender: sender)
    #expect(sent.isError)
    #expect(sent.text == "Armada cannot send messages to Antigravity CLI sessions yet.")
    #expect(sender.requests.isEmpty)
  }

  @Test("A headless Antigravity start is refused before it reaches the starter")
  func startHeadlessRefused() async {
    let starter = FakeSessionStarter()
    let result = await call(
      "armada_start_session",
      [
        "project": .string(FakeFleetSource.armadaProject), "vendor": "antigravity",
        "prompt": "hi", "headless": true,
      ], starter: starter)
    #expect(result.isError && result.text.contains("headless"))
    #expect(starter.requests.isEmpty)
  }

  @Test("An Antigravity start and resume reach the starter as Antigravity")
  func start() async {
    let starter = FakeSessionStarter()
    let fresh = await call(
      "armada_start_session",
      ["project": .string(FakeFleetSource.armadaProject), "vendor": "antigravity"],
      starter: starter)
    #expect(!fresh.isError)
    let resumed = await call(
      "armada_start_session", ["resume": .string(Self.ended), "vendor": "antigravity"],
      starter: starter)
    #expect(!resumed.isError)
    #expect(starter.requests.map(\.vendor) == ["antigravity", "antigravity"])
    #expect(starter.requests.last?.resume == Self.ended)
  }

  @Test("Closing a working session needs force; an idle one reaches the closer as Antigravity")
  func close() async {
    let closer = FakeSessionCloser()
    let unforced = await call(
      "armada_close_session", ["session": .string(Self.working)], closer: closer)
    #expect(unforced.isError && unforced.text.contains("`force: true`"))
    #expect(closer.requests.isEmpty)

    let ended = await call(
      "armada_close_session", ["session": .string(Self.ended), "force": true], closer: closer)
    #expect(ended.isError && ended.text.contains("ended"))
    #expect(closer.requests.isEmpty)

    let idle = await call("armada_close_session", ["session": .string(Self.open)], closer: closer)
    #expect(!idle.isError)
    let forced = await call(
      "armada_close_session", ["session": .string(Self.working), "force": true], closer: closer)
    #expect(!forced.isError)
    #expect(
      closer.requests == [
        CloseSessionRequest(sessionID: Self.open, force: false, vendor: "antigravity"),
        CloseSessionRequest(sessionID: Self.working, force: true, vendor: "antigravity"),
      ])
  }

  @Test("Focus reaches the focuser as Antigravity for a live session, and refuses an ended one")
  func focus() async {
    let focuser = FakeSessionFocuser()
    let focused = await call(
      "armada_focus_session", ["session": .string(Self.open)], focuser: focuser)
    #expect(!focused.isError)
    let ended = await call(
      "armada_focus_session", ["session": .string(Self.ended)], focuser: focuser)
    #expect(ended.isError && ended.text.contains("ended"))
    #expect(
      focuser.requests == [FocusSessionRequest(sessionID: Self.open, vendor: "antigravity")])
  }

  @Test("armada_wait watches live Antigravity sessions, never as wanting attention")
  func watched() {
    let all = Tools.watched(Self.source().fleet)
    #expect(Set(all.keys) == [Self.working, Self.open])
    #expect(all[Self.open]?.vendor == "antigravity")
    #expect(all.values.allSatisfy { !$0.wantsAttention })
  }
}
