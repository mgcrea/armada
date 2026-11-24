import Darwin
import Foundation

/// Where the queue lives. Both paths are fixed, the same for every build of Armada, so a Debug
/// and a Release app share one queue. The locks sit under `/private/tmp` because Codex's
/// `workspace-write` sandbox refuses writes elsewhere, and a write lock needs a writable
/// descriptor; settings sit in Application Support, which sandboxes may read.
public struct BuildSlotPaths: Sendable {
  public var lockRoot: URL
  public var settingsFile: URL

  public init(lockRoot: URL, settingsFile: URL) {
    self.lockRoot = lockRoot
    self.settingsFile = settingsFile
  }

  public var slotsDir: URL { lockRoot.appendingPathComponent("slots", isDirectory: true) }
  public var waitingDir: URL { lockRoot.appendingPathComponent("waiting", isDirectory: true) }

  public func slotFile(_ n: Int) -> URL { slotsDir.appendingPathComponent("\(n).lock") }

  public func waitingFile(pid: Int32) -> URL {
    waitingDir.appendingPathComponent("\(pid).lock")
  }

  /// Where a waiter writes and locks its record before renaming it to `waitingFile`, so no
  /// reader ever sees a waiting file that is not yet locked.
  public func waitingTempFile(pid: Int32) -> URL {
    waitingDir.appendingPathComponent(".\(pid).tmp")
  }

  /// The real paths, or the test-only overrides `ARMADA_BUILDSLOT_DIR` and
  /// `ARMADA_BUILDSLOT_SETTINGS`.
  public static func standard(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    uid: uid_t = getuid(),
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> BuildSlotPaths {
    let lockRoot =
      environment["ARMADA_BUILDSLOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "/private/tmp/armada-build-slots-\(uid)"
    let settingsFile =
      environment["ARMADA_BUILDSLOT_SETTINGS"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
      }
      ?? home.appendingPathComponent(
        "Library/Application Support/Armada/build-slots/settings.json")
    return BuildSlotPaths(
      lockRoot: URL(fileURLWithPath: lockRoot, isDirectory: true), settingsFile: settingsFile)
  }

  /// Creates the lock folders, 0700, whoever needs them first.
  public func ensureDirectories() throws {
    for dir in [lockRoot, slotsDir, waitingDir] {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }
}
