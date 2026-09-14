import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("Armada tools")
struct ToolsTests {

  private func call(
    _ name: String, _ arguments: JSONValue = .object([:]),
    on source: FakeFleetSource = FakeFleetSource()
  ) async -> ToolResult {
    await Tools.table(source: source).call(name: name, arguments: arguments, allowWrites: false)
  }

  private func ids(_ result: ToolResult, _ key: String = "sessions") throws -> [String] {
    try #require(result.structuredContent?[key]?.arrayValue).compactMap { $0["id"]?.stringValue }
  }

  // MARK: - The listing

  @Test("Five tools, every one read-only and never behind the write switch")
  func listing() {
    let table = Tools.table(source: FakeFleetSource())
    let listed = table.listing(allowWrites: false)
    #expect(listed.count == 5)
    #expect(Set(listed.map(\.name)) == Set(table.listing(allowWrites: true).map(\.name)))
    for tool in listed {
      #expect(tool.annotations.readOnlyHint, "\(tool.name)")
      #expect(tool.gate == .always, "\(tool.name)")
    }
  }

  @Test("Every tool description stays inside its context budget")
  func descriptionBudget() {
    for tool in Tools.table(source: FakeFleetSource()).listing(allowWrites: false) {
      let bytes = MCPJSON.string(tool.json).utf8.count
      #expect(bytes < 1_400, "\(tool.name) is \(bytes) bytes")
    }
  }

  /// The "hop once" rule, as a test. Two hops can straddle a rescan and pair one session's
  /// state with another rescan's context.
  @Test(
    "Each call takes exactly one snapshot",
    arguments: [
      "armada_needs_attention", "armada_get_fleet", "armada_get_usage",
    ])
  func oneSnapshotPerCall(_ name: String) async {
    let source = FakeFleetSource()
    _ = await call(name, on: source)
    #expect(source.snapshotCalls == 1)
  }

  // MARK: - What needs me

  /// Urgency before recency: the inferred runningTool moved most recently and still comes
  /// last, because a session stopped on a prompt is the one the person can act on.
  @Test("Waiting sessions lead, most recent first across accounts, then inferred ones")
  func attentionOrder() async throws {
    let result = await call("armada_needs_attention")
    #expect(!result.isError)
    #expect(
      try ids(result) == [
        FakeFleetSource.otherAccountWaiting, FakeFleetSource.waiting, FakeFleetSource.runningTool,
      ])
    #expect(result.text.contains("permission prompt"))
    #expect(result.text.contains("probably running a tool"))
  }

  @Test("Codex is left out, and the answer says why rather than going quiet")
  func codexExcluded() async throws {
    let result = await call("armada_needs_attention")
    let codex = try #require(result.structuredContent?["codex"])
    #expect(codex["excluded"] == .bool(true))
    #expect(codex["openSessions"] == .int(2))
    #expect(codex["reason"]?.stringValue?.contains("awaitingInput") == true)
  }

  @Test("Nothing waiting is a success, not an error")
  func nothingWaiting() async throws {
    let source = FakeFleetSource(
      FakeFleetSource.fleet(claude: [
        FleetSnapshot.ClaudeAccount(
          id: "a", name: "A", plan: nil, modelID: nil, usage: nil, quotaHit: nil,
          sessions: [FakeFleetSource.claudeSession("x", name: "X", state: "idle", ago: 1)])
      ]))
    let result = await call("armada_needs_attention", on: source)
    #expect(!result.isError)
    #expect(result.text == "Nothing is waiting on you.")
    #expect(try ids(result).isEmpty)
  }

  /// A stopped Armada holds nothing. An agent told "nothing is waiting" by an unlicensed
  /// copy would be told something false.
  @Test("An unlicensed Armada says it is watching nothing, in the payload and the prose")
  func notWatching() async throws {
    let source = FakeFleetSource(FakeFleetSource.fleet(isEntitled: false, claude: []))
    for name in ["armada_needs_attention", "armada_get_fleet", "armada_get_usage"] {
      let result = await call(name, on: source)
      #expect(result.structuredContent?["watching"] == .bool(false), "\(name)")
      #expect(result.text.contains("not an empty fleet"), "\(name)")
    }
  }

  // MARK: - The fleet

  @Test("The fleet lists idle Claude sessions and hides ended Codex threads and subagents")
  func fleetDefaults() async throws {
    let listed = try ids(await call("armada_get_fleet"))
    #expect(listed.contains(FakeFleetSource.idle))
    #expect(listed.contains(FakeFleetSource.codexOpen))
    #expect(!listed.contains(FakeFleetSource.codexEnded))
    #expect(!listed.contains(FakeFleetSource.codexSubagent))
    // What wants the person comes first, whichever vendor it belongs to.
    #expect(listed.first == FakeFleetSource.otherAccountWaiting)
  }

  @Test("The fleet's filters do what they say")
  func fleetFilters() async throws {
    let noIdle = try ids(await call("armada_get_fleet", ["include_idle": false]))
    #expect(!noIdle.contains(FakeFleetSource.idle))

    let everything = try ids(
      await call("armada_get_fleet", ["include_ended": true, "include_subagents": true]))
    #expect(everything.contains(FakeFleetSource.codexEnded))
    #expect(everything.contains(FakeFleetSource.codexSubagent))

    let codexOnly = await call("armada_get_fleet", ["vendor": "codex"])
    #expect(try ids(codexOnly) == [FakeFleetSource.codexOpen])
    #expect(try #require(codexOnly.structuredContent?["accounts"]?.arrayValue).count == 1)
  }

  @Test("The lede counts what the person will care about")
  func fleetLede() async {
    let result = await call("armada_get_fleet")
    #expect(result.text.hasPrefix("3 accounts, 6 sessions: 2 waiting for you"))
  }

  // MARK: - One session

  @Test("A session is found by id, by an 8-character prefix, or by exact name")
  func lookup() async throws {
    for query in [FakeFleetSource.runningTool, "bbbbbbbb", "BBBBBBBB-2222", "refactor API"] {
      let result = await call("armada_get_session", ["session": .string(query)])
      #expect(!result.isError, "\(query)")
      #expect(
        result.structuredContent?["session"]?["id"] == .string(FakeFleetSource.runningTool),
        "\(query)")
    }
  }

  @Test("A prefix shared by two sessions is refused with both named, never the first taken")
  func ambiguous() async throws {
    let result = await call("armada_get_session", ["session": "aaaaaaaa"])
    #expect(result.isError)
    let candidates = try #require(result.structuredContent?["candidates"]?.arrayValue)
    #expect(
      Set(candidates.compactMap { $0["id"]?.stringValue }) == [
        FakeFleetSource.waiting, FakeFleetSource.waitingTwin,
      ])
  }

  @Test("A prefix shorter than eight characters matches nothing", arguments: ["bbbb", "b", "   "])
  func shortPrefix(_ query: String) async {
    let result = await call("armada_get_session", ["session": .string(query)])
    #expect(result.isError)
  }

  @Test("The host is a second hop, attached to Claude sessions only")
  func host() async throws {
    let source = FakeFleetSource()
    source.hosts[FakeFleetSource.waiting] = .init(
      name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", pid: 99)
    let result = await call(
      "armada_get_session", ["session": .string(FakeFleetSource.waiting)], on: source)
    #expect(result.structuredContent?["session"]?["host"]?["name"] == .string("Visual Studio Code"))
    #expect(result.text.contains("permission prompt"))
  }

  // MARK: - Usage

  @Test("Unread usage is null, never a zero")
  func unreadUsage() async throws {
    let result = await call("armada_get_usage", ["account": "work"])
    #expect(!result.isError)
    let account = try #require(result.structuredContent?["accounts"]?[0])
    #expect(account["usage"] == .null)
    #expect(result.text.contains("not read yet"))
  }

  @Test("Usage carries both windows, the reset countdown and the source")
  func usage() async throws {
    let result = await call("armada_get_usage", ["account": "Default"])
    let usage = try #require(result.structuredContent?["accounts"]?[0]?["usage"])
    #expect(usage["fiveHour"]?["utilization"] == .int(17))
    #expect(usage["fiveHour"]?["resetsIn"] == .string("2h 10m"))
    #expect(usage["source"] == .string("live"))
    #expect(usage["ageSeconds"] == .int(30))
    #expect(result.text.contains("5h 17%, resets in 2h 10m"))
  }

  @Test("An unknown account is refused, naming the real ones")
  func unknownAccount() async {
    let result = await call("armada_get_usage", ["account": "nope"])
    #expect(result.isError)
    #expect(result.text.contains("Default"))
    #expect(result.text.contains("Work"))
  }

  // MARK: - Transcripts

  @Test("A session that was never prompted has no transcript, and says so")
  func neverPrompted() async {
    let result = await call("armada_read_transcript", ["session": .string(FakeFleetSource.idle)])
    #expect(result.isError)
    #expect(result.text.contains("never been prompted"))
  }

  @Test("The transcript tool returns the newest turns, capped, and leads with the last words")
  func transcriptEndToEnd() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "armada-mcp-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try TranscriptFixtures.claude.joined(separator: "\n").write(
      to: url, atomically: true, encoding: .utf8)

    let source = FakeFleetSource(
      FakeFleetSource.fleet(transcriptPath: url.path(percentEncoded: false)))
    let result = await call(
      "armada_read_transcript", ["session": .string(FakeFleetSource.waiting), "limit": 2],
      on: source)
    #expect(!result.isError)
    let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
    #expect(entries.count == 2)
    #expect(result.structuredContent?["omitted"]?["entries"] != nil)
    #expect(result.text.hasPrefix("Fix login last said: Done. The test passes now."))
    #expect(result.structuredContent?["note"] != nil)
  }
}
