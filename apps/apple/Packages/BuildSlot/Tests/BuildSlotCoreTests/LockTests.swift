import BuildSlotCore
import Darwin
import Foundation
import Synchronization
import Testing

// Locks are POSIX record locks, observed from a second process (python's `lockf`) because
// `F_GETLK` never reports the caller's own locks.
struct LockTests {
  private func prepared() throws -> BuildSlotPaths {
    let paths = tempPaths()
    try paths.ensureDirectories()
    return paths
  }

  @Test func directoriesArePrivate() throws {
    let paths = try prepared()
    for dir in [paths.lockRoot, paths.slotsDir, paths.waitingDir] {
      let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
      #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }
  }

  @Test func refusesALockRootOthersCanWrite() throws {
    let paths = tempPaths()
    try FileManager.default.createDirectory(at: paths.lockRoot, withIntermediateDirectories: true)
    #expect(chmod(paths.lockRoot.path, 0o777) == 0)
    #expect(throws: UnsafeLockDirectory.self) { try paths.ensureDirectories() }
  }

  @Test func refusesALockRootThatIsASymlink() throws {
    let paths = tempPaths()
    let target = paths.lockRoot.deletingLastPathComponent().appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: paths.lockRoot, withDestinationURL: target)
    #expect(throws: UnsafeLockDirectory.self) { try paths.ensureDirectories() }
  }

  @Test func lockFileRefusesASymlink() throws {
    let paths = try prepared()
    let victim = paths.lockRoot.appendingPathComponent("victim.txt")
    try Data("keep me".utf8).write(to: victim)
    try FileManager.default.createSymbolicLink(at: paths.slotFile(0), withDestinationURL: victim)
    #expect(throws: POSIXError.self) { try LockFile(path: paths.slotFile(0)) }
    #expect(try Data(contentsOf: victim) == Data("keep me".utf8))
    #expect(QueueReader.read(paths, slotCount: 2).freeSlots == [1])
  }

  // Two shims starting together on a fresh lock folder (after a reboot) both create it. Neither
  // may catch the other's folder half made and refuse it as unsafe.
  @Test func concurrentCreationIsNeverRefused() {
    for _ in 0..<50 {
      let paths = tempPaths()
      let failures = Mutex(0)
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        do { try paths.ensureDirectories() } catch { failures.withLock { $0 += 1 } }
      }
      #expect(failures.withLock { $0 } == 0)
    }
  }

  @Test func tryLockFailsWhileAnotherProcessHolds() throws {
    let paths = try prepared()
    let helper = holdLock(paths.slotFile(0), record: nil)
    let lock = try LockFile(path: paths.slotFile(0))
    #expect(!lock.tryLock())
    stop(helper)
    #expect(lock.tryLock())
  }

  @Test func probeNamesHolder() throws {
    let paths = try prepared()
    #expect(LockProbe.holderPID(of: paths.slotFile(0)) == nil)
    let helper = holdLock(paths.slotFile(0), record: nil)
    #expect(LockProbe.holderPID(of: paths.slotFile(0)) == helper.processIdentifier)
    stop(helper)
    #expect(LockProbe.holderPID(of: paths.slotFile(0)) == nil)
  }

  @Test func leftoverRecordReadsFree() throws {
    let paths = try prepared()
    try record(pid: 99999).encoded().write(to: paths.slotFile(0))
    let state = QueueReader.read(paths, slotCount: 2)
    #expect(state.holders.isEmpty)
    #expect(state.freeSlots == [0, 1])
  }

  @Test func recordMustMatchProbe() throws {
    let paths = try prepared()
    let helper = holdLock(paths.slotFile(1), record: record(pid: 99999))
    defer { stop(helper) }
    let state = QueueReader.read(paths, slotCount: 2)
    #expect(state.holders.isEmpty)
    #expect(state.freeSlots == [0])
  }

  @Test func readsHolderAndWaiter() throws {
    let paths = try prepared()
    let holder = holdLock(paths.slotFile(0), record: record(pid: 0))
    defer { stop(holder) }
    let waiterPath = paths.waitingDir.appendingPathComponent("{pid}.lock")
    let waiter = holdLock(waiterPath, record: record(pid: 0, startedAt: nil, waitingSince: .now))
    defer { stop(waiter) }

    let state = QueueReader.read(paths, slotCount: 1)
    #expect(state.holders.map(\.slot) == [0])
    #expect(state.holders.map(\.record.pid) == [holder.processIdentifier])
    #expect(state.waiters.map(\.slot) == [nil])
    #expect(state.waiters.map(\.record.pid) == [waiter.processIdentifier])
    #expect(state.freeSlots.isEmpty)
  }

  @Test func slotsBeyondTheCountAreRead() throws {
    let paths = try prepared()
    let holder = holdLock(paths.slotFile(3), record: record(pid: 0))
    defer { stop(holder) }
    let state = QueueReader.read(paths, slotCount: 2)
    #expect(state.holders.map(\.slot) == [3])
    #expect(state.freeSlots == [0, 1])
  }

  @Test func sweepsDeadWaiter() throws {
    let paths = try prepared()
    let dead = paths.waitingFile(pid: 123)
    try record(pid: 123).encoded().write(to: dead)

    _ = QueueReader.read(paths, slotCount: 1, sweep: false)
    #expect(FileManager.default.fileExists(atPath: dead.path))
    _ = QueueReader.read(paths, slotCount: 1)
    #expect(!FileManager.default.fileExists(atPath: dead.path))
  }

  @Test func sweepsOnlyStaleTempFiles() throws {
    let paths = try prepared()
    let temp = paths.waitingTempFile(pid: 123)
    try Data().write(to: temp)

    _ = QueueReader.read(paths, slotCount: 1, now: .now + 30)
    #expect(FileManager.default.fileExists(atPath: temp.path))
    _ = QueueReader.read(paths, slotCount: 1, now: .now + 61)
    #expect(!FileManager.default.fileExists(atPath: temp.path))
  }

  @Test func skipsOwnFiles() throws {
    let paths = try prepared()
    let own = try LockFile(path: paths.slotFile(0))
    #expect(own.tryLock())
    try own.write(record(pid: getpid()))

    let state = QueueReader.read(paths, slotCount: 2, ownPID: getpid())
    #expect(state.holders.isEmpty)
    #expect(state.freeSlots == [1])
    #expect(!otherProcessCanLock(paths.slotFile(0)))
    own.unlinkAndClose()
  }

  @Test func writeReplacesTheRecordAndRenameKeepsTheLock() throws {
    let paths = try prepared()
    let temp = paths.waitingTempFile(pid: getpid())
    let final = paths.waitingFile(pid: getpid())
    let lock = try LockFile(path: temp)
    #expect(lock.tryLock())
    try lock.write(record(pid: getpid(), startedAt: nil, waitingSince: .now))
    try lock.write(record(pid: 7))
    try lock.rename(to: final)
    #expect(!FileManager.default.fileExists(atPath: temp.path))
    #expect(!otherProcessCanLock(final))
    // Reading through a second descriptor drops this process's lock, so only once it is done.
    #expect(SlotRecord.decoded(from: try Data(contentsOf: final))?.pid == 7)
    lock.unlinkAndClose()
    #expect(!FileManager.default.fileExists(atPath: final.path))
  }
}
