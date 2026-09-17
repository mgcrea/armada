import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

/// A fleet that moves: each snapshot is the next in the list, and the last one repeats.
private final class MovingFleetSource: FleetSource, @unchecked Sendable {
  private let lock = NSLock()
  private let fleets: [FleetSnapshot]
  private var index = 0

  init(_ fleets: [FleetSnapshot]) { self.fleets = fleets }

  var calls: Int { lock.withLock { index } }

  func snapshot() async -> FleetSnapshot {
    lock.withLock {
      defer { index += 1 }
      return fleets[min(index, fleets.count - 1)]
    }
  }

  func host(forClaudeSession id: String) async -> FleetSnapshot.Host? { nil }
  func projects() async -> ProjectsSnapshot { FakeFleetSource.projects() }
}

@Suite("armada_wait")
struct WaitToolTests {

  private static func fleet(_ sessions: [FleetSnapshot.ClaudeSession]) -> FleetSnapshot {
    FakeFleetSource.fleet(claude: [
      FleetSnapshot.ClaudeAccount(
        id: "/Users/me/.claude", name: "Default", plan: nil, modelID: nil, usage: nil,
        quotaHit: nil, sessions: sessions)
    ])
  }

  private static func session(_ id: String, _ state: String, ago: TimeInterval = 60)
    -> FleetSnapshot.ClaudeSession
  {
    FakeFleetSource.claudeSession(
      id, name: "Session \(id.prefix(4))", state: state,
      waitingFor: state == "waiting" ? "permission prompt" : nil, ago: ago)
  }

  private func call(_ arguments: JSONValue, on source: any FleetSource) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(),
      waitPoll: .milliseconds(5)
    ).call(name: "armada_wait", arguments: arguments, allowWrites: false)
  }

  private let a = "aaaaaaaa-0000-4000-8000-000000000001"
  private let b = "bbbbbbbb-0000-4000-8000-000000000002"

  @Test("Read-only, listed without the write switch, and pre-allowed for the supervisor")
  func listing() throws {
    let table = Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser())
    let tool = try #require(table.listing(allowWrites: false).first { $0.name == "armada_wait" })
    #expect(tool.annotations.readOnlyHint)
    #expect(Tools.readToolNames.contains("armada_wait"))
  }

  @Test("Returns when a session starts waiting, with what it waits for")
  func attention() async throws {
    let source = MovingFleetSource([
      Self.fleet([Self.session(a, "working"), Self.session(b, "idle")]),
      Self.fleet([Self.session(a, "working"), Self.session(b, "idle")]),
      Self.fleet([Self.session(a, "waiting", ago: 1), Self.session(b, "idle")]),
    ])
    let result = await call(["timeout_seconds": 5], on: source)
    #expect(!result.isError)
    #expect(result.structuredContent?["timedOut"] == .bool(false))
    let change = try #require(result.structuredContent?["changes"]?.arrayValue?.first)
    #expect(change["id"] == .string(a))
    #expect(change["from"] == .string("working"))
    #expect(change["to"] == .string("waiting"))
    #expect(change["waitingFor"] == .string("permission prompt"))
    #expect(result.text == "1 session now wants the person.")
  }

  @Test("A session already waiting at the start does not end the wait")
  func alreadyWaiting() async {
    let fleet = Self.fleet([Self.session(a, "waiting")])
    let result = await call(["timeout_seconds": 1], on: MovingFleetSource([fleet]))
    #expect(!result.isError)
    #expect(result.structuredContent?["timedOut"] == .bool(true))
  }

  @Test("A session that asks again after being answered counts, by its status time")
  func asksAgain() async {
    let source = MovingFleetSource([
      Self.fleet([Self.session(a, "waiting", ago: 60)]),
      Self.fleet([Self.session(a, "waiting", ago: 1)]),
    ])
    let result = await call(["timeout_seconds": 5], on: source)
    #expect(result.structuredContent?["timedOut"] == .bool(false))
  }

  @Test("`until: change` reports a session ending as gone, and ignores unnamed sessions")
  func changeAndFilter() async throws {
    let source = MovingFleetSource([
      Self.fleet([Self.session(a, "idle"), Self.session(b, "idle")]),
      Self.fleet([Self.session(a, "idle"), Self.session(b, "working")]),
      Self.fleet([Self.session(b, "working")]),
    ])
    let result = await call(
      ["sessions": [.string(a)], "until": "change", "timeout_seconds": 5], on: source)
    let changes = try #require(result.structuredContent?["changes"]?.arrayValue)
    #expect(changes.count == 1)
    #expect(changes.first?["id"] == .string(a))
    #expect(changes.first?["to"] == .string("gone"))
    #expect(source.calls == 3)
  }

  @Test("An unknown session or an unknown `until` is refused before waiting")
  func refusals() async {
    let source = MovingFleetSource([Self.fleet([Self.session(a, "idle")])])
    let unknown = await call(["sessions": ["nope"], "timeout_seconds": 5], on: source)
    #expect(unknown.isError)
    let badUntil = await call(["until": "forever"], on: source)
    #expect(badUntil.isError)
    #expect(source.calls == 2)
  }

  @Test("An unlicensed Armada waits for nothing")
  func notEntitled() async {
    let source = MovingFleetSource([FakeFleetSource.fleet(isEntitled: false, claude: [])])
    let result = await call(["timeout_seconds": 5], on: source)
    #expect(result.isError)
    #expect(source.calls == 1)
  }
}
