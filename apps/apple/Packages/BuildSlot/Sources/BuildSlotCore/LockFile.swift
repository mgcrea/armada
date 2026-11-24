import Darwin
import Foundation
import Synchronization

/// A slot or waiting file this process locks: one descriptor, kept open for as long as the lock
/// is wanted. POSIX record locks belong to the process, not the descriptor, and closing *any*
/// descriptor on the file drops them, so everything this process does to the file (writing its
/// record, renaming it) goes through this one descriptor, and readers here skip the files it
/// holds (`isHeldHere`).
public final class LockFile {
  public private(set) var path: URL
  private var fd: Int32
  private var identity: FileIdentity?

  /// Opens or creates the file, 0600, close-on-exec so a build's children never carry it.
  /// Refuses a symlink (`O_NOFOLLOW`): the lock folder sits under world-writable `/tmp`, and a
  /// planted link would have `write` truncate whatever file it points at.
  public init(path: URL) throws {
    let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError.current() }
    self.path = path
    self.fd = fd
  }

  deinit { closeDescriptor() }

  /// Takes a whole-file write lock without waiting. True when this process now holds it.
  public func tryLock() -> Bool {
    guard fd >= 0 else { return false }
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    guard fcntl(fd, F_SETLK, &lock) == 0 else { return false }
    if identity == nil, let held = FileIdentity(fd: fd) {
      identity = held
      LockFile.held.withLock { _ = $0.insert(held) }
    }
    return true
  }

  /// Replaces the file's content with `record`.
  public func write(_ record: SlotRecord) throws {
    let data = try record.encoded()
    guard ftruncate(fd, 0) == 0 else { throw POSIXError.current() }
    let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    guard written == data.count else { throw written < 0 ? POSIXError.current() : POSIXError(.EIO) }
  }

  /// Moves the file, lock and all: the lock is on the file, not its name.
  public func rename(to destination: URL) throws {
    guard Darwin.rename(path.path, destination.path) == 0 else { throw POSIXError.current() }
    path = destination
  }

  /// Removes the file, then closes, which drops the lock. In that order, so no reader finds the
  /// file free with this process's record still in it. For waiting files only: a slot is
  /// released by closing (deinit, or the process exiting), never by unlinking. A reader that
  /// opened the old inode could lock it while a newcomer locks a fresh file at the same path,
  /// and two processes would both hold that slot.
  public func unlinkAndClose() {
    guard fd >= 0 else { return }
    unlink(path.path)
    closeDescriptor()
  }

  private func closeDescriptor() {
    guard fd >= 0 else { return }
    if let identity { _ = LockFile.held.withLock { $0.remove(identity) } }
    identity = nil
    close(fd)
    fd = -1
  }

  // MARK: Files held here

  private static let held = Mutex<Set<FileIdentity>>([])

  /// Whether this process holds `path`'s lock through a `LockFile`. Asked with `stat`, which
  /// opens nothing, so asking never drops the lock it asks about.
  static func isHeldHere(_ path: URL) -> Bool {
    guard let identity = FileIdentity(path: path) else { return false }
    return held.withLock { $0.contains(identity) }
  }
}

/// A file by device and inode, which a rename keeps and two spellings of a path share.
struct FileIdentity: Hashable, Sendable {
  let device: dev_t
  let inode: ino_t

  init?(fd: Int32) {
    var info = stat()
    guard fstat(fd, &info) == 0 else { return nil }
    device = info.st_dev
    inode = info.st_ino
  }

  init?(path: URL) {
    var info = stat()
    guard stat(path.path, &info) == 0 else { return nil }
    device = info.st_dev
    inode = info.st_ino
  }
}

/// Who holds a file's lock, asked without taking it.
public enum LockProbe {
  /// The pid holding a write-conflicting lock on `path`; nil when the lock is free or the file
  /// is missing. Never names this process's own locks (`F_GETLK` skips the caller's), and must
  /// not be pointed at a file this process holds: closing the probe's descriptor would drop it.
  public static func holderPID(of path: URL) -> Int32? {
    let fd = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    return holderPID(fd: fd)
  }

  static func holderPID(fd: Int32) -> Int32? {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
    return lock.l_pid
  }
}

extension POSIXError {
  /// The error `errno` names now.
  static func current() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
