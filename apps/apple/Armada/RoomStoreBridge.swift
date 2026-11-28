import ArmadaMCP
import Foundation

/// The room tools' door into the app. See `RoomStore`.
///
/// Rooms live in Application Support, one file per room. When that folder cannot be found the
/// tools answer that rooms are not available, the same as a server built without a store.
/// A post that completes every seat notifies once. The tool result does not mention it.
nonisolated struct RoomStoreBridge: RoomStore {
  private let directory: RoomDirectory

  init(directory: RoomDirectory) {
    self.directory = directory
  }

  /// The store for this build's Application Support, or a refusal when that folder is missing.
  /// Main actor because `AppInfo` is.
  @MainActor
  static func makeDefault() -> any RoomStore {
    guard
      let root = AppInfo.supportDirectory?.appending(path: "rooms", directoryHint: .isDirectory)
    else { return UnavailableRoomStore() }
    return RoomStoreBridge(directory: RoomDirectory(root: root))
  }

  func open(_ request: RoomOpen) async -> RoomOutcome {
    await directory.open(request)
  }

  func post(_ request: RoomPosting) async -> RoomOutcome {
    let outcome = await directory.post(request)
    if case .ok(let value) = outcome, value.becameAllDone {
      await RoomNotifier.post(room: value.room.name)
    }
    return outcome
  }

  func attach(_ request: RoomAttachment) async -> RoomOutcome {
    await directory.attach(request)
  }

  func confirm(_ request: RoomAttachment) async -> RoomOutcome {
    await directory.confirm(request)
  }

  func release(_ name: String, seat: String) async -> RoomOutcome {
    await directory.release(name, seat: seat)
  }

  func room(_ name: String) async -> RoomOutcome {
    await directory.room(name)
  }

  func beginRound(_ name: String, now: Date) async -> RoomOutcome {
    await directory.beginRound(name, now: now)
  }

  func close(_ name: String, at now: Date) async -> RoomOutcome {
    await directory.close(name, at: now)
  }

  func applyBind(_ name: String, seat: String, bind: Room.Bind) async -> RoomOutcome {
    await directory.applyBind(name, seat: seat, bind: bind)
  }
}
