import Foundation
import Testing

@testable import ArmadaMCP

@Suite("Room directory")
struct RoomDirectoryTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "armada-rooms-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func seats(_ pairs: [(String, String)] = [("claude", "claude")]) -> [RoomNamedSeat] {
    pairs.map { RoomNamedSeat(seat: $0.0, vendor: $0.1) }
  }

  private func open(
    _ name: String, at directory: RoomDirectory,
    when: Date = Date(timeIntervalSince1970: 1_800_000_000)
  )
    async -> RoomOutcome
  {
    await directory.open(
      RoomOpen(name: name, question: "Why?", seats: seats(), now: when))
  }

  private func value(_ outcome: RoomOutcome) -> RoomValue? {
    if case .ok(let value) = outcome { return value }
    return nil
  }

  @Test("Open writes the room and reads it back")
  func roundTrip() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let opened = await open("login", at: store)
    let room = try #require(value(opened)?.room)
    #expect(room.name == "login")
    #expect(room.question == "Why?")
    #expect(room.seats.count == 1)
    let loaded = try #require(value(await store.room("login"))?.room)
    #expect(loaded.seats.map(\.marker) == room.seats.map(\.marker))
    #expect(loaded.question == "Why?")
    let file = directory.appending(path: "login.json")
    let attributes = try FileManager.default.attributesOfItem(
      atPath: file.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    let dirAttributes = try FileManager.default.attributesOfItem(
      atPath: directory.path(percentEncoded: false))
    #expect((dirAttributes[.posixPermissions] as? Int) == 0o700)
  }

  @Test("A bad name is refused before any file is created")
  func badName() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let outcome = await store.open(
      RoomOpen(name: "../secret", question: "Why?", seats: seats(), now: now))
    guard case .refused(let message) = outcome else {
      Issue.record("bad name should be refused")
      return
    }
    #expect(message == RoomRules.nameRefusal("../secret"))
    let parent = directory.deletingLastPathComponent()
    #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "secret.json").path))
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
  }

  @Test("Opening an open name, a closed name, or a 21st room is refused")
  func limits() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await open("login", at: store)
    guard case .refused(let again) = await open("login", at: store) else {
      Issue.record("second open should fail")
      return
    }
    #expect(again == "Room login is already open.")
    _ = await store.close("login", at: now)
    guard case .refused(let closed) = await open("login", at: store) else {
      Issue.record("closed name should fail")
      return
    }
    #expect(closed == "Room login is closed. Open a new one under another name.")

    for index in 1...20 {
      let outcome = await open("r\(index)", at: store)
      #expect(value(outcome) != nil, "r\(index)")
    }
    guard case .refused(let full) = await open("extra", at: store) else {
      Issue.record("21st room should fail")
      return
    }
    #expect(full == RoomRules.tooManyOpen)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appending(path: "extra.json").path(percentEncoded: false)))
  }

  @Test("A file this build cannot read is moved aside, and the backup is left alone")
  func movedAside() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "login.json")
    try Data("{".utf8).write(to: file)
    let store = RoomDirectory(root: directory)
    let opened = try #require(value(await open("login", at: store))?.room)
    #expect(opened.name == "login")
    let names = try FileManager.default.contentsOfDirectory(
      atPath: directory.path(percentEncoded: false))
    let backup = try #require(names.first { $0.hasPrefix("login.json.bak-") })
    let backupURL = directory.appending(path: backup)
    #expect(try Data(contentsOf: backupURL) == Data("{".utf8))
    let rewritten = try Data(contentsOf: file)
    #expect(rewritten != Data("{".utf8))
    #expect(try Data(contentsOf: backupURL) == Data("{".utf8))
  }

  @Test("A room closed more than 7 days ago is deleted on the next open, and a newer one stays")
  func prune() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    let old = now.addingTimeInterval(-8 * 86_400)
    let week = now.addingTimeInterval(-7 * 86_400)
    let yesterday = now.addingTimeInterval(-86_400)
    _ = await open("old", at: store, when: old)
    _ = await store.close("old", at: old)
    _ = await open("week", at: store, when: week)
    _ = await store.close("week", at: week)
    _ = await open("recent", at: store, when: yesterday)
    _ = await store.close("recent", at: yesterday)
    try Data("{".utf8).write(to: directory.appending(path: "junk.json"))
    try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))
    try Data("bak".utf8).write(to: directory.appending(path: "old.json.bak-1"))
    _ = await open("fresh", at: store, when: now)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: directory.path(percentEncoded: false))
    #expect(!names.contains("old.json"))
    #expect(names.contains("week.json"))
    #expect(names.contains("recent.json"))
    #expect(names.contains("junk.json"))
    #expect(names.contains("notes.txt"))
    #expect(names.contains("old.json.bak-1"))
    #expect(names.contains("fresh.json"))
  }

  @Test("Two overlapping posts take p1 and p2, and allDone flips once")
  func concurrentPosts() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await open("login", at: store)
    async let first = store.post(
      RoomPosting(room: "login", seat: "claude", text: "one", kind: .done, replyTo: nil, now: now))
    async let second = store.post(
      RoomPosting(
        room: "login", seat: "claude", text: "two", kind: .done, replyTo: nil,
        now: now.addingTimeInterval(1)))
    let outcomes = await [first, second]
    let values = outcomes.compactMap(value)
    #expect(values.count == 2)
    #expect(values.filter(\.becameAllDone).count == 1)
    let posts = try #require(value(await store.room("login"))?.room.posts)
    #expect(posts.map(\.id) == ["p1", "p2"])
    #expect(Set(posts.map(\.text)) == ["one", "two"])
  }

  @Test("Closing twice reports the room already closed and does not move closedAt")
  func secondClose() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoomDirectory(root: directory)
    _ = await open("login", at: store)
    let first = try #require(value(await store.close("login", at: now)))
    #expect(!first.wasAlreadyClosed)
    #expect(first.room.closedAt == now)
    let second = try #require(value(await store.close("login", at: now.addingTimeInterval(30))))
    #expect(second.wasAlreadyClosed)
    #expect(!second.becameAllDone)
    #expect(second.room.closedAt == now)
  }

  @Test("A server without a room directory refuses every call")
  func unavailable() async {
    let store = UnavailableRoomStore()
    let opened = await store.open(
      RoomOpen(name: "login", question: "Why?", seats: seats(), now: now))
    guard case .refused(let message) = opened else {
      Issue.record("unavailable store should refuse")
      return
    }
    #expect(message == "Rooms are not available on this server.")
    guard case .refused = await store.room("login") else {
      Issue.record("room should refuse")
      return
    }
  }
}
