import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("Room tools")
struct RoomToolsTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "armada-room-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func call(
    _ name: String, _ arguments: JSONValue, store: any RoomStore = UnavailableRoomStore(),
    source: FakeFleetSource = FakeFleetSource(), allowWrites: Bool = true,
    sender: FakeMessageSender = FakeMessageSender(), roomPoll: Duration = .milliseconds(1)
  ) async -> ToolResult {
    await Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(), sender: sender,
      focuser: FakeSessionFocuser(), schedules: FakeScheduleStore(), rooms: store,
      roomPoll: roomPoll
    ).call(name: name, arguments: arguments, allowWrites: allowWrites)
  }

  private func seats() -> JSONValue {
    .array([
      .object(["seat": "claude", "vendor": "claude"]),
      .object(["seat": "codex", "vendor": "codex"]),
    ])
  }

  @Test("Read is always listed, and the three room writes sit at the end of the gate")
  func listing() {
    #expect(Tools.readToolNames.last == "armada_room_read")
    #expect(!Tools.readToolNames.contains("armada_room_open"))
    #expect(
      Array(Tools.writeTools.suffix(3)) == [
        "armada_room_open", "armada_room_post", "armada_room_round",
      ])
  }

  @Test("With writes off, open is refused and read is callable")
  func gate() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let refused = await call(
      "armada_room_open", ["name": "login", "question": "Why?", "seats": seats()], store: store,
      allowWrites: false)
    #expect(refused.isError)
    #expect(refused.text.contains("Allow writes"))
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    let read = await call("armada_room_read", ["room": "login"], store: store, allowWrites: false)
    #expect(read.isError)
    #expect(read.text.contains("not open"))
  }

  @Test("Open, post and read a note back, including a reply")
  func postAndRead() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let opened = await call(
      "armada_room_open", ["name": "login", "question": "Why?", "seats": seats()], store: store)
    #expect(!opened.isError)
    let briefs = try #require(opened.structuredContent?["briefs"]?.arrayValue)
    #expect(briefs.count == 2)
    #expect(briefs[0]["brief"]?.stringValue?.contains("Marker:") == true)
    #expect(opened.structuredContent?["seats"]?.arrayValue?.first?["marker"] == nil)

    let posted = await call(
      "armada_room_post",
      ["room": "login", "seat": "claude", "text": "the tests fail", "kind": "finding"], store: store
    )
    #expect(!posted.isError)
    #expect(posted.structuredContent?["posts"]?.arrayValue?.first?["id"] == .string("p1"))
    #expect(posted.structuredContent?["posts"]?.arrayValue?.first?["kind"] == .string("finding"))

    let reply = await call(
      "armada_room_post",
      ["room": "login", "seat": "codex", "text": "same here", "reply_to": "p1"], store: store)
    #expect(!reply.isError)
    #expect(reply.structuredContent?["posts"]?.arrayValue?.last?["replyTo"] == .string("p1"))

    let read = await call("armada_room_read", ["room": "login", "after": "p1"], store: store)
    #expect(!read.isError)
    #expect(read.structuredContent?["posts"]?.arrayValue?.map { $0["id"]?.stringValue } == ["p2"])
    #expect(read.structuredContent?["cursor"] == .string("p2"))
  }

  @Test("An unknown seat, a long question and a missing room are refused")
  func refusals() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await call(
      "armada_room_open", ["name": "login", "question": "Why?", "seats": seats()], store: store)
    let unknown = await call(
      "armada_room_post", ["room": "login", "seat": "nope", "text": "x"], store: store)
    #expect(unknown.text == "Seat nope is not in this room.")
    let long = String(repeating: "a", count: 2001)
    let question = await call(
      "armada_room_open", ["name": "other", "question": .string(long), "seats": seats()],
      store: store)
    #expect(question.text == "The question is 2001 characters; the limit is 2000.")
    let missing = await call("armada_room_read", ["room": "nope"], store: store)
    #expect(missing.text == "Room nope is not open.")
    let after = await call("armada_room_read", ["room": "login", "after": ""], store: store)
    #expect(after.text == "after  is not a post in this room.")
  }

  @Test("A server without rooms refuses to open one")
  func unavailable() async {
    let result = await call(
      "armada_room_open", ["name": "login", "question": "Why?", "seats": seats()])
    #expect(result.text == "Rooms are not available on this server.")
  }
}
