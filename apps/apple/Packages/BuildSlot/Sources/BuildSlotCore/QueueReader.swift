import Darwin
import Foundation

/// A holder (with its slot) or a waiter (slot nil).
public struct QueueEntry: Equatable, Sendable {
  public var slot: Int?
  public var record: SlotRecord

  public init(slot: Int?, record: SlotRecord) {
    self.slot = slot
    self.record = record
  }
}

public struct QueueState: Equatable, Sendable {
  public var holders: [QueueEntry]
  public var waiters: [QueueEntry]
  /// Slots below the configured count whose lock nobody holds.
  public var freeSlots: [Int]

  public init(holders: [QueueEntry], waiters: [QueueEntry], freeSlots: [Int]) {
    self.holders = holders
    self.waiters = waiters
    self.freeSlots = freeSlots
  }
}

/// Reads the queue from the lock folder without disturbing it: `F_GETLK` on fresh read-only
/// descriptors, never a lock taken. Shared by the shims, `buildslot status` and the app.
public enum QueueReader {
  /// A waiter renames its temp file within moments of creating it, so one this old is a
  /// waiter that died in between.
  static let staleTempAge: TimeInterval = 60

  /// The queue now. Slots run from 0 to the configured count, or past it while a slot file
  /// above the count exists (a holder from before the count was lowered), but never past the
  /// largest count settings allow: a file named beyond it is no slot, and a name like
  /// `9223372036854775807.lock` would otherwise overflow, or cost every read billions of opens.
  /// A slot is held only when `F_GETLK` names the pid its record names: a free lock is a free
  /// slot whatever the file says, and a lock whose record names someone else (being written, or
  /// torn) is neither.
  ///
  /// Files this process holds are skipped, never opened, since closing a descriptor on them
  /// would drop the lock, and `F_GETLK` would not report them anyway; the caller knows its own
  /// state. `ownPID` also skips that pid's waiting and temp files. A pid holding a slot is no
  /// waiter, though its waiting file stays locked for a moment after it takes the slot. With
  /// `sweep`, a waiting file whose lock is free (its waiter died) is deleted, and so is a temp
  /// file older than a minute whose lock is free.
  public static func read(
    _ paths: BuildSlotPaths, slotCount: Int, ownPID: Int32? = nil, now: Date = .now,
    sweep: Bool = true
  ) -> QueueState {
    var holders: [QueueEntry] = []
    var freeSlots: [Int] = []
    let highest =
      numberedFiles(in: paths.slotsDir).map(\.number)
      .filter { $0 < BuildSlotSettings.slotRange.upperBound }.max() ?? -1
    for slot in 0..<max(slotCount, highest + 1) {
      let url = paths.slotFile(slot)
      if LockFile.isHeldHere(url) { continue }
      switch probe(url) {
      case .free:
        if slot < slotCount { freeSlots.append(slot) }
      case .held(let record):
        holders.append(QueueEntry(slot: slot, record: record))
      case .unknownHolder:
        break
      }
    }

    var waiters: [QueueEntry] = []
    let holderPIDs = Set(holders.map(\.record.pid))
    for (number, url) in numberedFiles(in: paths.waitingDir) {
      if Int32(exactly: number) == ownPID || LockFile.isHeldHere(url) { continue }
      switch probe(url) {
      case .free:
        if sweep { unlinkIfUnchanged(url) }
      case .held(let record):
        if !holderPIDs.contains(record.pid) {
          waiters.append(QueueEntry(slot: nil, record: record))
        }
      case .unknownHolder:
        break
      }
    }
    if sweep { sweepTempFiles(paths, ownPID: ownPID, now: now) }

    waiters.sort {
      ($0.record.waitingSince ?? .distantPast, $0.record.pid)
        < ($1.record.waitingSince ?? .distantPast, $1.record.pid)
    }
    return QueueState(holders: holders, waiters: waiters, freeSlots: freeSlots)
  }

  private enum Probe {
    case free
    case held(SlotRecord)
    /// Locked, but the record is missing or names another pid.
    case unknownHolder
  }

  /// One descriptor for both the lock query and the read, so the record read is the file the
  /// lock was asked about.
  private static func probe(_ url: URL) -> Probe {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    // Only a missing file is free; one that cannot be opened (a symlink) is no slot to offer.
    guard fd >= 0 else { return errno == ENOENT ? .free : .unknownHolder }
    defer { close(fd) }
    guard let pid = LockProbe.holderPID(fd: fd) else { return .free }
    guard let record = SlotRecord.decoded(from: readAll(fd)), record.pid == pid else {
      return .unknownHolder
    }
    return .held(record)
  }

  private static func readAll(_ fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var offset: off_t = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
      if count <= 0 { break }
      data.append(contentsOf: buffer[0..<count])
      offset += off_t(count)
    }
    return data
  }

  /// `N.lock` files in `dir`, by their number, spelled as the tool writes it: `+3.lock` and
  /// `03.lock` are not slot 3.
  private static func numberedFiles(in dir: URL) -> [(number: Int, url: URL)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.compactMap { name in
      guard name.hasSuffix(".lock"), let number = Int(name.dropLast(5)), number >= 0,
        "\(number).lock" == name
      else { return nil }
      return (number, dir.appendingPathComponent(name))
    }
  }

  private static func sweepTempFiles(_ paths: BuildSlotPaths, ownPID: Int32?, now: Date) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.waitingDir.path)) ?? []
    for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp") {
      if let ownPID, name == ".\(ownPID).tmp" { continue }
      let url = paths.waitingDir.appendingPathComponent(name)
      var info = stat()
      guard stat(url.path, &info) == 0, !LockFile.isHeldHere(url) else { continue }
      let modified = Date(
        timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
          + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
      guard now.timeIntervalSince(modified) > staleTempAge else { continue }
      unlinkIfUnchanged(url)
    }
  }

  /// Deletes `url` when its lock is free and it is still the file that was found free. A new
  /// waiter of a reused pid may rename its locked file onto the name in between; the inode check
  /// leaves that one alone.
  private static func unlinkIfUnchanged(_ url: URL) {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard LockProbe.holderPID(fd: fd) == nil, let opened = FileIdentity(fd: fd),
      FileIdentity(path: url) == opened
    else { return }
    unlink(url.path)
  }
}
