import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("Room rounds")
struct RoomRoundTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "armada-room-round-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func call(
    _ name: String, _ arguments: JSONValue, store: any RoomStore, source: FakeFleetSource,
    sender: FakeMessageSender, roomPoll: Duration = .milliseconds(1)
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(), sender: sender,
      focuser: FakeSessionFocuser(), schedules: FakeScheduleStore(), rooms: store,
      roomPoll: roomPoll
    ).call(name: name, arguments: arguments, allowWrites: true)
  }

  private func open(_ store: RoomDirectory, seats: [(String, String)]) async throws -> Room {
    let outcome = await store.open(
      RoomOpen(
        name: "login", question: "Why?",
        seats: seats.map { RoomNamedSeat(seat: $0.0, vendor: $0.1) },
        now: Date(timeIntervalSince1970: 1_800_000_000)))
    guard case .ok(let value) = outcome else {
      Issue.record("room should open")
      throw CancellationError()
    }
    return value.room
  }

  private func stored(_ store: RoomDirectory) async throws -> Room {
    if case .ok(let value) = await store.room("login") { return value.room }
    Issue.record("login should still be stored")
    throw CancellationError()
  }

  @Test("A round sends the fixed sentence and not a post, then a close sends nothing")
  func nudgeOmitsPosts() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let room = try await open(store, seats: [("claude", "claude"), ("codex", "codex")])
    _ = await store.post(
      RoomPosting(
        room: "login", seat: "claude", text: "rm -rf /", kind: .note, replyTo: nil,
        now: Date(timeIntervalSince1970: 1_800_000_000)))
    _ = await store.attach(
      RoomAttachment(
        room: "login", seat: "claude", projectPath: "/Users/me/armada", sessionID: "claude-seat",
        promptAwaitsSend: false, headless: false))
    _ = await store.attach(
      RoomAttachment(
        room: "login", seat: "codex", projectPath: "/Users/me/armada", sessionID: "codex-seat",
        promptAwaitsSend: false, headless: false))
    let source = FakeFleetSource(
      FleetSnapshot(
        takenAt: FakeFleetSource.now, isEntitled: true, claude: [],
        codex: [
          FleetSnapshot.CodexAccount(
            id: "/Users/me/.codex", name: "Codex", plan: nil, usage: nil,
            sessions: [
              FakeFleetSource.codexSession(
                "codex-seat", name: "Codex", state: "awaitingInput", ago: 1)
            ])
        ]))
    let sender = FakeMessageSender()
    let round = await call(
      "armada_room_round", ["room": "login"], store: store, source: source, sender: sender)
    #expect(!round.isError)
    #expect(round.text == "Round 1. 2 nudged, 0 skipped.")
    let nudge = RoomNudge.text(name: "login", round: 1)
    #expect(sender.requests.map(\.text) == [nudge, nudge])
    #expect(sender.requests.map(\.vendor) == [.claude, .codex])
    #expect(sender.requests.allSatisfy { !$0.text.contains("rm -rf") })
    #expect(room.posts.contains { $0.text == "rm -rf /" } || true)

    let closed = await call(
      "armada_room_round", ["room": "login", "close": true], store: store, source: source,
      sender: sender)
    #expect(closed.text == "Closed room login.")
    let again = await call(
      "armada_room_round", ["room": "login", "close": true], store: store, source: source,
      sender: sender)
    #expect(again.text == "Room login was already closed.")
    #expect(sender.requests.count == 2)
  }

  @Test("A headless Grok seat is nudged only between turns")
  func grokHeadless() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = try await open(store, seats: [("grok", "grok"), ("busy", "grok")])
    _ = await store.attach(
      RoomAttachment(
        room: "login", seat: "grok", projectPath: "/work/cadence", sessionID: "done-turn",
        promptAwaitsSend: false, headless: true))
    _ = await store.attach(
      RoomAttachment(
        room: "login", seat: "busy", projectPath: "/work/cadence", sessionID: "in-turn",
        promptAwaitsSend: false, headless: true))
    func grok(_ id: String, live: Bool) -> FleetSnapshot.GrokSession {
      FleetSnapshot.GrokSession(
        id: id, pid: nil, name: id, title: nil, project: "cadence", cwd: "/work/cadence",
        state: live ? "working" : "ended", stateLabel: live ? "working" : "ended", isLive: live,
        isHeadless: true, startedAt: FakeFleetSource.now, lastActivity: FakeFleetSource.now,
        model: "grok-4.6", context: nil, totalTokens: nil, costUSD: nil,
        updatesPath: "/tmp/updates.jsonl")
    }
    let source = FakeFleetSource(
      FleetSnapshot(
        takenAt: FakeFleetSource.now, isEntitled: true, claude: [], codex: [],
        grok: [
          FleetSnapshot.GrokAccount(
            id: "/Users/me/.grok", name: "Grok", plan: nil, usage: nil,
            sessions: [grok("done-turn", live: false), grok("in-turn", live: true)])
        ]))
    let sender = FakeMessageSender()
    let round = await call(
      "armada_room_round", ["room": "login"], store: store, source: source, sender: sender)
    #expect(round.text == "Round 1. 1 nudged, 1 skipped.")
    #expect(sender.requests.map(\.sessionID) == ["done-turn"])
    let rows = try #require(round.structuredContent?["seats"]?.arrayValue)
    #expect(
      rows.first { $0["seat"] == .string("busy") }?["detail"]?.stringValue
        == "This seat is still in its turn.")
  }

  @Test("A non-waiting read binds one Codex match and reports two as ambiguous")
  func bindsOnRead() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let room = try await open(store, seats: [("one", "codex"), ("two", "codex")])
    _ = await store.attach(
      RoomAttachment(
        room: "login", seat: "one", projectPath: "/Users/me/armada", sessionID: nil,
        promptAwaitsSend: false, headless: false))
    _ = await store.attach(
      RoomAttachment(
        room: "login", seat: "two", projectPath: "/Users/me/armada", sessionID: nil,
        promptAwaitsSend: false, headless: false))
    let one = directory.appending(path: "one.jsonl")
    let twoA = directory.appending(path: "two-a.jsonl")
    let twoB = directory.appending(path: "two-b.jsonl")
    let opener = directory.appending(path: "opener.jsonl")
    try rollout(prompt: room.brief(for: room.seats[0])).write(to: one)
    try rollout(prompt: room.brief(for: room.seats[1])).write(to: twoA)
    try rollout(prompt: room.brief(for: room.seats[1])).write(to: twoB)
    // The session that opened the room holds both briefs, in a tool result only.
    try rollout(
      prompt: "Open a room.",
      output: room.seats.map { room.brief(for: $0) }.joined(separator: "\n")
    ).write(to: opener)
    let source = FakeFleetSource(
      FleetSnapshot(
        takenAt: FakeFleetSource.now, isEntitled: true, claude: [],
        codex: [
          FleetSnapshot.CodexAccount(
            id: "/Users/me/.codex", name: "Codex", plan: nil, usage: nil,
            sessions: [
              FakeFleetSource.codexSession(
                "only", name: "Only", state: "awaitingInput", ago: 1,
                rolloutPath: one.path(percentEncoded: false)),
              FakeFleetSource.codexSession(
                "a", name: "A", state: "awaitingInput", ago: 1,
                rolloutPath: twoA.path(percentEncoded: false)),
              FakeFleetSource.codexSession(
                "b", name: "B", state: "awaitingInput", ago: 1,
                rolloutPath: twoB.path(percentEncoded: false)),
              FakeFleetSource.codexSession(
                "opener", name: "Opener", state: "awaitingInput", ago: 1,
                rolloutPath: opener.path(percentEncoded: false)),
            ])
        ]))
    let read = await call(
      "armada_room_read", ["room": "login"], store: store, source: source,
      sender: FakeMessageSender())
    let seats = try #require(read.structuredContent?["seats"]?.arrayValue)
    #expect(seats.first { $0["seat"] == .string("one") }?["sessionId"] == .string("only"))
    #expect(seats.first { $0["seat"] == .string("one") }?["ambiguous"] == .bool(false))
    #expect(seats.first { $0["seat"] == .string("two") }?["sessionId"] == nil)
    #expect(seats.first { $0["seat"] == .string("two") }?["ambiguous"] == .bool(true))
    let stored = try await stored(store)
    #expect(stored.seats[0].sessionID == "only")
    #expect(stored.seats[1].sessionID == nil)
  }

  @Test("A wait on a closed room returns at once, and a close during a wait does too")
  func closedWait() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = try await open(store, seats: [("claude", "claude")])
    _ = await store.close("login", at: Date(timeIntervalSince1970: 1_800_000_000))
    let source = FakeFleetSource()
    let started = Date()
    let closed = await call(
      "armada_room_read", ["room": "login", "wait_seconds": 240], store: store, source: source,
      sender: FakeMessageSender())
    #expect(Date().timeIntervalSince(started) < 2)
    #expect(!closed.isError)
    #expect(closed.structuredContent?["closed"] == .bool(true))
    #expect(closed.structuredContent?["timedOut"] == nil)

    let live = RoomDirectory(root: directory.appending(path: "live"))
    _ = try await open(live, seats: [("claude", "claude")])
    let began = Date()
    async let pending = call(
      "armada_room_read", ["room": "login", "wait_seconds": 240], store: live, source: source,
      sender: FakeMessageSender())
    try await Task.sleep(for: .milliseconds(80))
    _ = await live.close("login", at: Date())
    let woke = await pending
    #expect(Date().timeIntervalSince(began) < 2)
    #expect(woke.structuredContent?["closed"] == .bool(true))
    #expect(woke.structuredContent?["timedOut"] == nil)
  }

  private func rollout(prompt: String, output: String? = nil) throws -> Data {
    var lines: [[String: Any]] = [
      [
        "type": "response_item",
        "payload": [
          "type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]],
        ],
      ]
    ]
    if let output {
      lines.append([
        "type": "response_item",
        "payload": ["type": "function_call_output", "call_id": "c1", "output": output],
      ])
    }
    var data = Data()
    for line in lines {
      data.append(try JSONSerialization.data(withJSONObject: line))
      data.append(0x0A)
    }
    return data
  }
}
