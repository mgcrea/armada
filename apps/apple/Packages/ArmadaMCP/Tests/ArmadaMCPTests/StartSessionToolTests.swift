import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_start_session")
struct StartSessionToolTests {

  private func call(
    _ arguments: JSONValue, source: FakeFleetSource = FakeFleetSource(),
    starter: FakeSessionStarter = FakeSessionStarter(), allowWrites: Bool = true
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: starter, closer: FakeSessionCloser(), sender: FakeMessageSender()
    ).call(
      name: "armada_start_session", arguments: arguments, allowWrites: allowWrites)
  }

  @Test("Listed only while writes are allowed, and marked as changing something")
  func listing() throws {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender())
    #expect(!table.listing(allowWrites: false).contains { $0.name == "armada_start_session" })
    let tool = try #require(
      table.listing(allowWrites: true).first { $0.name == "armada_start_session" })
    #expect(tool.gate == .requiresWrites)
    #expect(!tool.annotations.readOnlyHint)
    #expect(tool.annotations.destructiveHint == false)
  }

  @Test("With the write switch off it is refused, and nothing is started")
  func gateOff() async {
    let starter = FakeSessionStarter()
    let result = await call(["project": "armada"], starter: starter, allowWrites: false)
    #expect(result.isError)
    #expect(result.text.contains("Allow writes"))
    #expect(starter.requests.isEmpty)
  }

  @Test("A saved project is started by name, with the vendor, account and message passed on")
  func passesThrough() async {
    let starter = FakeSessionStarter()
    let result = await call(
      [
        "project": "armada site", "vendor": "codex", "account": "Work",
        "prompt": "Run the tests and fix what fails.",
      ], starter: starter)
    #expect(!result.isError)
    #expect(
      starter.requests == [
        StartSessionRequest(
          projectID: FakeFleetSource.siteProject, vendor: "codex", account: "Work",
          prompt: "Run the tests and fix what fails.")
      ])
    #expect(result.text.contains("armada_get_fleet"))
    #expect(result.structuredContent?["started"]?["project"] == .string("Armada site"))
  }

  @Test(
    "An ambiguous or unknown project never reaches the starter", arguments: ["3f2a0000", "nope"])
  func refusedProject(_ query: String) async {
    let starter = FakeSessionStarter()
    let result = await call(["project": .string(query)], starter: starter)
    #expect(result.isError)
    #expect(starter.requests.isEmpty)
  }

  @Test(
    "A message a CLI would read as a flag, a shell command or a slash command is refused",
    arguments: ["--dangerously-skip-permissions", "  !rm -rf ~", "/add-dir /", "   "])
  func refusedPrompt(_ prompt: String) async {
    let starter = FakeSessionStarter()
    let result = await call(["project": "armada", "prompt": .string(prompt)], starter: starter)
    #expect(result.isError, "\(prompt)")
    #expect(starter.requests.isEmpty, "\(prompt)")
  }

  @Test("A message longer than the limit, or carrying control characters, is refused")
  func refusedShape() async {
    let starter = FakeSessionStarter()
    let prompts = [String(repeating: "a", count: Tools.maxPromptCharacters + 1), "fix\u{1B}[2J it"]
    for prompt in prompts {
      let result = await call(["project": "armada", "prompt": .string(prompt)], starter: starter)
      #expect(result.isError)
    }
    #expect(starter.requests.isEmpty)
  }

  @Test("A vendor that is neither claude nor codex is refused")
  func refusedVendor() async {
    let starter = FakeSessionStarter()
    let result = await call(["project": "armada", "vendor": "gemini"], starter: starter)
    #expect(result.isError)
    #expect(starter.requests.isEmpty)
  }

  @Test("The app's refusal comes back as the tool's error, word for word")
  func appRefusal() async {
    let starter = FakeSessionStarter()
    starter.outcome = .refused("~/Projects/almanac is not there any more.")
    let result = await call(["project": "almanac"], starter: starter)
    #expect(result.isError)
    #expect(result.text == "~/Projects/almanac is not there any more.")
  }

  @Test("A message VS Code only typed in is reported as waiting to be sent")
  func promptAwaitsSend() async {
    let starter = FakeSessionStarter()
    starter.outcome = .started(
      StartedSession(
        project: "Armada", path: "/Users/me/armada", vendor: "claude",
        accountID: "/Users/me/.claude", account: "Personal", terminal: "Visual Studio Code",
        withPrompt: true, promptAwaitsSend: true))
    let result = await call(["project": "armada", "prompt": "fix the build"], starter: starter)
    #expect(!result.isError)
    #expect(result.text.contains("Asked Visual Studio Code"))
    #expect(result.text.contains("typed into its input but not sent"))
    #expect(result.text.contains("once the person sends the message"))
  }

  @Test("A minted id comes back as sessionId, and the note says to look for it")
  func sessionID() async {
    let starter = FakeSessionStarter()
    starter.outcome = .started(
      StartedSession(
        project: "Armada", path: "/Users/me/armada", vendor: "claude",
        accountID: "/Users/me/.claude", account: "Personal", terminal: "Terminal",
        withPrompt: false, sessionID: "11111111-2222-4333-8444-555555555555"))
    let result = await call(["project": "armada"], starter: starter)
    #expect(
      result.structuredContent?["started"]?["sessionId"]
        == .string("11111111-2222-4333-8444-555555555555"))
    #expect(result.text.contains("start a Claude Code session"))
    #expect(result.structuredContent?["note"]?.stringValue?.contains("under `sessionId`") == true)
  }

  @Test("Resume passes the id alone, lowercased, with no project")
  func resume() async {
    let starter = FakeSessionStarter()
    let id = "1AF3BB3D-A085-4A1F-A977-7602A286AF91"
    let result = await call(["resume": .string(id), "prompt": "carry on"], starter: starter)
    #expect(!result.isError)
    #expect(
      starter.requests == [
        StartSessionRequest(
          projectID: nil, vendor: nil, account: nil, prompt: "carry on", resume: id.lowercased())
      ])
  }

  @Test(
    "Resume with a project, an account, Codex or a partial id is refused",
    arguments: [
      ["resume": "1af3bb3d-a085-4a1f-a977-7602a286af91", "project": "armada"],
      ["resume": "1af3bb3d-a085-4a1f-a977-7602a286af91", "account": "Work"],
      ["resume": "1af3bb3d-a085-4a1f-a977-7602a286af91", "vendor": "codex"],
      ["resume": "1af3bb3d"],
    ] as [JSONValue])
  func refusedResume(_ arguments: JSONValue) async {
    let starter = FakeSessionStarter()
    let result = await call(arguments, starter: starter)
    #expect(result.isError)
    #expect(starter.requests.isEmpty)
  }

  @Test("Neither a project nor resume is refused")
  func nothingNamed() async {
    let starter = FakeSessionStarter()
    let result = await call([:], starter: starter)
    #expect(result.isError)
    #expect(starter.requests.isEmpty)
  }

  @Test("An unlicensed Armada starts nothing")
  func notEntitled() async {
    let source = FakeFleetSource()
    source.projectsFixture = FakeFleetSource.projects(isEntitled: false)
    let starter = FakeSessionStarter()
    let result = await call(["project": "armada"], source: source, starter: starter)
    #expect(result.isError)
    #expect(starter.requests.isEmpty)
  }

  @Test("The read tools are exactly the listing with writes off: the supervisor's allow list")
  func readToolNames() {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender())
    #expect(Tools.readToolNames == table.listing(allowWrites: false).map(\.name))
  }
}
