import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("armada_get_build_slots")
struct BuildSlotsToolTests {

  private func table() -> ToolTable {
    Tools.table(
      source: FakeFleetSource(), starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(), schedules: FakeScheduleStore())
  }

  private func call(
    _ name: String, _ arguments: JSONValue = .object([:]), on source: FakeFleetSource
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(), schedules: FakeScheduleStore()
    )
    .call(name: name, arguments: arguments, allowWrites: false)
  }

  private static let startedAt = FakeFleetSource.now.addingTimeInterval(-90)
  private static let waitingSince = FakeFleetSource.now.addingTimeInterval(-30)

  /// One holder in slot 0, started by the idle Claude session, and one waiter held back by
  /// memory, started by the open Codex thread.
  private static func busy() -> BuildSlotsSnapshot {
    BuildSlotsSnapshot(
      enabled: true, slots: 2, memoryRule: "warning", memoryPressure: "warning",
      holders: [
        .init(
          slot: 0, pid: 501, label: "armada", cwd: "/Users/me/armada", tool: "swift",
          argv: ["swift", "test"], since: startedAt, waitsOnMemory: false,
          session: .init(id: FakeFleetSource.idle, vendor: "claude", title: "Docs"))
      ],
      waiters: [
        .init(
          slot: nil, pid: 502, label: "armada", cwd: "/Users/me/armada", tool: "xcodebuild",
          argv: ["xcodebuild", "build"], since: waitingSince, waitsOnMemory: true,
          session: .init(id: FakeFleetSource.codexOpen, vendor: "codex", title: "Codex thread"))
      ])
  }

  private func source(_ slots: BuildSlotsSnapshot) -> FakeFleetSource {
    let source = FakeFleetSource()
    source.buildSlotsFixture = slots
    return source
  }

  @Test("Listed as a read tool, never behind the write gate")
  func listedAsRead() {
    #expect(Tools.readToolNames.contains("armada_get_build_slots"))
    #expect(!Tools.writeTools.contains("armada_get_build_slots"))
    let tool = table().listing(allowWrites: false).first { $0.name == "armada_get_build_slots" }
    #expect(tool?.annotations.readOnlyHint == true)
    #expect(tool?.gate == .always)
  }

  @Test("Switched off, the lede says so")
  func offLede() async {
    let result = await call("armada_get_build_slots", on: source(.empty))
    #expect(!result.isError)
    #expect(result.text == "Build slots off.")
    #expect(result.structuredContent?["enabled"] == .bool(false))
  }

  @Test("Holders and waiters, each with its session")
  func holdersAndWaiters() async throws {
    let result = await call("armada_get_build_slots", on: source(Self.busy()))
    #expect(!result.isError)
    #expect(result.text == "1 of 2 slots busy, 1 waiting; memory pressure warning.")
    let body = try #require(result.structuredContent)
    #expect(body["enabled"] == .bool(true))
    #expect(body["slots"] == .int(2))
    #expect(body["memoryRule"] == .string("warning"))
    #expect(body["memoryPressure"] == .string("warning"))

    let holder = try #require(body["holders"]?.arrayValue?.first)
    #expect(holder["slot"] == .int(0))
    #expect(holder["pid"] == .int(501))
    #expect(holder["label"] == .string("armada"))
    #expect(holder["cwd"] == .string("/Users/me/armada"))
    #expect(holder["tool"] == .string("swift"))
    #expect(holder["argv"] == .array(["swift", "test"]))
    #expect(holder["since"] == .string(Self.startedAt.formatted(.iso8601)))
    #expect(holder["waitsOnMemory"] == .bool(false))
    #expect(holder["session"]?["id"] == .string(FakeFleetSource.idle))
    #expect(holder["session"]?["vendor"] == .string("claude"))
    #expect(holder["session"]?["title"] == .string("Docs"))

    let waiter = try #require(body["waiters"]?.arrayValue?.first)
    #expect(waiter["slot"] == nil, "a waiter holds no slot")
    #expect(waiter["since"] == .string(Self.waitingSince.formatted(.iso8601)))
    #expect(waiter["waitsOnMemory"] == .bool(true))
    #expect(waiter["session"]?["vendor"] == .string("codex"))
  }

  @Test("A build nobody could name carries no session")
  func unmatched() async throws {
    let slots = BuildSlotsSnapshot(
      enabled: true, slots: 1, memoryRule: "off", memoryPressure: "normal",
      holders: [
        .init(
          slot: 0, pid: 7, label: "site", cwd: "/tmp/site", tool: "swift",
          argv: ["swift", "build"], since: Self.startedAt, waitsOnMemory: false, session: nil)
      ],
      waiters: [])
    let result = await call("armada_get_build_slots", on: source(slots))
    #expect(result.text == "1 of 1 slots busy, 0 waiting; memory pressure normal.")
    let holder = try #require(result.structuredContent?["holders"]?.arrayValue?.first)
    #expect(holder["session"] == nil)
  }

  @Test("The fleet marks the session holding a slot, and only that one")
  func fleetSessionCarriesBuildSlot() async throws {
    let result = await call("armada_get_fleet", on: source(Self.busy()))
    let sessions = try #require(result.structuredContent?["sessions"]?.arrayValue)
    let idle = try #require(sessions.first { $0["id"] == .string(FakeFleetSource.idle) })
    #expect(idle["buildSlot"]?["state"] == .string("holding"))
    #expect(idle["buildSlot"]?["since"] == .string(Self.startedAt.formatted(.iso8601)))
    #expect(idle["buildSlot"]?["tool"] == .string("swift"))
    let other = try #require(sessions.first { $0["id"] == .string(FakeFleetSource.waiting) })
    #expect(other["buildSlot"] == nil)
  }

  @Test("One session waiting for a slot says so")
  func getSessionCarriesWaiting() async throws {
    let result = await call(
      "armada_get_session", ["session": .string(FakeFleetSource.codexOpen)],
      on: source(Self.busy()))
    #expect(!result.isError)
    let session = try #require(result.structuredContent?["session"])
    #expect(session["buildSlot"]?["state"] == .string("waiting"))
    #expect(session["buildSlot"]?["since"] == .string(Self.waitingSince.formatted(.iso8601)))
    #expect(session["buildSlot"]?["tool"] == .string("xcodebuild"))
  }
}
