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

  /// Creates the lock folders, 0700, whoever needs them first, then checks each is a real
  /// directory of this user's that nobody else can write. `/private/tmp` is world-writable, so
  /// another account could have made the path first, open to all or as a symlink, to plant lock
  /// files; creating succeeds silently over an existing path, hence the check. Throws
  /// `UnsafeLockDirectory`, and the caller runs the build unqueued.
  ///
  /// Each folder is made by `mkdir(…, 0700)`, which sets the mode as it creates: FileManager's
  /// `attributes` chmod after creating, and a second shim starting at that moment (two builds
  /// after a reboot) would find the folder 755 and run unqueued. Measured: 8 threads creating
  /// one fresh folder failed in every one of 50 rounds that way.
  public func ensureDirectories() throws {
    try FileManager.default.createDirectory(
      at: lockRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    for dir in [lockRoot, slotsDir, waitingDir] {
      if mkdir(dir.path, 0o700) == 0 {
        chmod(dir.path, 0o700)  // A umask that strips the owner's bits must not leave it unusable.
      } else if errno != EEXIST {
        throw POSIXError.current()
      }
      var info = stat()
      guard lstat(dir.path, &info) == 0 else { throw POSIXError.current() }
      if info.st_mode & S_IFMT != S_IFDIR {
        throw UnsafeLockDirectory(path: dir.path, reason: "not a directory")
      }
      if info.st_uid != getuid() {
        throw UnsafeLockDirectory(path: dir.path, reason: "owned by uid \(info.st_uid)")
      }
      if info.st_mode & 0o077 != 0 {
        let mode = String(info.st_mode & 0o777, radix: 8)
        throw UnsafeLockDirectory(path: dir.path, reason: "mode \(mode), not 700")
      }
    }
  }
}

/// A lock folder another account could write to, or a symlink in its place.
public struct UnsafeLockDirectory: Error, CustomStringConvertible, Sendable {
  public let path: String
  public let reason: String

  public var description: String { "\(path) is unsafe: \(reason)" }
}
