import CoreServices
import Foundation

/// The C callback. A file-level `nonisolated func` for the same reason
/// `sessionEventCallback` is one: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// a closure written here is main-actor isolated and will not convert to a C
/// function pointer.
private nonisolated func codexEventCallback(
  _ stream: ConstFSEventStreamRef,
  _ info: UnsafeMutableRawPointer?,
  _ count: Int,
  _ paths: UnsafeMutableRawPointer,
  _ flags: UnsafePointer<FSEventStreamEventFlags>,
  _ ids: UnsafePointer<FSEventStreamEventId>
) {
  guard let info else { return }
  let watcher = Unmanaged<CodexWatcher>.fromOpaque(info).takeUnretainedValue()
  Task { @MainActor in watcher.scheduleScan() }
}

/// One rollout, as a background scan sees it.
nonisolated struct CodexScanEntry: Sendable {
  let sessionId: String
  let rollout: URL
  let size: UInt64
  let modified: Date
  let locked: Bool
  /// Nil when the file has not changed since the last scan and the caller already
  /// holds a parsed copy.
  let meta: CodexSessionMeta?
  let tail: CodexRolloutTail?
}

nonisolated struct CodexScan: Sendable {
  let entries: [CodexScanEntry]
  let titles: [String: String]
  /// The newest rate limits seen in anything this scan actually read.
  let rateLimits: CodexRateLimits?
}

/// Every recent Codex session, kept current from the filesystem.
///
/// The Claude side's `SessionWatcher` can rebuild its whole list from one
/// directory listing, because `sessions/<pid>.json` is a registry. There is no
/// registry here, so this composes three sources: the rollout files under
/// `sessions/YYYY/MM/DD` for what exists, `thread-writer-locks/` for what is live,
/// and `session_index.jsonl` for names.
///
/// **The list is "recent", not "live", and that is a real difference from the
/// Claude pane.** A `codex exec` run exits when its turn ends, so a list of only
/// live sessions would be empty almost all the time and would never show the
/// automation runs that account for most of this machine's Codex usage. So
/// sessions stay in the list for `recentWindow` after their last event, marked
/// `ended`.
@MainActor
@Observable
final class CodexWatcher {
  /// How long a finished session stays in the list. Long enough to cover a working
  /// morning, short enough that the pane is about today.
  ///
  /// `nonisolated`, like `daysBack`: `scan` reads both and runs off the main actor.
  nonisolated static let recentWindow: TimeInterval = 12 * 3600

  /// How many day directories back to look. Covers `recentWindow` with room for a
  /// session that started days ago and is still running — an hour of clock skew or
  /// a long weekend session should not make a live row vanish.
  nonisolated static let daysBack = 7

  /// A floor under the watch. FSEvents covers every write, but a lock disappearing
  /// when a process is killed is the kind of thing worth sweeping for.
  static let sweepInterval: TimeInterval = 5

  private(set) var sessions: [CodexSession] = []
  private(set) var rateLimits: CodexRateLimits?
  private(set) var didScan = false

  let home: CodexHome

  private var byId: [String: CodexSession] = [:]
  private var stream: FSEventStreamRef?
  private var timer: DispatchSourceTimer?
  private var isScanning = false
  private var wantsAnotherScan = false

  private let queue = DispatchQueue(label: "io.mgcrea.armada.codex")

  init(home: CodexHome) {
    self.home = home
  }

  var liveSessions: [CodexSession] { sessions.filter { $0.state.isLive } }
  var workingCount: Int { sessions.count { $0.state == .working } }

  func start() {
    guard stream == nil else { return }
    scheduleScan()

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagNoDefer)
    // The sessions tree and the locks directory. Not the home itself: `~/.codex`
    // holds four SQLite databases with their WAL files, and watching it would fire
    // this scan continuously while the ChatGPT app is running.
    let watched =
      [
        home.sessionsDir.path(percentEncoded: false),
        home.locksDir.path(percentEncoded: false),
      ] as CFArray

    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault, codexEventCallback, &context, watched,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
    else { return }

    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created

    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
    tick.setEventHandler { MainActor.assumeIsolated { self.scheduleScan() } }
    tick.resume()
    timer = tick
  }

  /// Coalesce: a burst of writes during a turn is one scan, and a scan that
  /// arrives while one is running sets a flag rather than piling up.
  func scheduleScan() {
    guard !isScanning else {
      wantsAnotherScan = true
      return
    }
    isScanning = true

    let home = self.home
    let known = byId.mapValues { ($0.tailScannedSize, $0.meta) }

    Task.detached(priority: .utility) {
      let scan = CodexWatcher.scan(home: home, known: known)
      await MainActor.run { self.apply(scan) }
    }
  }

  /// The filesystem work, off the main actor.
  ///
  /// Bounded three ways, because this runs on every filesystem event in a busy
  /// directory: at most `daysBack` day directories are listed, only files touched
  /// inside `recentWindow` (or holding a lock) are considered at all, and a file
  /// whose size has not changed since the last scan is not opened.
  nonisolated static func scan(
    home: CodexHome, known: [String: (UInt64, CodexSessionMeta)]
  ) -> CodexScan {
    let fileManager = FileManager.default
    let locked = CodexLocks.liveSessionIDs(in: home.locksDir)
    let cutoff = Date.now.addingTimeInterval(-recentWindow)
    var entries: [CodexScanEntry] = []
    var newest: CodexRateLimits?

    for day in home.dayDirectories(back: daysBack) {
      let names =
        (try? fileManager.contentsOfDirectory(atPath: day.path(percentEncoded: false))) ?? []
      for name in names {
        guard let sessionId = CodexRollout.sessionId(fromFilename: name) else { continue }
        let url = day.appending(path: name, directoryHint: .notDirectory)
        let attributes =
          (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))) ?? [:]
        let size = (attributes[.size] as? UInt64) ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast

        // A locked session stays in scope however old its file is: a session that
        // has been sitting open since yesterday is exactly the one worth showing.
        guard modified > cutoff || locked.contains(sessionId) else { continue }

        let cached = known[sessionId]
        let unchanged = cached?.0 == size
        let meta = unchanged ? nil : CodexRollout.meta(at: url) ?? cached?.1
        let tail = unchanged ? nil : CodexRollout.tail(at: url)

        if let limits = tail?.rateLimits,
          limits.observedAt > (newest?.observedAt ?? .distantPast)
        {
          newest = limits
        }

        entries.append(
          CodexScanEntry(
            sessionId: sessionId, rollout: url, size: size, modified: modified,
            locked: locked.contains(sessionId), meta: meta, tail: tail))
      }
    }

    // Only when something is untitled: the index is 104KB and re-reading it on
    // every write of every rollout would be the most expensive thing here.
    let needsTitles = entries.contains { known[$0.sessionId] == nil }
    let titles = needsTitles ? CodexTitleIndex.read(home.sessionIndex) : [:]

    return CodexScan(entries: entries, titles: titles, rateLimits: newest)
  }

  private func apply(_ scan: CodexScan) {
    var next: [String: CodexSession] = [:]

    for entry in scan.entries {
      let session: CodexSession
      if let existing = byId[entry.sessionId] {
        session = existing
      } else if let meta = entry.meta {
        session = CodexSession(id: entry.sessionId, meta: meta, rollout: entry.rollout)
      } else {
        // No cached session and the file did not parse — a rollout being written
        // as it was read, most likely. It comes back on the next event.
        continue
      }

      if let tail = entry.tail {
        session.lastEventAt = tail.lastEventAt ?? session.lastEventAt
        session.totalTokens = tail.totalTokens ?? session.totalTokens
        session.state = Self.state(locked: entry.locked, tail: tail)
      } else {
        // Nothing was read this pass; only liveness can have changed.
        session.state = Self.state(locked: entry.locked, running: session.state == .working)
      }
      session.tailScannedSize = entry.size
      if session.title == nil, let title = scan.titles[entry.sessionId] {
        session.title = title
      }
      next[entry.sessionId] = session
    }

    byId = next
    sessions = next.values.sorted {
      ($0.lastEventAt ?? $0.meta.startedAt ?? .distantPast, $0.id)
        > ($1.lastEventAt ?? $1.meta.startedAt ?? .distantPast, $1.id)
    }
    if let limits = scan.rateLimits, limits.observedAt > (rateLimits?.observedAt ?? .distantPast) {
      rateLimits = limits
    }
    didScan = true

    isScanning = false
    if wantsAnotherScan {
      wantsAnotherScan = false
      scheduleScan()
    }
  }

  private static func state(locked: Bool, tail: CodexRolloutTail) -> CodexSessionState {
    state(locked: locked, running: tail.isTurnRunning)
  }

  private static func state(locked: Bool, running: Bool) -> CodexSessionState {
    guard locked else { return .ended }
    return running ? .working : .awaitingInput
  }
}
