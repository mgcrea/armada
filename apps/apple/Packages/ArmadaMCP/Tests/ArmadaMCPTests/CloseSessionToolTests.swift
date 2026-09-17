import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_close_session")
struct CloseSessionToolTests {

  private func call(
    _ arguments: JSONValue, source: FakeFleetSource = FakeFleetSource(),
    closer: FakeSessionCloser = FakeSessionCloser(), allowWrites: Bool = true
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: closer, sender: FakeMessageSender()
    ).call(
      name: "armada_close_session", arguments: arguments, allowWrites: allowWrites)
  }

  @Test("Listed only while writes are allowed, and marked as destructive")
  func listing() throws {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender())
    #expect(!table.listing(allowWrites: false).contains { $0.name == "armada_close_session" })
    let tool = try #require(
      table.listing(allowWrites: true).first { $0.name == "armada_close_session" })
    #expect(tool.gate == .requiresWrites)
    #expect(!tool.annotations.readOnlyHint)
    #expect(tool.annotations.destructiveHint == true)
  }

  @Test("With the write switch off it is refused, and nothing is closed")
  func gateOff() async {
    let closer = FakeSessionCloser()
    let result = await call(
      ["session": .string(FakeFleetSource.idle)], closer: closer, allowWrites: false)
    #expect(result.isError)
    #expect(result.text.contains("Allow writes"))
    #expect(closer.requests.isEmpty)
  }

  @Test("An idle or waiting session is closed by name or prefix, without force")
  func closesQuietSessions() async {
    let closer = FakeSessionCloser()
    let byName = await call(["session": "Docs"], closer: closer)
    let byPrefix = await call(["session": "aaaaaaaa-1111"], closer: closer)
    #expect(!byName.isError)
    #expect(!byPrefix.isError)
    #expect(
      closer.requests == [
        CloseSessionRequest(sessionID: FakeFleetSource.idle, force: false),
        CloseSessionRequest(sessionID: FakeFleetSource.waiting, force: false),
      ])
    #expect(byName.text.contains("Closed Idle one"))
    #expect(byName.structuredContent?["closed"]?["id"] == .string(FakeFleetSource.idle))
    #expect(byName.structuredContent?["closed"]?["killed"] == .bool(false))
  }

  @Test(
    "A busy session is refused without force, and says probably when the state is inferred",
    arguments: [
      (FakeFleetSource.waitingTwin, "is working"),
      (FakeFleetSource.runningTool, "is probably running a tool"),
    ])
  func busyNeedsForce(_ id: String, _ phrase: String) async {
    let closer = FakeSessionCloser()
    let result = await call(["session": .string(id)], closer: closer)
    #expect(result.isError)
    #expect(result.text.contains(phrase))
    #expect(result.text.contains("force"))
    #expect(closer.requests.isEmpty)
  }

  @Test("With force a busy session reaches the closer, and force is passed on")
  func forced() async {
    let closer = FakeSessionCloser()
    let result = await call(
      ["session": .string(FakeFleetSource.runningTool), "force": true], closer: closer)
    #expect(!result.isError)
    #expect(
      closer.requests == [CloseSessionRequest(sessionID: FakeFleetSource.runningTool, force: true)])
  }

  @Test("A Codex session is refused with the reason")
  func codexRefused() async {
    let closer = FakeSessionCloser()
    let result = await call(["session": .string(FakeFleetSource.codexOpen)], closer: closer)
    #expect(result.isError)
    #expect(result.text.contains("Codex"))
    #expect(closer.requests.isEmpty)
  }

  @Test(
    "An ambiguous or unknown session never reaches the closer",
    arguments: ["Fix login copy2", "aaaaaaaa"])
  func refusedLookup(_ query: String) async {
    let closer = FakeSessionCloser()
    let result = await call(["session": .string(query)], closer: closer)
    #expect(result.isError)
    #expect(closer.requests.isEmpty)
  }

  @Test("The app's refusal comes back as the tool's error, word for word")
  func appRefusal() async {
    let closer = FakeSessionCloser()
    closer.outcome = .refused("That session has already ended.")
    let result = await call(["session": "Docs"], closer: closer)
    #expect(result.isError)
    #expect(result.text == "That session has already ended.")
  }

  @Test("A process that was killed, or has not exited, is reported as such")
  func killedAndLingering() async {
    let closer = FakeSessionCloser()
    closer.outcome = .closed(
      ClosedSession(name: "Docs", project: "armada", state: "idle", killed: true, exited: true))
    let killed = await call(["session": "Docs"], closer: closer)
    #expect(killed.text.contains("was killed"))

    closer.outcome = .closed(
      ClosedSession(name: "Docs", project: "armada", state: "idle", killed: true, exited: false))
    let lingering = await call(["session": "Docs"], closer: closer)
    #expect(lingering.text.contains("has not exited yet"))
  }

  @Test("An unlicensed Armada closes nothing")
  func notEntitled() async {
    let closer = FakeSessionCloser()
    let source = FakeFleetSource(FakeFleetSource.fleet(isEntitled: false))
    let result = await call(
      ["session": .string(FakeFleetSource.idle)], source: source, closer: closer)
    #expect(result.isError)
    #expect(closer.requests.isEmpty)
  }
}
