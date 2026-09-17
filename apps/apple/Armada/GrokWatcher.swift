import CoreServices
import Foundation

/// The C callback, file-level and `nonisolated` for `codexEventCallback`'s reason.
private nonisolated func grokEventCallback(
  _ stream: ConstFSEventStreamRef,
  _ info: UnsafeMutableRawPointer?,
  _ count: Int,
  _ paths: UnsafeMutableRawPointer,
  _ flags: UnsafePointer<FSEventStreamEventFlags>,
  _ ids: UnsafePointer<FSEventStreamEventId>
) {
  guard let info else { return }
  let watcher = Unmanaged<GrokWatcher>.fromOpaque(info).takeUnretainedValue()
  Task { @MainActor in watcher.scheduleScan() }
}

/// One session directory, as a background scan sees it.
nonisolated struct GrokScanEntry: Sendable {
  let sessionId: String
  let directory: URL
  let size: UInt64
  let modified: Date
  let summaryModified: Date?
  let pid: Int32?
  /// Nil when `updates.jsonl` has not changed since the last scan and the watcher already
  /// holds the session.
  let summary: GrokFiles.Summary?
  let tail: GrokFiles.UpdatesTail?
  let usage: GrokFiles.Usage?
  let context: GrokFiles.Context?
}

/// What a scan needs to know about a session the watcher already holds.
nonisolated struct GrokKnownSession: Sendable {
  let size: UInt64
  let summaryModified: Date?
}

/// Every recent Grok Build session, kept current from the file system.
///
/// Modelled on `CodexWatcher`, and "recent" for its reason: a headless `grok -p` run exits
/// with its turn and never appears in `active_sessions.json`, so a list of open sessions alone
/// would miss every scripted run. Sessions stay listed for `recentWindow` after their last write.
@MainActor
@Observable
final class GrokWatcher {
  nonisolated static let recentWindow: TimeInterval = 12 * 3600

  /// How long a headless session whose last update opened a turn still counts as working.
  /// Nothing on disk names a `grok -p` process, so this is the one guess in the pane.
  nonisolated static let headlessGrace: TimeInterval = 90

  /// `active_sessions.json` sits beside `logs/unified.jsonl`, which Grok writes constantly, so
  /// the home itself is not watched. The sweep picks up a session opening or closing.
  static let sweepInterval: TimeInterval = 5

  nonisolated static let tailBytes = 64 * 1024

  private(set) var sessions: [GrokSession] = []
  private(set) var didScan = false

  let home: GrokHome

  private var byId: [String: GrokSession] = [:]
  private var stream: FSEventStreamRef?
  private var timer: DispatchSourceTimer?
  private var isScanning = false
  private var wantsAnotherScan = false

  private let queue = DispatchQueue(label: "io.mgcrea.armada.grok")

  init(home: GrokHome) {
    self.home = home
  }

  var liveSessions: [GrokSession] { sessions.filter { $0.state.isLive } }
  var workingCount: Int { sessions.count { $0.state == .working } }
  var awaitingInputCount: Int { sessions.count { $0.state == .awaitingInput } }

  func start() {
    guard stream == nil else { return }
    scheduleScan()

    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagNoDefer)
    // Not the whole tree's SQLite search index either, but FSEvents cannot exclude a file, and
    // a scan that finds nothing changed reads no file.
    let watched = [home.sessionsDir.path(percentEncoded: false)] as CFArray
    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault, grokEventCallback, &context, watched,
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

  /// See `CodexWatcher.stop()`.
  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    timer?.cancel()
    timer = nil
    wantsAnotherScan = false
    byId = [:]
    sessions = []
  }

  func scheduleScan() {
    guard !isScanning else {
      wantsAnotherScan = true
      return
    }
    isScanning = true
    let home = self.home
    let known = byId.mapValues { GrokKnownSession(size: $0.scannedSize, summaryModified: $0.summaryModified) }
    Task.detached(priority: .utility) {
      let entries = GrokWatcher.scan(home: home, known: known)
      await MainActor.run { self.apply(entries) }
    }
  }

  /// Off the main actor. Lists two levels of directories, stats one file per session, and
  /// opens a session's files only when its `updates.jsonl` has grown.
  nonisolated static func scan(home: GrokHome, known: [String: GrokKnownSession]) -> [GrokScanEntry] {
    let fileManager = FileManager.default
    let open = (try? Data(contentsOf: home.activeSessions)).map(GrokFiles.activeSessions) ?? []
    var pids: [String: Int32] = [:]
    for entry in open where kill(entry.pid, 0) == 0 || errno == EPERM {
      pids[entry.sessionId] = entry.pid
    }
    let cutoff = Date.now.addingTimeInterval(-recentWindow)
    var entries: [GrokScanEntry] = []

    let projects =
      (try? fileManager.contentsOfDirectory(
        at: home.sessionsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for project in projects where project.hasDirectoryPath {
      let children =
        (try? fileManager.contentsOfDirectory(atPath: project.path(percentEncoded: false))) ?? []
      for name in children where GrokFiles.isSessionId(name) {
        let sessionId = name.lowercased()
        let directory = project.appending(path: name, directoryHint: .isDirectory)
        let updates = directory.appending(path: "updates.jsonl", directoryHint: .notDirectory)
        let attributes =
          (try? fileManager.attributesOfItem(atPath: updates.path(percentEncoded: false))) ?? [:]
        let size = (attributes[.size] as? UInt64) ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let summaryURL = directory.appending(path: "summary.json", directoryHint: .notDirectory)
        let summaryModified =
          (try? fileManager.attributesOfItem(atPath: summaryURL.path(percentEncoded: false)))?[
            .modificationDate] as? Date
        let pid = pids[sessionId]
        // An open session stays listed however long it has sat idle.
        guard modified > cutoff || pid != nil else { continue }

        // The title lands in `summary.json` after the turn that earned it, a minute after the
        // last update on the session measured, so its date counts as a change too.
        let changed =
          known[sessionId]?.size != size || known[sessionId]?.summaryModified != summaryModified
        var summary: GrokFiles.Summary?
        var tail: GrokFiles.UpdatesTail?
        var usage: GrokFiles.Usage?
        var context: GrokFiles.Context?
        if changed {
          summary = (try? Data(contentsOf: summaryURL)).flatMap(GrokFiles.summary)
          tail = readTail(updates, size: size)
          usage = (try? Data(contentsOf: directory.appending(path: "usage.json")))
            .flatMap(GrokFiles.usage)
          context = (try? Data(contentsOf: directory.appending(path: "signals.json")))
            .flatMap(GrokFiles.context)
          // Opened and never prompted: a summary and no conversation. Listed only while open.
          if summary == nil, known[sessionId] == nil { continue }
        }
        entries.append(
          GrokScanEntry(
            sessionId: sessionId, directory: directory, size: size, modified: modified,
            summaryModified: summaryModified, pid: pid,
            summary: summary, tail: tail, usage: usage, context: context))
      }
    }
    return entries
  }

  nonisolated private static func readTail(_ url: URL, size: UInt64) -> GrokFiles.UpdatesTail? {
    guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let chunk = try? handle.readToEnd() else { return nil }
    return GrokFiles.updatesTail(chunk, droppingFirstLine: start > 0)
  }

  private func apply(_ entries: [GrokScanEntry]) {
    var next: [String: GrokSession] = [:]
    if entries.contains(where: { $0.tail != nil }) { UsageIndex.shared.noteActivity() }
    let now = Date.now

    for entry in entries {
      let session: GrokSession
      if let existing = byId[entry.sessionId] {
        session = existing
        if let summary = entry.summary { session.summary = summary }
      } else if let summary = entry.summary {
        session = GrokSession(id: entry.sessionId, directory: entry.directory, summary: summary)
      } else {
        continue
      }
      if let tail = entry.tail {
        session.lastEventAt = tail.lastEventAt ?? session.lastEventAt
        session.state = Self.state(pid: entry.pid, running: tail.isTurnRunning, at: tail.lastEventAt, now: now)
      } else {
        session.state = Self.state(
          pid: entry.pid, running: session.state == .working, at: session.lastEventAt, now: now)
      }
      session.usage = entry.usage ?? session.usage
      session.context = entry.context ?? session.context
      session.pid = entry.pid
      session.scannedSize = entry.size
      session.summaryModified = entry.summaryModified
      next[entry.sessionId] = session
    }

    byId = next
    sessions = next.values.sorted {
      ($0.lastEventAt ?? $0.summary.updatedAt ?? .distantPast, $0.id)
        > ($1.lastEventAt ?? $1.summary.updatedAt ?? .distantPast, $1.id)
    }
    didScan = true
    isScanning = false
    if wantsAnotherScan {
      wantsAnotherScan = false
      scheduleScan()
    }
  }

  /// An open TUI session is working or waiting by its last update. A session not open in a TUI
  /// is a headless run, working only while its opened turn is recent.
  nonisolated static func state(pid: Int32?, running: Bool, at: Date?, now: Date)
    -> GrokSessionState
  {
    if pid != nil { return running ? .working : .awaitingInput }
    guard running, let at, now.timeIntervalSince(at) < headlessGrace else { return .ended }
    return .working
  }
}
