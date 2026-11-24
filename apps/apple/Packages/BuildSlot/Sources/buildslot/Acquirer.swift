import BuildSlotCore
import Darwin
import Foundation

/// The slot this process holds while its child builds, or none when the build runs unqueued.
/// The lock lives as long as this value: keep it alive until the process exits.
struct Held {
  let lock: LockFile?
}

/// Waits for a slot. Every failure to queue (the lock folder refused, a file that cannot be
/// opened or written) prints one `running unqueued` line and returns no lock, so the build runs
/// anyway: a queue that breaks builds is worse than none.
enum Acquirer {
  static let pollInterval: useconds_t = 500_000
  static let reprintInterval: TimeInterval = 60

  static func acquire(tool: String, argv: [String], paths: BuildSlotPaths) -> Held {
    do {
      try paths.ensureDirectories()
    } catch {
      return unqueued("cannot use the lock folder \(paths.lockRoot.path) (\(describe(error)))")
    }
    let pid = getpid()
    let cwd = currentDirectory()
    let record = SlotRecord(
      pid: pid, processStart: ProcessTree.startTime(of: pid), startedAt: nil, waitingSince: nil,
      cwd: cwd, label: HolderLabel.label(cwd: cwd), tool: tool, argv: SlotRecord.truncated(argv))

    let start = Date.now
    var waiting: LockFile?
    // Removed once a slot is held or the shim gives up waiting; a shim killed while waiting
    // leaves it unlocked, and the next reader sweeps it.
    defer { waiting?.unlinkAndClose() }
    var memoryWaited: TimeInterval = 0
    var lastPoll = start
    var lastStep: AcquireStep?
    var shownHolders: Set<Int32>?
    var lastPrinted = Date.distantPast

    while true {
      let now = Date.now
      if case .waitForMemory = lastStep { memoryWaited += now.timeIntervalSince(lastPoll) }
      lastPoll = now
      // Re-read every poll, so a changed count or rule applies to shims already waiting.
      let settings = BuildSlotSettings.load(from: paths.settingsFile)
      let state = QueueReader.read(paths, slotCount: settings.slots, ownPID: pid, now: now)
      let pressure = MemoryPressure.current()
      let step = AcquirePolicy.decide(
        state: state, settings: settings, pressure: pressure,
        waitedForSlot: now.timeIntervalSince(start), waitedForMemory: memoryWaited)
      lastStep = step

      switch step {
      case .take(let slot):
        switch take(preferring: slot, count: settings.slots, record: record, paths: paths) {
        case .took(let lock, let slot):
          if waiting != nil {
            say(WaitMessages.gotSlot(slot, after: Date.now.timeIntervalSince(start)))
          }
          return Held(lock: lock)
        case .lost:
          break  // Another shim took it between the read and the lock: poll again.
        case .failed(let reason):
          return unqueued(reason)
        }

      case .waitForSlot, .waitForMemory:
        if waiting == nil {
          do {
            waiting = try register(record, paths: paths, since: now)
          } catch {
            return unqueued("cannot register as waiting (\(describe(error)))")
          }
        }
        let holders = Set(state.holders.map(\.record.pid))
        if holders != shownHolders || now.timeIntervalSince(lastPrinted) >= reprintInterval {
          shownHolders = holders
          lastPrinted = now
          if case .waitForMemory(let level) = step {
            let cap = TimeInterval(settings.memoryWaitCapSeconds)
            say(WaitMessages.waitingForMemory(level, remaining: cap - memoryWaited))
          } else {
            say(
              WaitMessages.waitingForSlot(
                holders: state.holders.map(\.record), busy: settings.slots - state.freeSlots.count,
                total: settings.slots, now: now))
          }
        }

      case .takeAnyway(let slot, let reason):
        switch reason {
        case .memoryCap: say(WaitMessages.memoryCapReached(pressure, after: memoryWaited))
        case .slotCap: say(WaitMessages.slotCapReached(after: now.timeIntervalSince(start)))
        }
        guard let slot else { return Held(lock: nil) }
        if case .took(let lock, _) = take(
          preferring: slot, count: settings.slots, record: record, paths: paths)
        {
          return Held(lock: lock)
        }
        return Held(lock: nil)
      }
      usleep(pollInterval)
    }
  }

  private enum Attempt {
    case took(LockFile, slot: Int)
    case lost
    case failed(String)
  }

  /// Tries `preferred`, then every other slot below the count. The reader's free list is only a
  /// hint: a slot it could not open (EMFILE and the like) reads as busy, yet may be free.
  private static func take(
    preferring preferred: Int, count: Int, record: SlotRecord, paths: BuildSlotPaths
  ) -> Attempt {
    for slot in [preferred] + (0..<count).filter({ $0 != preferred }) {
      let lock: LockFile
      do {
        lock = try LockFile(path: paths.slotFile(slot))
      } catch {
        return .failed("cannot open \(paths.slotFile(slot).path) (\(describe(error)))")
      }
      // A slot not taken closes here, which drops nothing: this process held no lock on it.
      guard lock.tryLock() else { continue }
      var holder = record
      holder.startedAt = .now
      do {
        try lock.write(holder)
      } catch {
        return .failed("cannot write \(lock.path.path) (\(describe(error)))")
      }
      return .took(lock, slot: slot)
    }
    return .lost
  }

  /// Writes and locks the waiting record under a temporary name, then renames it into place, so
  /// no reader ever finds a waiting file that is not yet locked.
  private static func register(_ record: SlotRecord, paths: BuildSlotPaths, since: Date) throws
    -> LockFile
  {
    let file = try LockFile(path: paths.waitingTempFile(pid: record.pid))
    do {
      guard file.tryLock() else { throw POSIXError(.EAGAIN) }
      var waiter = record
      waiter.waitingSince = since
      try file.write(waiter)
      try file.rename(to: paths.waitingFile(pid: record.pid))
      return file
    } catch {
      file.unlinkAndClose()
      throw error
    }
  }

  private static func unqueued(_ reason: String) -> Held {
    say(WaitMessages.unqueued(reason))
    return Held(lock: nil)
  }
}

/// One line on stderr, written at once: the build's own output may follow.
func say(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// The working directory with symlinks resolved, as the nesting rule and the holder record
/// compare it (`/tmp` is `/private/tmp`).
func currentDirectory() -> String {
  let path = FileManager.default.currentDirectoryPath
  guard let real = realpath(path, nil) else { return path }
  defer { free(real) }
  return String(cString: real)
}

/// A short reason for a line on stderr: the POSIX message where there is one, as `ls` would
/// say it, rather than Foundation's sentence about saving a file.
func describe(_ error: any Error) -> String {
  if let error = error as? UnsafeLockDirectory { return error.description }
  if let error = error as? POSIXError { return String(cString: strerror(error.code.rawValue)) }
  let error = error as NSError
  if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
    underlying.domain == NSPOSIXErrorDomain
  {
    return String(cString: strerror(Int32(underlying.code)))
  }
  return error.localizedDescription
}
