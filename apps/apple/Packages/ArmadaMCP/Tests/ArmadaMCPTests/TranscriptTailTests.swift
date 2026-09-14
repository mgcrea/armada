import Foundation
import Testing

@testable import ArmadaMCP

/// Lines in the shapes measured on this Mac on 2026-09-14: Claude Code 2.1.269 writes one
/// content block per assistant line; Codex writes `response_item` payloads and repeats the
/// messages as `event_msg`.
enum TranscriptFixtures {
  static let claude = [
    #"{"type":"user","timestamp":"2026-09-14T10:00:00.000Z","message":{"role":"user","content":"Why does login fail?"}}"#,
    #"{"type":"user","isMeta":true,"timestamp":"2026-09-14T10:00:00.100Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>injected</system-reminder>"}]}}"#,
    #"{"type":"assistant","timestamp":"2026-09-14T10:00:01.000Z","message":{"model":"claude-opus-5","content":[{"type":"thinking","thinking":""}]}}"#,
    #"{"type":"assistant","timestamp":"2026-09-14T10:00:02.000Z","message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#,
    #"{"type":"user","timestamp":"2026-09-14T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"1 test passed"}]}]}}"#,
    #"{"type":"ai-title","aiTitle":"Fix login","sessionId":"x"}"#,
    #"{"type":"assistant","isSidechain":true,"timestamp":"2026-09-14T10:00:03.500Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"subagent chatter"}]}}"#,
    #"{"type":"assistant","timestamp":"2026-09-14T10:00:04.000Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Done. The test passes now."}]}}"#,
  ]

  static let codex = [
    #"{"type":"turn_context","timestamp":"2026-09-14T10:00:00.000Z","payload":{"model":"gpt-5.5"}}"#,
    #"{"type":"response_item","timestamp":"2026-09-14T10:00:00.100Z","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"setup"}]}}"#,
    #"{"type":"response_item","timestamp":"2026-09-14T10:00:00.200Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
    #"{"type":"response_item","timestamp":"2026-09-14T10:00:01.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Bump the version"}]}}"#,
    #"{"type":"event_msg","timestamp":"2026-09-14T10:00:01.100Z","payload":{"type":"user_message","message":"Bump the version"}}"#,
    #"{"type":"response_item","timestamp":"2026-09-14T10:00:02.000Z","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"make bump\"}"}}"#,
    #"{"type":"response_item","timestamp":"2026-09-14T10:00:03.000Z","payload":{"type":"function_call_output","output":"ok"}}"#,
    #"{"type":"response_item","timestamp":"2026-09-14T10:00:04.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Bumped to 1.0.1."}]}}"#,
    #"{"type":"event_msg","timestamp":"2026-09-14T10:00:05.000Z","payload":{"type":"task_complete"}}"#,
  ]

  static func read(_ lines: [String], fragment: Bool = false) -> TranscriptTail.Read {
    let text = (fragment ? ["\"half a line}"] : []) + lines
    return TranscriptTail.Read(
      chunk: Data(text.joined(separator: "\n").utf8), droppingFirstLine: fragment)
  }
}

@Suite("Transcript tail")
struct TranscriptTailTests {

  @Test("Claude: turns and tools survive; thinking, meta, sidechain and titles do not")
  func claude() {
    let entries = TranscriptTail.condense(
      TranscriptFixtures.read(TranscriptFixtures.claude, fragment: true), vendor: .claude,
      maxChars: 2_000)
    #expect(entries.map(\.kind) == [.user, .toolUse, .toolResult, .assistant])
    #expect(entries[0].text == "Why does login fail?")
    #expect(entries[1].tool == "Bash")
    #expect(entries[1].text == #"{"command":"swift test"}"#)
    #expect(entries[2].text == "1 test passed")
    #expect(entries[3].model == "claude-opus-5")
  }

  @Test("Codex: setup and injected context are dropped, the model comes from turn_context")
  func codex() {
    let entries = TranscriptTail.condense(
      TranscriptFixtures.read(TranscriptFixtures.codex), vendor: .codex, maxChars: 2_000)
    #expect(entries.map(\.kind) == [.user, .toolUse, .toolResult, .assistant, .system])
    #expect(entries[0].text == "Bump the version")
    #expect(entries[1].tool == "shell")
    #expect(entries[3].model == "gpt-5.5")
  }

  @Test("Texts are cut to max_chars and marked, tool input to a shorter summary")
  func truncation() {
    let long = String(repeating: "x", count: 500)
    let lines = [
      #"{"type":"user","message":{"content":"\#(long)"}}"#,
      #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"\#(long)"}}]}}"#,
    ]
    let entries = TranscriptTail.condense(
      TranscriptFixtures.read(lines), vendor: .claude, maxChars: 400)
    #expect(entries[0].truncated)
    #expect(entries[0].text?.count == 401)
    #expect(entries[1].truncated)
    #expect(entries[1].text?.count == TranscriptTail.toolInputChars + 1)
  }

  @Test("A read that starts mid-file flags its first line as a fragment and stays in bounds")
  func boundedRead() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "armada-tail-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try TranscriptFixtures.claude.joined(separator: "\n").write(
      to: url, atomically: true, encoding: .utf8)

    let read = try #require(TranscriptTail.read(at: url, maxBytes: 200))
    #expect(read.chunk.count == 200)
    #expect(read.droppingFirstLine)

    let whole = try #require(TranscriptTail.read(at: url, maxBytes: 1_000_000))
    #expect(!whole.droppingFirstLine)
  }
}
