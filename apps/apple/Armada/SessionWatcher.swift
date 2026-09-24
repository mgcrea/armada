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

/// At most `limit` whole-transcript reads at once, across every account.
///
/// **Launch is the case this exists for.** Every session adopted at startup schedules
/// its one deep scan in the same instant, nineteen of them on this Mac with the largest
/// transcript at 50MB, and a detached task each held every one of those files in memory
/// together. Two at a time finishes the backlog a little later and caps the peak at the
/// two largest files, which is invisible to a row that already renders its registry name
/// while it waits for a title.
private actor DeepScanGate {
  private let limit: Int
  private var running = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = limit
  }

  func acquire() async {
    guard running >= limit else {
      running += 1
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  /// Hands the slot straight to the next waiter rather than freeing it, so a scan that
  /// arrives in between cannot jump the queue.
  func release() {
    if waiting.isEmpty {
      running -= 1
    } else {
      waiting.removeFirst().resume()
    }
  }
}

/// What one deep scan found. See `SessionWatcher.deepScanInBackground`.
private nonisolated struct DeepScan: Sendable {
  let title: String?
  let reading: ContextReading?
  let baseline: ContextBaseline?
  let compaction: Compaction?
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

  /// Shared by every account's watcher, because memory is shared by every account.
  private nonisolated static let deepScans = DeepScanGate(limit: 2)

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

  /// Tear the watch down: the stream, then the clock, then the list.
  ///
  /// The stream's context holds this watcher UNRETAINED, so it is stopped and
  /// invalidated here, before whatever owns the watcher lets go of it. A callback
  /// already queued is safe — the `Task` it creates holds the watcher strongly.
  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    timer?.cancel()
    timer = nil
    byId = [:]
    sessions = []
  }

  /// The newest rate-limit refusal across this folder's sessions, live or spent.
  ///
  /// Folder-wide because that is the scope a plan limit has: the windows belong to
  /// the organization, not to the session that happened to be refused first, so a
  /// refusal in any one of them describes all of them.
  var newestQuotaHit: QuotaHit? {
    sessions.compactMap(\.quotaHit).max { $0.at < $1.at }
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
        // **Take the new copy.** The session keeps its identity — and so its title,
        // transcript and context readings — but the registry itself is a live
        // document: `status`, `waitingFor` and `updatedAt` all move inside it, and
        // keeping the copy read at adoption would freeze the reported state and the
        // last-activity time at the moment the row first appeared.
        // Guarded on inequality. `Session` is `@Observable`, so an unconditional
        // assignment invalidates every view reading any registry field on every
        // rescan — and a rescan runs whenever *any* session in the folder rewrites its
        // file, which with a dozen sessions is most seconds. `SessionRegistry` is a
        // `Hashable` value type, so this compares by content.
        if existing.registry != registry {
          existing.registry = registry
          refreshState(existing, wrote: false)
        }
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
    //
    // **This is the baseline order, not the presented one.** `next` is a dictionary
    // and has no order of its own, so something deterministic has to be imposed here
    // or rows shuffle on every FSEvents tick. The window layers `SessionOrder` on top
    // of this array, and the menu bar panel reads it directly through
    // `Accounts.allSessions` — the panel shows three of nineteen, so its three have to
    // stay the newest three whatever the window is set to. Do not make this
    // preference-driven.
    sessions = next.values.sorted {
      ($0.registry.startedAt ?? 0, $0.id) > ($1.registry.startedAt ?? 0, $1.id)
    }
  }

  /// Route a batch of filesystem events.
  ///
  /// One file name and one dictionary lookup per path, rather than every path against
  /// every session with a `URL` built for each pair: a busy turn delivers dozens of
  /// paths a batch, and a folder can hold nineteen sessions. A session written several
  /// times in one batch is refreshed once, which is all the size gate in `refreshTitle`
  /// would have let through anyway.
  fileprivate func handle(paths: [String]) {
    let sessionsPath = folder.sessionsDir.path(percentEncoded: false)
    var needsRescan = false
    var written: [Session] = []
    var seen: Set<String> = []

    for path in paths {
      if path.hasPrefix(sessionsPath) {
        needsRescan = true
        continue
      }
      // A transcript write. Exact filename match, so a subagent writing under
      // `projects/<enc-cwd>/<sessionId>/…` does not mark its parent working.
      guard let id = TranscriptLocator.sessionID(ofTranscriptPath: path),
        let session = byId[id], seen.insert(id).inserted
      else { continue }
      if session.transcript == nil { session.transcript = URL(filePath: path) }
      written.append(session)
    }

    if !written.isEmpty { UsageIndex.shared.noteActivity() }
    for session in written {
      session.lastWrite = Date()
      refreshTitle(session)
      refreshState(session, wrote: true)
    }

    if needsRescan { rescan() }
  }

  /// The 1s sweep: apply the idle threshold, and catch a session whose process
  /// went away without its registry file going with it.
  private func tick() {
    let now = Date()
    for session in sessions {
      guard session.state != .idle else { continue }
      // **Skip anything the registry reported.** The idle threshold exists to age out
      // a `.working` that was set by a transcript write and never contradicted; a
      // reported state needs no ageing, and a session parked on a permission prompt is
      // silent for minutes on purpose. Blanking that to idle after 20s is exactly the
      // lie this threshold used to tell.
      guard SessionState(registryStatus: session.registry.status) == nil else { continue }
      let silence = now.timeIntervalSince(session.lastWrite ?? .distantPast)
      // Every second, for as long as a session sits on a tool call with no status
      // reported. That costs a `stat` rather than a tail read: see
      // `isAwaitingToolResult(_:transcript:)`.
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
  /// Also carries the rate-limit refusal out of the same buffer.
  ///
  /// Two things are wanted from a transcript's tail and they are wanted on the same
  /// event, so they share one read. `TranscriptTitle.tail(of:)` exists for that:
  /// adding the quota scan as a second `…(at:)` call would have doubled the I/O of
  /// every transcript write to find a record that is absent from almost all of them.
  private func refreshTitle(_ session: Session) {
    if session.transcript == nil { locateTranscript(session) }
    guard let transcript = session.transcript else { return }
    // One `attributesOfItem`, two answers. The size gates the read below; the
    // modification date seeds `lastWrite`, and asking for both costs one `stat`.
    let attributes =
      (try? FileManager.default.attributesOfItem(atPath: transcript.path(percentEncoded: false)))
      ?? [:]
    let size = attributes[.size] as? UInt64 ?? 0

    // **Above the size gate, on purpose.** `lastWrite` is otherwise set only from
    // FSEvents observed while Armada is running, so every session adopted at launch
    // has none until it next writes — and a list ordered by last activity over a
    // column that is nil for most rows is not an ordering, it is the id tiebreak
    // wearing a date's name. The file itself knows, and the gate below returns early
    // on an unchanged file, which is exactly the cold-start case this is for.
    //
    // Never moves the value backwards: a write this process actually saw stamps
    // `Date()`, which is at or after the mtime that caused it, so the live value
    // always wins. And it cannot invent a state — `refreshState` sets `.working`
    // only on `wrote: true`, which nothing here passes. Its one second-order effect
    // is that `tick()`'s idle sweep skips a freshly adopted session for up to 20s,
    // which is harmless: `rescan()` already ran the tool-use check on adoption.
    if let modified = attributes[.modificationDate] as? Date,
      modified > (session.lastWrite ?? .distantPast)
    {
      session.lastWrite = modified
    }

    guard size != session.titleScannedSize || session.title == nil else { return }
    session.titleScannedSize = size

    guard let tail = TranscriptTitle.tail(of: transcript) else { return }

    // The tool-use answer rides the same read, stamped with the `stat` above, so the
    // `refreshState` that follows an adoption finds it cached rather than reading this
    // tail a second time. A file that grew between the `stat` and the read leaves an
    // answer newer than its stamp, which only costs the next check a re-read.
    if let modified = attributes[.modificationDate] as? Date {
      session.toolResultCheck = (
        size, modified,
        TranscriptTitle.isAwaitingToolResult(
          inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine)
      )
    }

    // Newest wins, and nothing found leaves what is already held — see
    // `Session.quotaHit` for why an absent record is not a retraction.
    if let hit = TranscriptQuota.newestHit(
      inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine),
      hit.at > (session.quotaHit?.at ?? .distantPast)
    {
      session.quotaHit = hit
    }

    refreshContext(session, tail: tail)

    if let title = TranscriptTitle.newestTitle(
      inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine)
    {
      session.title = title
    }

    // **Runs whether or not the title was found**, unlike the earlier cut of this,
    // because two of the three things it now returns have nothing to do with titles:
    // the opening context reading and the compaction record are wanted for every
    // session. That widens the full scan from the 16 of 19 live sessions that needed
    // it for a title to all of them — a bounded one-off, still detached, still at
    // most once per session.
    guard !session.didFullScan else { return }
    session.didFullScan = true
    deepScanInBackground(sessionId: session.id, transcript: transcript)
  }

  /// The context figures, off the tail buffer the caller already read.
  ///
  /// Everything here is a recorded number. What Claude Code's `/context` shows and
  /// this cannot is the *composition* of the fixed prefix — see `TranscriptContext`.
  ///
  /// **Nothing found leaves what is already held**, the same rule as `quotaHit`. A
  /// 64KB tail can legitimately contain no `assistant` entry at all: measured on a
  /// live session here, a burst of edits wrote 140KB of `file-history` entries after
  /// the last turn, putting both of the file's assistant lines outside the window.
  /// Clearing on that would blank the panel of a session that is merely busy, and the
  /// next assistant turn is appended at the end of the file — so the tail is
  /// guaranteed to carry it — which makes holding the previous reading correct rather
  /// than merely convenient.
  private func refreshContext(_ session: Session, tail: (chunk: Data, droppingFirstLine: Bool)) {
    // The unfiltered reading, not `series.last`. Every block of one request repeats
    // the same `usage` object, and a tail can start part-way through a request and
    // hold only its blocks 1 and 2 — which `series` drops, because it filters to
    // block 0 to keep its per-request rate honest. The totals are identical, so the
    // current figure should take whichever block it can get.
    if let newest = TranscriptContext.newestReading(
      inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine)
    {
      session.context = newest
    }

    let series = TranscriptContext.series(
      inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine)
    if series.count >= 2 { session.previousContext = series.dropLast().last }
    // The newest turn that wrote to the cache names its lifetime; one that hit it in
    // full names nothing, so it falls through to the requests before it.
    if let ttl = session.context?.cacheTTL ?? series.reversed().lazy.compactMap(\.cacheTTL).first {
      session.cacheTTL = ttl
    }
    if let growth = ContextGrowth(series: series) { session.growth = growth }

    // Newest wins, and an absent one leaves what is held: this attachment is written
    // when the model is set, so it scrolls out of the tail as the session carries on
    // and its absence is not a change of model.
    if let modelID = TranscriptContext.newestModelID(
      inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine)
    {
      session.sessionModelID = modelID
    }
  }

  /// The once-per-session deep scan, off the main actor.
  ///
  /// Three answers out of **one** read of the file, which is the whole reason they
  /// share a pass:
  ///
  /// - the title, when the tail did not have it;
  /// - the opening context reading, from the head of the same buffer. The first
  ///   `assistant` entry sits a median 61.6KB in, max 193KB across 30 transcripts;
  /// - the newest compaction, which no tail can reach: measured across 40 transcripts
  ///   over 500KB, the 4 that had compacted carried the boundary 160KB to 8.7MB from
  ///   the end.
  ///
  /// **The title is not the ~4% case the spike reported.** Measured against this
  /// machine's 19 live sessions, only 3 had their newest title inside the 64KB tail —
  /// 16%, against the spike's 96%. The spike sampled 553 transcripts "active in the
  /// prior 3 weeks", a population full of short recent ones; Armada looks only at
  /// sessions that are live *now*, which skew long-running (9–16 hours and 0.6–9.5MB
  /// here) and long past their last title write, with p99 4MB and max 13MB between
  /// the newest title and the end of the file. So the whole-file read is the common
  /// path for this app, not the rare one, and it is sized accordingly: 54MB and 141ms
  /// across those 19, which is why it runs detached, why it runs at most once per
  /// session, and why `DeepScanGate` lets only two run at a time.
  ///
  /// Keyed by session id rather than capturing the `Session`, which is
  /// `@Observable` and main-actor state: the answers are applied to whichever
  /// session still holds that id when they land, and dropped if the session ended
  /// while the scan was running.
  private func deepScanInBackground(sessionId: String, transcript: URL) {
    Task.detached(priority: .utility) { [weak self] in
      await SessionWatcher.deepScans.acquire()
      let found = SessionWatcher.deepScan(transcript)
      await SessionWatcher.deepScans.release()
      guard let found else { return }

      await MainActor.run {
        guard let self, let session = self.byId[sessionId] else { return }
        if let title = found.title, session.title == nil { session.title = title }
        if let reading = found.reading, session.context == nil { session.context = reading }
        if let ttl = found.reading?.cacheTTL, session.cacheTTL == nil { session.cacheTTL = ttl }
        session.baseline = found.baseline
        session.compaction = found.compaction
      }
    }
  }

  /// The read and the three parses, as one synchronous function the gate can bracket.
  ///
  /// The parsers walk the buffer through `JSONLines`, so what this holds is the file
  /// itself and nothing proportional to it on top.
  private nonisolated static func deepScan(_ transcript: URL) -> DeepScan? {
    guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
    defer { try? handle.close() }
    guard let whole = try? handle.readToEnd() else { return nil }

    return DeepScan(
      title: TranscriptTitle.newestTitle(inChunk: whole, droppingFirstLine: false),
      // Seeds the panel for a session whose newest turn is already out of tail range
      // — see `refreshContext`. Applied only if nothing better has arrived.
      reading: TranscriptContext.newestReading(inChunk: whole, droppingFirstLine: false),
      // The baseline is in the first entries, so it is read off a prefix rather than
      // by walking a 50MB buffer that has already answered everything else.
      baseline: TranscriptContext.baseline(inChunk: whole.prefix(TranscriptTitle.headBytes)),
      compaction: TranscriptContext.newestCompaction(inChunk: whole, droppingFirstLine: false))
  }

  /// Working on a write; otherwise the tool-use check decides between "running a
  /// tool" and idle.
  ///
  /// Quitting a session produces a spurious `working` blip — a shutdown write
  /// about 50ms before the registry file disappears. Not special-cased: the
  /// registry event that follows removes the row within ~2s, which is faster than
  /// anyone reads a state dot.
  private func refreshState(_ session: Session, wrote: Bool) {
    // A write this instant outranks everything: it is the freshest evidence there is,
    // and it lands in milliseconds where a registry rewrite has to go through
    // FSEvents and a rescan.
    if wrote {
      session.state = .working
      return
    }

    // The registry's own answer, where it has one.
    if let reported = SessionState(registryStatus: session.registry.status) {
      // The one refinement it cannot make. `busy` is true of a model producing text
      // and of one sitting on an unanswered `tool_use`, and the transcript is the
      // only thing that separates them. Nothing is refined about `waiting` or `idle`
      // — those are complete answers.
      guard reported == .working, let transcript = session.transcript else {
        session.state = reported
        return
      }
      session.state =
        isAwaitingToolResult(session, transcript: transcript) ? .runningTool : .working
      return
    }

    // No reported status: a folder on a build older than the one that started writing
    // it. Everything below is the original inference, unchanged.
    guard let transcript = session.transcript else {
      session.state = .idle
      return
    }
    session.state = isAwaitingToolResult(session, transcript: transcript) ? .runningTool : .idle
  }

  /// Whether the transcript ends on an unanswered `tool_use`, read at most once per
  /// version of the file.
  ///
  /// **Keyed on size and modification date, and that is what bounds `tick()`.** A
  /// session on a build that reports no status, parked on a long tool call, stays
  /// `.runningTool` and is asked about every second for as long as the call runs,
  /// which used to be a 64KB read and a JSON walk each time. A file that has not
  /// changed cannot change the answer, so a `stat` settles it. `refreshTitle` fills the
  /// same cache from the tail it has just read.
  private func isAwaitingToolResult(_ session: Session, transcript: URL) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(
      atPath: transcript.path(percentEncoded: false))
    let size = attributes?[.size] as? UInt64
    let modified = attributes?[.modificationDate] as? Date
    if let size, let modified, let check = session.toolResultCheck,
      check.size == size, check.modified == modified
    {
      return check.awaiting
    }

    guard let tail = TranscriptTitle.tail(of: transcript) else { return false }
    let awaiting = TranscriptTitle.isAwaitingToolResult(
      inChunk: tail.chunk, droppingFirstLine: tail.droppingFirstLine)
    if let size, let modified { session.toolResultCheck = (size, modified, awaiting) }
    return awaiting
  }
}
