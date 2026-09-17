import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_focus_session")
struct FocusSessionToolTests {

  private func call(
    _ arguments: JSONValue, source: FakeFleetSource = FakeFleetSource(),
    focuser: FakeSessionFocuser = FakeSessionFocuser(), allowWrites: Bool = true
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: focuser
    ).call(
      name: "armada_focus_session", arguments: arguments, allowWrites: allowWrites)
  }

  @Test("Listed only while writes are allowed, and marked as harmless to repeat")
  func listing() throws {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser())
    #expect(!table.listing(allowWrites: false).contains { $0.name == "armada_focus_session" })
    let tool = try #require(
      table.listing(allowWrites: true).first { $0.name == "armada_focus_session" })
    #expect(tool.gate == .requiresWrites)
    #expect(!tool.annotations.readOnlyHint)
    #expect(tool.annotations.destructiveHint == false)
    #expect(tool.annotations.idempotentHint == true)
  }

  @Test("With the write switch off it is refused, and nothing is raised")
  func gateOff() async {
    let focuser = FakeSessionFocuser()
    let result = await call(
      ["session": .string(FakeFleetSource.waiting)], focuser: focuser, allowWrites: false)
    #expect(result.isError)
    #expect(result.text.contains("Allow writes"))
    #expect(focuser.requests.isEmpty)
  }

  @Test("A session found by name reaches the focuser by its exact id, whatever its state")
  func focuses() async {
    let focuser = FakeSessionFocuser()
    let byName = await call(["session": "Fix login"], focuser: focuser)
    let busy = await call(["session": .string(FakeFleetSource.runningTool)], focuser: focuser)
    #expect(!byName.isError)
    #expect(!busy.isError)
    #expect(
      focuser.requests == [
        FocusSessionRequest(sessionID: FakeFleetSource.waiting),
        FocusSessionRequest(sessionID: FakeFleetSource.runningTool),
      ])
    #expect(byName.text == "Brought Fix login in armada forward in Code.")
    #expect(byName.structuredContent?["focused"]?["id"] == .string(FakeFleetSource.waiting))
    #expect(byName.structuredContent?["focused"]?["reach"] == "window")
    #expect(byName.structuredContent?["focused"]?["accessibilityGranted"] == nil)
  }

  @Test("The lede says how close the raise got, and why it stopped at the application")
  func ledes() async {
    let focuser = FakeSessionFocuser()
    focuser.outcome = .focused(
      FocusedSession(
        name: "Fix login", project: "armada", app: "Code", reach: .tab, accessibilityGranted: true))
    #expect(await call(["session": "Fix login"], focuser: focuser).text.contains("on its tab"))

    focuser.outcome = .focused(
      FocusedSession(
        name: "Fix login", project: "armada", app: "Terminal", reach: .application,
        accessibilityGranted: true))
    #expect(
      await call(["session": "Fix login"], focuser: focuser).text.contains("no window of it"))

    focuser.outcome = .focused(
      FocusedSession(
        name: "Fix login", project: "armada", app: "Terminal", reach: .application,
        accessibilityGranted: false))
    let ungranted = await call(["session": "Fix login"], focuser: focuser)
    #expect(ungranted.text.contains("Accessibility"))
    #expect(ungranted.structuredContent?["focused"]?["accessibilityGranted"] == .bool(false))
  }

  @Test("A Codex session is refused with the reason")
  func codexRefused() async {
    let focuser = FakeSessionFocuser()
    let result = await call(["session": .string(FakeFleetSource.codexOpen)], focuser: focuser)
    #expect(result.isError)
    #expect(result.text.contains("Codex"))
    #expect(focuser.requests.isEmpty)
  }

  @Test(
    "An ambiguous or unknown session never reaches the focuser",
    arguments: ["Fix login copy2", "aaaaaaaa"])
  func refusedLookup(_ query: String) async {
    let focuser = FakeSessionFocuser()
    let result = await call(["session": .string(query)], focuser: focuser)
    #expect(result.isError)
    #expect(focuser.requests.isEmpty)
  }

  @Test("The app's refusal comes back as the tool's error, word for word")
  func appRefusal() async {
    let focuser = FakeSessionFocuser()
    focuser.outcome = .refused("Fix login has no app window.")
    let result = await call(["session": "Fix login"], focuser: focuser)
    #expect(result.isError)
    #expect(result.text == "Fix login has no app window.")
  }

  @Test("An unlicensed Armada raises nothing")
  func notEntitled() async {
    let focuser = FakeSessionFocuser()
    let source = FakeFleetSource(FakeFleetSource.fleet(isEntitled: false))
    let result = await call(
      ["session": .string(FakeFleetSource.waiting)], source: source, focuser: focuser)
    #expect(result.isError)
    #expect(focuser.requests.isEmpty)
  }
}
