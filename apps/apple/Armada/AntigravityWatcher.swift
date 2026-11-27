import CoreServices
import Foundation

/// The C callback, file-level and `nonisolated` for `codexEventCallback`'s reason.
private nonisolated func antigravityEventCallback(
  _ stream: ConstFSEventStreamRef,
  _ info: UnsafeMutableRawPointer?,
  _ count: Int,
  _ paths: UnsafeMutableRawPointer,
  _ flags: UnsafePointer<FSEventStreamEventFlags>,
  _ ids: UnsafePointer<FSEventStreamEventId>
) {
  guard let info else { return }
  let watcher = Unmanaged<AntigravityWatcher>.fromOpaque(info).takeUnretainedValue()
  Task { @MainActor in watcher.scheduleScan() }
}

/// One conversation, as a background scan sees it.
nonisolated struct AntigravityScanEntry: Sendable {
  let id: String
  let summary: AntigravityFiles.Summary?
  let holder: AntigravityPresence.Holder?
  let cwd: String
  let transcriptSize: Int
  /// The transcript read since the last scan, or nil when it has not changed.
  let delta: AntigravityFiles.TranscriptDelta?
  /// Where `delta` was read from: the known offset, or 0 when the file shrank or is new.
  let readFrom: Int
}

/// What a scan needs to know about a conversation the watcher already holds.
nonisolated struct AntigravityKnownSession: Sendable {
  let transcriptOffset: Int
  let transcriptSize: Int
}

/// Every recent Antigravity CLI conversation, kept current from the file system.
///
/// `GrokWatcher`'s structure. The lock files and the summaries database are swept every
/// `sweepInterval`, since presence changes write nothing FSEvents would report beyond a zero-byte
/// file, and the database sits beside logs `agy` writes constantly. FSEvents watches `brain`,
/// where transcripts grow, so a turn shows as it happens.
@MainActor
@Observable
final class AntigravityWatcher {
  static let sweepInterval: TimeInterval = 5

  private(set) var sessions: [AntigravitySession] = []
  private(set) var didScan = false

  let home: AntigravityHome

  private var byId: [String: AntigravitySession] = [:]
  private var stream: FSEventStreamRef?
  private var timer: DispatchSourceTimer?
  private var isScanning = false
  /// Bumped by `stop()`, so a scan already running when it was called is not applied.
  private var generation = 0
  private var wantsAnotherScan = false

  private let queue = DispatchQueue(label: "io.mgcrea.armada.antigravity")

  init(home: AntigravityHome) {
    self.home = home
  }

  var liveSessions: [AntigravitySession] { sessions.filter { $0.state.isLive } }
  var workingCount: Int { sessions.count { $0.state == .working } }
  var awaitingInputCount: Int { sessions.count { $0.state == .awaitingInput } }

  func start() {
    // The timer, not the stream, says whether this is running: the stream may fail to open.
    guard timer == nil else { return }
    scheduleScan()

    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagNoDefer)
    let watched = [home.brainDir.path(percentEncoded: false)] as CFArray
    if let created = FSEventStreamCreate(
      kCFAllocatorDefault, antigravityEventCallback, &context, watched,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
    {
      FSEventStreamSetDispatchQueue(created, queue)
      FSEventStreamStart(created)
      stream = created
    }

    // The sweep runs even without a stream: `brain` is missing until the first conversation,
    // and the locks and the database are read only here.
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
    generation += 1
    byId = [:]
    sessions = []
  }

  func scheduleScan() {
    // As in `CodexWatcher.scheduleScan()`: a capture's home does not exist, and a scan
    // would replace the seeded sessions with the nothing it finds there.
    guard !ScreenshotMode.isEnabled else { return }
    guard !isScanning else {
      wantsAnotherScan = true
      return
    }
    isScanning = true
    let home = self.home
    let known = byId.mapValues {
      AntigravityKnownSession(
        transcriptOffset: $0.transcriptOffset, transcriptSize: $0.transcriptSize)
    }
    let generation = self.generation
    Task.detached(priority: .utility) {
      let entries = AntigravityWatcher.scan(home: home, known: known)
      await MainActor.run { self.apply(entries, generation: generation) }
    }
  }

  /// Off the main actor. Reads the database and the `agy` processes' open files, stats one
  /// transcript per listed conversation, and reads a transcript only past what was read before.
  nonisolated static func scan(
    home: AntigravityHome, known: [String: AntigravityKnownSession]
  ) -> [AntigravityScanEntry] {
    let now = Date.now
    // Every row: a held conversation is listed however long ago its row was written, and
    // `merge` drops the stale unheld ones.
    let summaries = AntigravityFiles.summaries(databaseAt: home.summariesDB, since: .distantPast)
    let holders = AntigravityPresence.holders(presenceDir: home.presenceDir)
    let lastConversations =
      (try? Data(contentsOf: home.lastConversations)).map(AntigravityFiles.lastConversations)
      ?? [:]
    let listed = AntigravityFiles.merge(
      summaries: summaries, holders: holders, lastConversations: lastConversations, now: now)

    let fileManager = FileManager.default
    var entries: [AntigravityScanEntry] = []
    for item in listed {
      let url = home.transcript(id: item.id)
      let size =
        ((try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size]
        as? NSNumber)?.intValue ?? 0
      let previous = known[item.id]
      var delta: AntigravityFiles.TranscriptDelta?
      var readFrom = 0
      if size != previous?.transcriptSize ?? 0 {
        // A file shorter than last time was replaced: start over.
        readFrom = previous.map { size < $0.transcriptSize ? 0 : $0.transcriptOffset } ?? 0
        // Nil when the file went between the stat and the read: the size is not taken, so the
        // next scan tries again.
        delta = read(url, from: readFrom).map(AntigravityFiles.transcriptDelta)
      }
      entries.append(
        AntigravityScanEntry(
          id: item.id, summary: item.summary, holder: item.holder, cwd: item.cwd,
          transcriptSize: size, delta: delta, readFrom: readFrom))
    }
    return entries
  }

  nonisolated private static func read(_ url: URL, from offset: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(offset))
    return try? handle.readToEnd() ?? Data()
  }

  private func apply(_ entries: [AntigravityScanEntry], generation: Int) {
    // A scan started before `stop()` lands on a watcher nothing shows any more, and what
    // it read would still be recorded as activity.
    guard generation == self.generation else { return scanFinished() }
    var next: [String: AntigravitySession] = [:]
    if entries.contains(where: { ($0.delta?.steps ?? 0) > 0 }) {
      UsageIndex.shared.noteActivity()
    }

    for entry in entries {
      let session =
        byId[entry.id]
        ?? AntigravitySession(
          id: entry.id, transcriptURL: home.transcript(id: entry.id), summary: entry.summary,
          cwd: entry.cwd)
      session.summary = entry.summary
      session.cwd = entry.cwd
      session.holder = entry.holder
      session.state = AntigravitySessionState.of(holder: entry.holder, summary: entry.summary)
      if let delta = entry.delta {
        if entry.readFrom == 0 {
          session.inputTokens = 0
          session.outputTokens = 0
          session.cacheReadTokens = 0
        }
        session.inputTokens += delta.inputTokens
        session.outputTokens += delta.outputTokens
        session.cacheReadTokens += delta.cacheReadTokens
        session.model = delta.model ?? session.model
        session.lastPrompt = delta.lastPrompt ?? session.lastPrompt
        session.lastEventAt = delta.lastStepAt ?? session.lastEventAt
        session.transcriptOffset = entry.readFrom + delta.consumed
        session.transcriptSize = entry.transcriptSize
      } else if entry.transcriptSize == 0 {
        session.transcriptOffset = 0
        session.transcriptSize = 0
      }
      next[entry.id] = session
    }

    byId = next
    sessions = next.values.sorted {
      ($0.lastEventAt ?? $0.summary?.lastModified ?? .distantPast, $0.id)
        > ($1.lastEventAt ?? $1.summary?.lastModified ?? .distantPast, $1.id)
    }
    didScan = true
    scanFinished()
  }

  /// The end of a scan, whether or not it was applied: the next one may start, and one
  /// asked for meanwhile does.
  private func scanFinished() {
    isScanning = false
    if wantsAnotherScan {
      wantsAnotherScan = false
      scheduleScan()
    }
  }
}

#if DEBUG
  extension AntigravityWatcher {
    /// A capture's sessions, never read from disk. See `DemoSeed`.
    func demoInstall(_ sessions: [AntigravitySession]) {
      self.sessions = sessions
      didScan = true
    }
  }
#endif
