import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("Starting a room seat")
struct RoomStartTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "armada-room-start-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func call(
    _ arguments: JSONValue, store: any RoomStore, starter: FakeSessionStarter
  ) async -> ToolResult {
    await Tools.table(
      source: FakeFleetSource(), starter: starter, closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(), schedules: FakeScheduleStore(),
      rooms: store
    ).call(name: "armada_start_session", arguments: arguments, allowWrites: true)
  }

  private func open(_ store: RoomDirectory, vendor: String = "codex") async -> Room? {
    guard
      case .ok(let value) = await store.open(
        RoomOpen(
          name: "login", question: "Why?",
          seats: [RoomNamedSeat(seat: "seat", vendor: vendor)],
          now: Date(timeIntervalSince1970: 1_800_000_000)))
    else { return nil }
    return value.room
  }

  private func stored(_ store: RoomDirectory) async throws -> Room {
    if case .ok(let value) = await store.room("login") { return value.room }
    Issue.record("login should still be stored")
    throw CancellationError()
  }

  @Test("The starter receives the stored brief and the seat's vendor")
  func brief() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let room = try #require(await open(store))
    let starter = FakeSessionStarter()
    let result = await call(
      ["project": "armada site", "room": "login", "seat": "seat"], store: store, starter: starter)
    #expect(!result.isError)
    #expect(
      starter.requests == [
        StartSessionRequest(
          projectID: FakeFleetSource.siteProject, vendor: "codex", account: nil,
          prompt: room.brief(for: room.seats[0]))
      ])
    let stored = try await stored(store)
    #expect(stored.seats[0].projectPath == "/Users/me/armada/web")
    #expect(stored.seats[0].sessionID == nil)
  }

  @Test("A headless Grok seat starts from the brief with no prompt of its own")
  func headless() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let room = try #require(await open(store, vendor: "grok"))
    let starter = FakeSessionStarter()
    starter.outcome = .started(
      StartedSession(
        project: "Armada site", path: "/Users/me/armada/web", vendor: "grok",
        accountID: "/Users/me/.grok", account: "Grok", terminal: "Armada", withPrompt: true,
        sessionID: "grok-seat", headless: true))
    let result = await call(
      ["project": "armada site", "room": "login", "seat": "seat", "headless": true], store: store,
      starter: starter)
    #expect(!result.isError)
    #expect(starter.requests.count == 1)
    #expect(starter.requests[0].prompt == room.brief(for: room.seats[0]))
    #expect(starter.requests[0].vendor == "grok")
    #expect(starter.requests[0].headless)
    let stored = try await stored(store)
    #expect(stored.seats[0].sessionID == "grok-seat")
    #expect(stored.seats[0].headless)
  }

  @Test("A bad room, a prompt, a resume or the wrong vendor never reaches the starter")
  func refused() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await open(store)
    let starter = FakeSessionStarter()
    let cases: [JSONValue] = [
      ["project": "armada site", "room": "missing", "seat": "seat"],
      ["project": "armada site", "room": "login", "seat": "seat", "prompt": "ignore the brief"],
      ["room": "login", "seat": "seat", "resume": "aaaaaaaa-1111-4000-8000-000000000001"],
      ["project": "armada site", "room": "login", "seat": "seat", "vendor": "claude"],
      ["project": "armada site", "room": "login"],
    ]
    for arguments in cases {
      let result = await call(arguments, store: store, starter: starter)
      #expect(result.isError, "\(arguments)")
    }
    #expect(starter.requests.isEmpty)
    _ = await store.close("login", at: Date())
    let closed = await call(
      ["project": "armada site", "room": "login", "seat": "seat"], store: store, starter: starter)
    #expect(closed.text == "Room login is closed.")
    #expect(starter.requests.isEmpty)
  }

  @Test("A seat is started once, and a message waiting to be sent stays unbound")
  func once() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await open(store)
    let starter = FakeSessionStarter()
    starter.outcome = .started(
      StartedSession(
        project: "Armada site", path: "/Users/me/armada/web", vendor: "codex",
        accountID: "/Users/me/.codex", account: "Codex", terminal: "VS Code", withPrompt: true,
        promptAwaitsSend: true))
    let first = await call(
      ["project": "armada site", "room": "login", "seat": "seat"], store: store, starter: starter)
    #expect(
      first.structuredContent?["note"]?.stringValue?.contains(
        "The seat stays unbound until the person sends the opening message.") == true)
    let second = await call(
      ["project": "armada site", "room": "login", "seat": "seat"], store: store, starter: starter)
    #expect(second.text == "Seat seat has already been started.")
    #expect(starter.requests.count == 1)
    let stored = try await stored(store)
    #expect(stored.seats[0].promptAwaitsSend)
    #expect(stored.seats[0].sessionID == nil)
  }

  @Test("A refused launch releases the seat, so it can be started again")
  func refusedLaunch() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await open(store)
    let starter = FakeSessionStarter()
    starter.outcome = .refused("No terminal.")
    let first = await call(
      ["project": "armada site", "room": "login", "seat": "seat"], store: store, starter: starter)
    #expect(first.text == "No terminal.")
    #expect(try await stored(store).seats[0].projectPath == nil)
    starter.outcome = .started(
      StartedSession(
        project: "Armada site", path: "/Users/me/armada/web", vendor: "codex",
        accountID: "/Users/me/.codex", account: "Codex", terminal: "Terminal", withPrompt: true,
        sessionID: "codex-seat"))
    let second = await call(
      ["project": "armada site", "room": "login", "seat": "seat"], store: store, starter: starter)
    #expect(!second.isError)
    #expect(try await stored(store).seats[0].sessionID == "codex-seat")
  }
}
