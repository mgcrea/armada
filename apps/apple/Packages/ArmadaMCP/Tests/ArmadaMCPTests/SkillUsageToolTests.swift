import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_get_skill_usage")
struct SkillUsageToolTests {

  private func call(
    _ arguments: JSONValue = .object([:]), on source: FakeFleetSource = FakeFleetSource()
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(), schedules: FakeScheduleStore()
    )
    .call(name: "armada_get_skill_usage", arguments: arguments, allowWrites: false)
  }

  private func skills(_ result: ToolResult) throws -> [JSONValue] {
    try #require(result.structuredContent?["skills"]?.arrayValue)
  }

  /// name → total, the shape most assertions need.
  private func totals(_ result: ToolResult) throws -> [String: Int] {
    var totals: [String: Int] = [:]
    for skill in try skills(result) {
      let name = try #require(skill["name"]?.stringValue)
      totals[name] = skill["total"]?.intValue
    }
    return totals
  }

  @Test("By default: 30 days, every account and project, the busiest first, built-ins left out")
  func defaults() async throws {
    let result = await call()
    #expect(!result.isError)
    #expect(result.structuredContent?["window"] == .string("30d"))
    let listed = try skills(result)
    #expect(
      listed.compactMap { $0["name"]?.stringValue } == [
        "code-health", "distill", "superpowers:brainstorming",
      ])
    #expect(result.structuredContent?["builtinsHidden"] == .int(1))

    let health = listed[0]
    #expect(health["source"] == .string("skill"))
    #expect(health["total"] == .int(14))
    #expect(health["auto"] == .int(4))
    #expect(health["slash"] == .int(10))
    let newest = FakeFleetSource.now.addingTimeInterval(-3_600)
    #expect(
      health["lastUsed"]
        == .string(
          newest.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())))
    #expect(listed[1]["source"] == .string("command"), "a use outside every project counts")
    #expect(listed[2]["source"] == .string("plugin"))

    #expect(
      result.text
        == "3 skills used in the last 30 days: code-health 14 (10 typed); distill 8 (8 typed); "
        + "superpowers:brainstorming 6.")
  }

  @Test("includeBuiltins lists the built-in commands too")
  func builtins() async throws {
    let result = await call(["includeBuiltins": true])
    let compact = try #require(try skills(result).first { $0["name"] == "compact" })
    #expect(compact["source"] == .string("builtin"))
    #expect(compact["total"] == .int(18))
    #expect(result.structuredContent?["builtinsHidden"] == .int(0))
  }

  @Test("One project sums only its own uses, not its subfolder project's")
  func project() async throws {
    let result = await call(["project": .string(FakeFleetSource.armadaProject)])
    #expect(!result.isError)
    #expect(try totals(result) == ["code-health": 10, "superpowers:brainstorming": 6])
    #expect(result.structuredContent?["builtinsHidden"] == .int(1))
    #expect(result.structuredContent?["project"]?["name"] == .string("armada"))
  }

  @Test("A project prefix two projects share is refused with both named")
  func ambiguousProject() async throws {
    let result = await call(["project": "3f2a0000"])
    #expect(result.isError)
    let candidates = try #require(result.structuredContent?["candidates"]?.arrayValue)
    #expect(
      Set(candidates.compactMap { $0["id"]?.stringValue }) == [
        FakeFleetSource.armadaProject, FakeFleetSource.siteProject,
      ])
  }

  @Test(
    "An account is found by id or by its name in any case",
    arguments: [
      ("/Users/me/.claude", ["code-health": 10, "distill": 8]),
      ("work", ["code-health": 4, "superpowers:brainstorming": 6]),
    ])
  func account(_ query: String, _ expected: [String: Int]) async throws {
    let result = await call(["account": .string(query)])
    #expect(!result.isError, "\(query)")
    #expect(try totals(result) == expected, "\(query)")
  }

  @Test("An unknown account is refused, naming the accounts")
  func unknownAccount() async {
    let result = await call(["account": "Nope"])
    #expect(result.isError)
    #expect(result.text.contains("\"Nope\""))
    #expect(result.text.contains("Default"))
    #expect(result.text.contains("Work"))
  }

  @Test("A name two accounts share takes both, never just the first")
  func sharedAccountName() async throws {
    let source = FakeFleetSource()
    let fixture = FakeFleetSource.skills()
    source.skillsFixture = SkillsSnapshot(
      takenAt: fixture.takenAt, isEntitled: true, index: fixture.index,
      projects: fixture.projects,
      accounts: [
        .init(id: "/Users/me/.claude", name: "Default"),
        .init(id: "/Users/me/.claude-work", name: "Default"),
      ],
      tallies: fixture.tallies)
    let result = await call(["account": "default"], on: source)
    #expect(try totals(result)["code-health"] == 14)
    #expect(result.structuredContent?["accounts"]?.arrayValue?.count == 2)
  }

  @Test(
    "A window selects its own tallies",
    arguments: [("7d", 7), ("30d", 14), ("all", 21)])
  func window(_ window: String, _ codeHealth: Int) async throws {
    let result = await call(["window": .string(window)])
    #expect(!result.isError)
    #expect(result.structuredContent?["window"] == .string(window))
    #expect(try totals(result)["code-health"] == codeHealth)
  }

  @Test("The lede words each window its own way")
  func windowWording() async {
    #expect((await call(["window": "7d"])).text.hasPrefix("3 skills used in the last 7 days: "))
    #expect((await call(["window": "all"])).text.hasPrefix("3 skills used over all time: "))
  }

  @Test("A window that is not one of the three is refused")
  func badWindow() async {
    let result = await call(["window": "90d"])
    #expect(result.isError)
    #expect(result.text == "Pass window: 7d, 30d or all.")
  }

  @Test("The lede names five skills and counts the rest")
  func lede() async {
    let source = FakeFleetSource()
    source.skillsFixture = FakeFleetSource.skills(
      tallies: (1...7).map {
        .init(
          projectID: nil, accountID: "/Users/me/.claude", skill: "s\($0)", source: "skill",
          window: "30d", auto: 10 - $0, slash: 0, lastUsed: FakeFleetSource.now)
      })
    let result = await call(on: source)
    #expect(
      result.text
        == "7 skills used in the last 30 days: s1 9; s2 8; s3 7; s4 6; s5 5; and 2 more.")
  }

  @Test("No uses is a success that says so")
  func none() async throws {
    let source = FakeFleetSource()
    source.skillsFixture = FakeFleetSource.skills(tallies: [])
    let result = await call(on: source)
    #expect(!result.isError)
    #expect(try skills(result).isEmpty)
    #expect(result.text == "No skills used in the last 30 days.")
  }

  @Test("While older transcripts are still being read, the index and the lede say so")
  func incomplete() async throws {
    let source = FakeFleetSource()
    source.skillsFixture = FakeFleetSource.skills(complete: false)
    let result = await call(on: source)
    let index = try #require(result.structuredContent?["index"])
    #expect(index["complete"] == .bool(false))
    #expect(index["filesRead"] == .int(412))
    #expect(index["filesTotal"] == .int(2_290))
    #expect(index["since"]?.stringValue != nil)
    #expect(result.text.hasPrefix("Armada is still reading older transcripts"))
  }

  @Test("The answer says Codex is not counted")
  func note() async {
    let result = await call()
    #expect(
      result.structuredContent?["note"]
        == .string("Claude Code only. Codex records no skill use of its own."))
  }

  @Test("An unlicensed Armada says it is watching nothing")
  func notWatching() async {
    let source = FakeFleetSource()
    source.skillsFixture = FakeFleetSource.skills(isEntitled: false, tallies: [])
    let result = await call(on: source)
    #expect(result.structuredContent?["watching"] == .bool(false))
    #expect(result.text.contains("not an empty fleet"))
  }

  @Test("Read-only, ungated, and pre-allowed beside the other reads")
  func listed() throws {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(), schedules: FakeScheduleStore())
    let tool = try #require(
      table.listing(allowWrites: false).first { $0.name == "armada_get_skill_usage" })
    #expect(tool.annotations.readOnlyHint)
    #expect(tool.gate == .always)
    #expect(Tools.readToolNames.contains("armada_get_skill_usage"))
  }

  @Test("One skills hop, and no fleet or projects snapshot")
  func oneHop() async {
    let source = FakeFleetSource()
    _ = await call(on: source)
    #expect(source.skillsCalls == 1)
    #expect(source.snapshotCalls == 0)
    #expect(source.projectsCalls == 0)
  }
}
