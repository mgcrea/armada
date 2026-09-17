import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_send_message")
struct SendMessageToolTests {

  private func call(
    _ arguments: JSONValue, source: FakeFleetSource = FakeFleetSource(),
    sender: FakeMessageSender = FakeMessageSender(), allowWrites: Bool = true
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(), sender: sender,
      focuser: FakeSessionFocuser()
    ).call(name: "armada_send_message", arguments: arguments, allowWrites: allowWrites)
  }

  @Test("Listed only while writes are allowed, and never among the read tools")
  func listing() throws {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser())
    #expect(!table.listing(allowWrites: false).contains { $0.name == "armada_send_message" })
    let tool = try #require(
      table.listing(allowWrites: true).first { $0.name == "armada_send_message" })
    #expect(tool.gate == .requiresWrites)
    #expect(!tool.annotations.readOnlyHint)
    #expect(!Tools.readToolNames.contains("armada_send_message"))
  }

  @Test("With the write switch off it is refused, and nothing is sent")
  func gateOff() async {
    let sender = FakeMessageSender()
    let result = await call(["session": "Docs", "text": "hi"], sender: sender, allowWrites: false)
    #expect(result.isError)
    #expect(sender.requests.isEmpty)
  }

  @Test("A session found by name gets the trimmed text, and delivery is reported")
  func delivered() async {
    let sender = FakeMessageSender()
    let result = await call(["session": "Docs", "text": "  run the tests\n"], sender: sender)
    #expect(!result.isError)
    #expect(
      sender.requests == [
        SendMessageRequest(sessionID: FakeFleetSource.idle, text: "run the tests")
      ])
    #expect(result.structuredContent?["sent"]?["status"] == .string("delivered"))
    #expect(result.text.hasPrefix("Delivered to Docs"))
  }

  @Test("A queued message carries the app's reason in the lede and the payload")
  func queued() async {
    let sender = FakeMessageSender()
    sender.outcome = .queued(
      name: "Refactor api", project: "armada", reason: "It reads it when its turn ends.")
    let result = await call(["session": "Refactor api", "text": "stop after this"], sender: sender)
    #expect(!result.isError)
    #expect(result.structuredContent?["sent"]?["status"] == .string("queued"))
    #expect(result.text == "Queued for Refactor api in armada. It reads it when its turn ends.")
  }

  @Test(
    "Empty, oversized or control-character text never reaches the sender",
    arguments: [
      "   ", String(repeating: "x", count: Tools.maxMessageCharacters + 1), "a\u{1B}[2Jb",
    ])
  func refusedText(_ text: String) async {
    let sender = FakeMessageSender()
    let result = await call(["session": "Docs", "text": .string(text)], sender: sender)
    #expect(result.isError)
    #expect(sender.requests.isEmpty)
  }

  @Test("A leading slash or dash is fine: the text never reaches a command line")
  func leadingCharacters() {
    #expect(Tools.messageRefusal("/compact when you are done") == nil)
    #expect(Tools.messageRefusal("- first, run the tests") == nil)
  }

  @Test("Codex, an unknown session and a missing text are refused")
  func refusedTargets() async {
    let sender = FakeMessageSender()
    let codex = await call(
      ["session": .string(FakeFleetSource.codexOpen), "text": "hi"], sender: sender)
    #expect(codex.isError)
    #expect(codex.text.contains("Codex"))
    let unknown = await call(["session": "nope", "text": "hi"], sender: sender)
    #expect(unknown.isError)
    let noText = await call(["session": "Docs"], sender: sender)
    #expect(noText.isError)
    #expect(sender.requests.isEmpty)
  }

  @Test("The app's refusal comes back word for word")
  func appRefusal() async {
    let sender = FakeMessageSender()
    sender.outcome = .refused("Turn on message delivery in Settings ▸ Supervisor first.")
    let result = await call(["session": "Docs", "text": "hi"], sender: sender)
    #expect(result.isError)
    #expect(result.text == "Turn on message delivery in Settings ▸ Supervisor first.")
  }
}
