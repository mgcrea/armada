import CoreServices
import Foundation

/// The C callback. A file-level `nonisolated` function rather than a closure
/// literal, because under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a closure
/// written here would be MainActor-isolated and will not convert to a C function
/// pointer.
private nonisolated func sessionEventCallback(
  _ stream: ConstFSEventStreamRef,
  _ info: UnsafeMutableRawPointer?,
  _ count: Int,
  _ paths: UnsafeMutableRawPointer,
  _ flags: UnsafePointer<FSEventStreamEventFlags>,
  _ ids: UnsafePointer<FSEventStreamEventId>
) {
  guard let info,
    let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]
  else { return }
  let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
  Task { @MainActor in watcher.handle(paths: cfPaths) }
}

/// Every live Claude Code session, kept current from the filesystem.
///
/// Watches rather than polls, which is the fleet convention and here also the only
/// thing fast enough: measured latencies from the spike are 12–102ms to notice a
/// new session, 3–17ms to notice a transcript write. `fs.watch` in Node misses
/// atomic renames on macOS; FSEvents with `kFSEventStreamCreateFlagFileEvents`
/// does not.
@MainActor
@Observable
final class SessionWatcher {
  /// 20 seconds of silence marks a session idle. A genuinely finished session went
  /// idle 21s after its last write in the spike (20s threshold plus the 1s tick),
  /// which was correct.
  static let idleAfter: TimeInterval = 20

  private(set) var sessions: [Session] = []

  let folder: ClaudeConfigFolder

  private var byId: [String: Session] = [:]
  private var stream: FSEventStreamRef?
  private var timer: DispatchSourceTimer?

  /// FSEvents delivers on this queue; every handler hops to the main actor. The
  /// work itself is small — a directory listing, or a 64KB tail read.
  private let queue = DispatchQueue(label: "io.mgcrea.armada.fsevents")

  /// One per config folder. Not a singleton: each account has its own
  /// `sessions/` and `projects/` trees, and folding them into one stream would
  /// mean routing every event back to a folder by path prefix for no gain.
  init(folder: ClaudeConfigFolder) {
    self.folder = folder
  }

  func start() {
    guard stream == nil else { return }
    rescan()

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
    let watched =
      [
        folder.sessionsDir.path(percentEncoded: false),
        folder.projectsDir.path(percentEncoded: false),
      ] as CFArray

    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault, sessionEventCallback, &context, watched,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
    else { return }

    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created

    // Idleness is the absence of events, so it needs a clock. Liveness is swept
    // here too, because a crashed session leaves its registry file behind.
    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now() + 1, repeating: 1)
    tick.setEventHandler { MainActor.assumeIsolated { self.tick() } }
    tick.resume()
    timer = tick
  }

  /// Rebuild the session list from `~/.claude/sessions`.
  ///
  /// Called on any registry event and on the liveness sweep. Sessions that survive
  /// keep their identity — and so their title, state and last-write time — because
  /// re-deriving those on every event would re-read a transcript for nothing.
  func rescan() {
    let live = SessionRegistry.scan(in: folder.sessionsDir)
    var next: [String: Session] = [:]

    for registry in live {
      if let existing = byId[registry.sessionId] {
        next[registry.sessionId] = existing
        continue
      }
      let session = Session(registry: registry)
      locateTranscript(session)
      refreshTitle(session)
      // A session Armada did not watch start is not necessarily idle, but nothing
      // on disk says otherwise until it writes. The tool-use check is the one
      // thing that can contradict it, so it runs on adoption too.
      refreshState(session, wrote: false)
      next[registry.sessionId] = session
    }

    byId = next
    // Newest first: the session someone just started is the one they are looking
    // for, and a stable sort keyed on start time keeps rows from jumping.
    sessions = next.values.sorted {
      ($0.registry.startedAt ?? 0, $0.id) > ($1.registry.startedAt ?? 0, $1.id)
    }
  }

  /// Route a batch of filesystem events.
  fileprivate func handle(paths: [String]) {
    let sessionsPath = folder.sessionsDir.path(percentEncoded: false)
    var needsRescan = false

    for path in paths {
      if path.hasPrefix(sessionsPath) {
        needsRescan = true
        continue
      }
      // A transcript write. Exact filename match, so a subagent writing under
      // `projects/<enc-cwd>/<sessionId>/…` does not mark its parent working.
      for session in sessions
      where TranscriptLocator.isTranscript(path: path, sessionId: session.id) {
        if session.transcript == nil { session.transcript = URL(filePath: path) }
        session.lastWrite = Date()
        refreshTitle(session)
        refreshState(session, wrote: true)
      }
    }

    if needsRescan { rescan() }
  }

  /// The 1s sweep: apply the idle threshold, and catch a session whose process
  /// went away without its registry file going with it.
  private func tick() {
    let now = Date()
    for session in sessions {
      guard session.state != .idle else { continue }
      let silence = now.timeIntervalSince(session.lastWrite ?? .distantPast)
      if silence > Self.idleAfter {
        refreshState(session, wrote: false)
      }
    }
    if sessions.contains(where: { !$0.registry.isAlive }) { rescan() }
  }

  private func locateTranscript(_ session: Session) {
    session.transcript = TranscriptLocator.find(
      sessionId: session.registry.sessionId,
      cwd: session.registry.cwd,
      in: folder.projectsDir)
  }

  /// Re-read the title if the file grew.
  ///
  /// Gated on size so a burst of writes costs one tail read, and so the full-scan
  /// fallback is attempted at most once per session rather than on every event.
  ///
  /// The tail read stays inline: it is 64KB and the answer is wanted in the same
  /// frame the row appears. The **full scan does not**, because it is not the rare
  /// case the spike suggested — 16 of this machine's 19 live sessions need it, for
  /// 54MB and 141ms all told. Inline, that is a visible stall on every cold start
  /// and it grows with both session count and session age. So it runs detached and
  /// the title arrives a moment later, which is what the rows are built to do
  /// anyway: an untitled session already renders its registry name.
  private func refreshTitle(_ session: Session) {
    if session.transcript == nil { locateTranscript(session) }
    guard let transcript = session.transcript else { return }
    let size =
      (try? FileManager.default.attributesOfItem(atPath: transcript.path(percentEncoded: false))[
        .size]) as? UInt64 ?? 0
    guard size != session.titleScannedSize || session.title == nil else { return }
    session.titleScannedSize = size

    if let title = TranscriptTitle.newestTitle(at: transcript) {
      session.title = title
      return
    }
    guard session.title == nil, !session.didFullScan else { return }
    session.didFullScan = true
    scanTitleInBackground(sessionId: session.id, transcript: transcript)
  }

  /// The full scan, off the main actor.
  ///
  /// Keyed by session id rather than capturing the `Session`, which is
  /// `@Observable` and main-actor state: the answer is applied to whichever
  /// session still holds that id when it lands, and dropped if the session ended
  /// while the scan was running.
  private func scanTitleInBackground(sessionId: String, transcript: URL) {
    Task.detached(priority: .utility) { [weak self] in
      guard let title = TranscriptTitle.newestTitle(at: transcript, fullScanFallback: true)
      else { return }
      await MainActor.run {
        guard let self, let session = self.byId[sessionId], session.title == nil else { return }
        session.title = title
      }
    }
  }

  /// Working on a write; otherwise the tool-use check decides between "running a
  /// tool" and idle.
  ///
  /// Quitting a session produces a spurious `working` blip — a shutdown write
  /// about 50ms before the registry file disappears. Not special-cased: the
  /// registry event that follows removes the row within ~2s, which is faster than
  /// anyone reads a state dot.
  private func refreshState(_ session: Session, wrote: Bool) {
    if wrote {
      session.state = .working
      return
    }
    guard let transcript = session.transcript else {
      session.state = .idle
      return
    }
    session.state = TranscriptTitle.isAwaitingToolResult(at: transcript) ? .runningTool : .idle
  }
}
