import Foundation

/// What `armada_room_open` asks the store to create. Markers are generated inside the store.
public struct RoomOpen: Sendable, Equatable {
  public var name: String
  public var question: String
  public var seats: [RoomNamedSeat]
  public var now: Date

  public init(name: String, question: String, seats: [RoomNamedSeat], now: Date) {
    self.name = name
    self.question = question
    self.seats = seats
    self.now = now
  }
}

public struct RoomPosting: Sendable, Equatable {
  public var room: String
  public var seat: String
  public var text: String
  public var kind: RoomKind
  public var replyTo: String?
  public var now: Date

  public init(
    room: String, seat: String, text: String, kind: RoomKind, replyTo: String?, now: Date
  ) {
    self.room = room
    self.seat = seat
    self.text = text
    self.kind = kind
    self.replyTo = replyTo
    self.now = now
  }
}

public struct RoomAttachment: Sendable, Equatable {
  public var room: String
  public var seat: String
  public var projectPath: String
  public var sessionID: String?
  public var promptAwaitsSend: Bool
  public var headless: Bool

  public init(
    room: String, seat: String, projectPath: String, sessionID: String?, promptAwaitsSend: Bool,
    headless: Bool
  ) {
    self.room = room
    self.seat = seat
    self.projectPath = projectPath
    self.sessionID = sessionID
    self.promptAwaitsSend = promptAwaitsSend
    self.headless = headless
  }
}

public struct RoomValue: Sendable, Equatable {
  public var room: Room
  /// True only on the post that flipped `allDone` from false to true.
  public var becameAllDone: Bool
  /// True only when `close` is asked of a room that was already closed.
  public var wasAlreadyClosed: Bool

  public init(room: Room, becameAllDone: Bool, wasAlreadyClosed: Bool = false) {
    self.room = room
    self.becameAllDone = becameAllDone
    self.wasAlreadyClosed = wasAlreadyClosed
  }
}

public enum RoomOutcome: Sendable, Equatable {
  case ok(RoomValue)
  case refused(String)
}

public protocol RoomStore: Sendable {
  func open(_ request: RoomOpen) async -> RoomOutcome
  func post(_ request: RoomPosting) async -> RoomOutcome
  /// Reserve a seat before its session is launched. Refuses a seat already started.
  func attach(_ request: RoomAttachment) async -> RoomOutcome
  /// Write what the launch reported over the reservation.
  func confirm(_ request: RoomAttachment) async -> RoomOutcome
  /// Drop a reservation whose launch was refused.
  func release(_ name: String, seat: String) async -> RoomOutcome
  func room(_ name: String) async -> RoomOutcome
  func beginRound(_ name: String, now: Date) async -> RoomOutcome
  func close(_ name: String, at now: Date) async -> RoomOutcome
  func applyBind(_ name: String, seat: String, bind: Room.Bind) async -> RoomOutcome
}

/// The stand-in `Tools.table` uses when the app has nowhere to put a room.
public struct UnavailableRoomStore: RoomStore {
  public static let refusal = "Rooms are not available on this server."

  public init() {}

  public func open(_ request: RoomOpen) async -> RoomOutcome { .refused(Self.refusal) }

  public func post(_ request: RoomPosting) async -> RoomOutcome { .refused(Self.refusal) }

  public func attach(_ request: RoomAttachment) async -> RoomOutcome { .refused(Self.refusal) }

  public func confirm(_ request: RoomAttachment) async -> RoomOutcome { .refused(Self.refusal) }

  public func release(_ name: String, seat: String) async -> RoomOutcome {
    .refused(Self.refusal)
  }

  public func room(_ name: String) async -> RoomOutcome { .refused(Self.refusal) }

  public func beginRound(_ name: String, now: Date) async -> RoomOutcome { .refused(Self.refusal) }

  public func close(_ name: String, at now: Date) async -> RoomOutcome { .refused(Self.refusal) }

  public func applyBind(_ name: String, seat: String, bind: Room.Bind) async -> RoomOutcome {
    .refused(Self.refusal)
  }
}

/// `rooms/<name>.json` under one directory. One actor, so two posts cannot take the same id.
///
/// **Init does not touch the disk.** Pruning runs on the first call, and again at the start of
/// every `open`, using the `now` that call was given. A file that cannot be read this time, or
/// that a newer build wrote, is refused and left alone. Only a file that was read and does not
/// decode is moved aside, never overwritten. If the move fails, that name refuses every write
/// until the process ends; other rooms are unaffected.
public actor RoomDirectory: RoomStore {
  private let root: URL
  private var blocked: Set<String> = []
  private var didPrune = false

  public init(root: URL) {
    self.root = root
  }

  public func open(_ request: RoomOpen) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(request.name) { return .refused(refusal) }
    prune(now: request.now)
    didPrune = true
    switch Room.opened(
      name: request.name, question: request.question, seats: request.seats, now: request.now)
    {
    case .failure(let refusal):
      return .refused(refusal.message)
    case .success(let room):
      switch load(room.name, now: request.now) {
      case .unreadable(let message):
        return .refused(message)
      case .room(let existing) where existing.closedAt != nil:
        return .refused(RoomRules.closedName(existing.name))
      case .room:
        return .refused(RoomRules.alreadyOpen(room.name))
      case .absent:
        if openCount() >= RoomRules.maxOpenRooms { return .refused(RoomRules.tooManyOpen) }
        return write(room, becameAllDone: false)
      }
    }
  }

  public func post(_ request: RoomPosting) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(request.room) { return .refused(refusal) }
    prepare(now: request.now)
    switch load(request.room, now: request.now) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(request.room))
    case .room(var room):
      let wasDone = room.allDone
      if let refusal = room.append(
        seat: request.seat, text: request.text, kind: request.kind, replyTo: request.replyTo,
        at: request.now)
      {
        return .refused(refusal)
      }
      return write(room, becameAllDone: !wasDone && room.allDone)
    }
  }

  public func attach(_ request: RoomAttachment) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(request.room) { return .refused(refusal) }
    prepare(now: Date())
    switch load(request.room, now: Date()) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(request.room))
    case .room(var room):
      if room.closedAt != nil { return .refused("Room \(room.name) is closed.") }
      if let refusal = room.noteSession(
        seat: request.seat, projectPath: request.projectPath, sessionID: request.sessionID,
        promptAwaitsSend: request.promptAwaitsSend, headless: request.headless)
      {
        return .refused(refusal)
      }
      return write(room, becameAllDone: false)
    }
  }

  /// Not refused on a closed room: the session was launched while the room was open.
  public func confirm(_ request: RoomAttachment) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(request.room) { return .refused(refusal) }
    prepare(now: Date())
    switch load(request.room, now: Date()) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(request.room))
    case .room(var room):
      if let refusal = room.confirmSession(
        seat: request.seat, projectPath: request.projectPath, sessionID: request.sessionID,
        promptAwaitsSend: request.promptAwaitsSend, headless: request.headless)
      {
        return .refused(refusal)
      }
      return write(room, becameAllDone: false)
    }
  }

  public func release(_ name: String, seat: String) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(name) { return .refused(refusal) }
    prepare(now: Date())
    switch load(name, now: Date()) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(name))
    case .room(var room):
      room.releaseSession(seat: seat)
      return write(room, becameAllDone: false)
    }
  }

  public func room(_ name: String) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(name) { return .refused(refusal) }
    prepare(now: Date())
    switch load(name, now: Date()) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(name))
    case .room(let room):
      return .ok(RoomValue(room: room, becameAllDone: false))
    }
  }

  public func beginRound(_ name: String, now: Date) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(name) { return .refused(refusal) }
    prepare(now: now)
    switch load(name, now: now) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(name))
    case .room(var room):
      if let refusal = room.beginRound() { return .refused(refusal) }
      return write(room, becameAllDone: false)
    }
  }

  public func close(_ name: String, at now: Date) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(name) { return .refused(refusal) }
    prepare(now: now)
    switch load(name, now: now) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(name))
    case .room(var room):
      if room.closedAt != nil {
        return .ok(RoomValue(room: room, becameAllDone: false, wasAlreadyClosed: true))
      }
      room.close(at: now)
      return write(room, becameAllDone: false)
    }
  }

  public func applyBind(_ name: String, seat: String, bind: Room.Bind) async -> RoomOutcome {
    if let refusal = RoomRules.nameRefusal(name) { return .refused(refusal) }
    prepare(now: Date())
    switch load(name, now: Date()) {
    case .unreadable(let message):
      return .refused(message)
    case .absent:
      return .refused(RoomRules.unknown(name))
    case .room(var room):
      let before = room.seats.first { $0.seat == seat }?.sessionID
      room.apply(bind, to: seat)
      let after = room.seats.first { $0.seat == seat }?.sessionID
      if before == after { return .ok(RoomValue(room: room, becameAllDone: false)) }
      return write(room, becameAllDone: false)
    }
  }

  // MARK: - Disk

  private enum Loaded {
    case absent
    case room(Room)
    case unreadable(String)
  }

  private func prepare(now: Date) {
    guard !didPrune else { return }
    prune(now: now)
    didPrune = true
  }

  /// Delete a closed room whose `closedAt` is strictly more than 7 days before `now`.
  /// An unreadable file is left where it is.
  private func prune(now: Date) {
    let cutoff = now.addingTimeInterval(-Double(RoomRules.keepClosedDays) * 86_400)
    for url in jsonFiles() {
      guard let room = decode(url), let closedAt = room.closedAt else {
        continue
      }
      let filename = url.deletingPathExtension().lastPathComponent
      guard room.version == RoomRules.version, room.name == filename, closedAt < cutoff else {
        continue
      }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func openCount() -> Int {
    jsonFiles().reduce(0) { count, url in
      guard let room = decode(url), room.version == RoomRules.version, room.closedAt == nil else {
        return count
      }
      return count + 1
    }
  }

  private func jsonFiles() -> [URL] {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return urls.filter { $0.pathExtension == "json" }
  }

  private func load(_ name: String, now: Date) -> Loaded {
    if blocked.contains(name) { return .unreadable(RoomRules.unreadable(name)) }
    let url = file(name)
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return .absent
    }
    // A read that fails says nothing about the file. Refuse this call and try again on the next.
    guard let data = try? Data(contentsOf: url) else {
      return .unreadable(RoomRules.unreadableNow(name))
    }
    if let version = Self.version(of: data), version > RoomRules.version {
      return .unreadable(RoomRules.newer(name))
    }
    if let room = decode(data), room.version == RoomRules.version, room.name == name {
      return .room(room)
    }
    if moveAside(url, name: name, now: now) { return .absent }
    blocked.insert(name)
    return .unreadable(RoomRules.unreadable(name))
  }

  private static func version(of data: Data) -> Int? {
    struct Versioned: Decodable { let version: Int }
    return (try? JSONDecoder().decode(Versioned.self, from: data))?.version
  }

  private func moveAside(_ url: URL, name: String, now: Date) -> Bool {
    let stamp = Int(now.timeIntervalSince1970)
    let aside = root.appending(path: "\(name).json.bak-\(stamp)")
    do {
      try FileManager.default.moveItem(at: url, to: aside)
      return true
    } catch {
      return false
    }
  }

  private func write(_ room: Room, becameAllDone: Bool) -> RoomOutcome {
    do {
      try save(room)
      return .ok(RoomValue(room: room, becameAllDone: becameAllDone))
    } catch {
      return .refused("Armada could not write rooms/\(room.name).json.")
    }
  }

  private func save(_ room: Room) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = file(room.name)
    try encode(room).write(to: url, options: .atomic)
    try manager.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    try manager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: root.path(percentEncoded: false))
  }

  private func file(_ name: String) -> URL {
    root.appending(path: "\(name).json")
  }

  private func encode(_ room: Room) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(room)
  }

  private func decode(_ url: URL) -> Room? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return decode(data)
  }

  private func decode(_ data: Data) -> Room? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Room.self, from: data)
  }
}
