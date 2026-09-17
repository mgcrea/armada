import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_get_projects")
struct ProjectsToolTests {

  private func call(
    _ arguments: JSONValue = .object([:]), on source: FakeFleetSource = FakeFleetSource()
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser()
    )
    .call(
      name: "armada_get_projects", arguments: arguments, allowWrites: false)
  }

  private func projects(_ result: ToolResult) throws -> [JSONValue] {
    try #require(result.structuredContent?["projects"]?.arrayValue)
  }

  @Test("Every saved project, with its tokens over three windows and its live sessions")
  func list() async throws {
    let result = await call()
    #expect(!result.isError)
    let listed = try projects(result)
    #expect(listed.count == 3)
    let armada = try #require(listed.first { $0["id"] == .string(FakeFleetSource.armadaProject) })
    #expect(armada["tokens"]?["7d"]?["total"] == .int(41_200_000))
    #expect(armada["tokens"]?["7d"]?["sessions"] == .int(18))
    #expect(armada["tokens"]?["30d"] != nil)
    #expect(armada["tokens"]?["all"] != nil)
    #expect(armada["live"]?[0]?["id"] == .string(FakeFleetSource.waiting))
    #expect(armada["byModel"] == nil, "the split is for one project at a time")
    #expect(result.text.hasPrefix("3 projects."))
    #expect(result.text.contains("armada: 41.2M tokens in 7 days"))
    #expect(result.structuredContent?["tokenNote"] != nil)
  }

  @Test("One project carries its split by model and by account")
  func single() async throws {
    let result = await call(["project": "armada"])
    #expect(!result.isError)
    let listed = try projects(result)
    #expect(listed.count == 1)
    #expect(listed[0]["byModel"]?.arrayValue?.count == 2)
    #expect(listed[0]["byAccount"]?[0]?["account"] == .string("Default"))
  }

  @Test(
    "A project is found by id, by an unshared 8-character prefix, by path or by exact name",
    arguments: [
      (FakeFleetSource.siteProject, FakeFleetSource.siteProject),
      ("7c1b0000", FakeFleetSource.almanacProject),
      ("/Users/me/armada/web/", FakeFleetSource.siteProject),
      ("armada site", FakeFleetSource.siteProject),
    ])
  func lookup(_ query: String, _ expected: String) async throws {
    let result = await call(["project": .string(query)])
    #expect(!result.isError, "\(query)")
    #expect(try projects(result).first?["id"] == .string(expected), "\(query)")
  }

  @Test("A prefix two projects share is refused with both named, never the first taken")
  func ambiguous() async throws {
    let result = await call(["project": "3f2a0000"])
    #expect(result.isError)
    let candidates = try #require(result.structuredContent?["candidates"]?.arrayValue)
    #expect(
      Set(candidates.compactMap { $0["id"]?.stringValue }) == [
        FakeFleetSource.armadaProject, FakeFleetSource.siteProject,
      ])
  }

  @Test("An unknown project is refused, naming the saved ones")
  func unknown() async {
    let result = await call(["project": "nope"])
    #expect(result.isError)
    #expect(result.text.contains("armada"))
    #expect(result.text.contains("almanac"))
  }

  @Test("A folder that is gone and an account not on this Mac are said, not hidden")
  func missing() async throws {
    let result = await call(["project": "almanac"])
    let project = try #require(try projects(result).first)
    #expect(project["missing"] == .bool(true))
    #expect(project["defaultAgent"]?["accountMissing"] == .bool(true))
  }

  @Test("While older transcripts are still being read, the lede says the totals are low")
  func incomplete() async throws {
    let source = FakeFleetSource()
    source.projectsFixture = FakeFleetSource.projects(complete: false)
    let result = await call(on: source)
    #expect(result.text.contains("still reading older transcripts (412 of 2290 files)"))
    #expect(result.structuredContent?["index"]?["complete"] == .bool(false))
  }

  @Test("No saved projects is a success that says where projects are added")
  func none() async throws {
    let source = FakeFleetSource()
    source.projectsFixture = FakeFleetSource.projects(list: [])
    let result = await call(on: source)
    #expect(!result.isError)
    #expect(try projects(result).isEmpty)
    #expect(result.text.contains("saved no projects"))
  }

  @Test("An unlicensed Armada says it is watching nothing")
  func notWatching() async {
    let source = FakeFleetSource()
    source.projectsFixture = FakeFleetSource.projects(isEntitled: false, list: [])
    let result = await call(on: source)
    #expect(result.structuredContent?["watching"] == .bool(false))
    #expect(result.text.contains("not an empty fleet"))
  }

  @Test("One projects hop, and no fleet snapshot")
  func oneHop() async {
    let source = FakeFleetSource()
    _ = await call(on: source)
    #expect(source.projectsCalls == 1)
    #expect(source.snapshotCalls == 0)
  }
}
