import BuildSlotCore
import Foundation

/// One holder or waiter in the queue, and the session that started it when one could be named.
nonisolated struct MonitoredEntry: Identifiable, Equatable, Sendable {
  /// The shim's pid.
  let id: Int32
  /// The slot held; nil for a waiter.
  let slot: Int?
  let record: SlotRecord
  let session: MatchCandidate?
  var isHolding: Bool
  /// A waiter while a slot stands free: what holds it back is memory, not the queue.
  let waitsOnMemory: Bool
  /// Started under a `codex` process. With no session named, more than one Codex thread could
  /// own it, and it is still a Codex session's, not a terminal's.
  let viaCodex: Bool

  /// When it took its slot, or when it started waiting.
  var since: Date? { record.startedAt ?? record.waitingSince }

  /// `swift test`, `xcodebuild build`.
  var command: String { WaitMessages.command(record) }

  /// Who started it, for a line that names every entry: the session, else "a Codex session" or
  /// "Terminal".
  var ownerName: String {
    session?.title ?? (viaCodex ? "a Codex session" : "Terminal")
  }

  /// `40 s`, `2 min`; empty for a record carrying neither date.
  func age(at now: Date) -> String {
    since.map { WaitMessages.duration(now.timeIntervalSince($0)) } ?? ""
  }
}

/// The queue as Armada shows it: who holds a slot, who waits, and which session each belongs to.
///
/// **Polled, not watched.** A `kill -9`'d holder releases its lock with no file event, and its
/// record stays on disk, so FSEvents would never say it left. Every 2 s while the switch is on or
/// the last read found a holder or waiter, every 30 s otherwise: a Release build's shims queue
/// builds while a Debug build with its switch off is the one watching, and that should still show,
/// but slot files outlive their holders (a slot is released by closing it, never by unlinking),
/// so files alone are no sign of activity. Turning the switch on calls `nudge()`, so the idle
/// sleep never delays the first read after it. Each poll is a few `open` + `F_GETLK` + small reads,
/// plus a `sysctl` per ancestor of each entry, all off the main actor. The account stores are read
/// on the main actor, before the hop.
@MainActor
@Observable
final class BuildSlotMonitor {
  static let shared = BuildSlotMonitor()

  static let interval: Duration = .seconds(2)
  static let idleInterval: Duration = .seconds(30)

  private(set) var holders: [MonitoredEntry] = []
  private(set) var waiters: [MonitoredEntry] = []
  private(set) var pressure = MemoryPressure.normal

  private var task: Task<Void, Never>?
  /// The sleep between reads, cancelled by `nudge()`.
  private var sleeper: Task<Void, Never>?
  /// Set by `nudge()`: one that comes while a read runs skips the sleep after it.
  private var nudged = false

  private init() {}

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.poll()
        let busy = BuildSlots.shared.isEnabled || !holders.isEmpty || !waiters.isEmpty
        await self.rest(for: busy ? Self.interval : Self.idleInterval)
      }
    }
  }

  /// Reads the queue now rather than at the end of the current sleep.
  func nudge() {
    nudged = true
    sleeper?.cancel()
  }

  private func rest(for duration: Duration) async {
    guard !nudged else {
      nudged = false
      return
    }
    let sleep = Task { _ = try? await Task.sleep(for: duration) }
    sleeper = sleep
    await sleep.value
    sleeper = nil
    nudged = false
  }

  /// The holder or waiter a session started, holding first.
  func entry(forSession id: String) -> MonitoredEntry? {
    holders.first { $0.session?.id == id } ?? waiters.first { $0.session?.id == id }
  }

  private func poll() async {
    let slots = BuildSlots.shared
    let next = await Self.read(
      slotCount: slots.settings.slots, candidates: Self.liveCandidates())
    if holders != next.holders { holders = next.holders }
    if waiters != next.waiters { waiters = next.waiters }
    if pressure != next.pressure { pressure = next.pressure }
  }

  /// Every session that could have started a build now. Claude Code's registry and Grok Build's
  /// `active_sessions.json` name a pid; Codex names none, so its open threads are matched by cwd.
  /// Codex subagents are left out: they share their parent's cwd, and two candidates at one
  /// depth are a tie that names neither.
  private static func liveCandidates() -> [MatchCandidate] {
    let claude = Accounts.shared.allSessions.map {
      MatchCandidate(
        id: $0.id, vendor: "claude", pid: $0.registry.pid, cwd: $0.registry.cwd,
        title: $0.displayName)
    }
    let codex = CodexAccounts.shared.allSessions
      .filter { $0.state.isLive && !$0.isSubagent && !$0.meta.cwd.isEmpty }
      .map {
        MatchCandidate(
          id: $0.id, vendor: "codex", pid: nil, cwd: $0.meta.cwd, title: $0.displayName)
      }
    let grok = GrokAccounts.shared.all.flatMap(\.sessions.sessions).compactMap { session in
      session.pid.map {
        MatchCandidate(
          id: session.id, vendor: "grok", pid: $0, cwd: session.summary.cwd,
          title: session.displayName)
      }
    }
    return claude + codex + grok
  }

  nonisolated struct Reading: Sendable {
    var holders: [MonitoredEntry]
    var waiters: [MonitoredEntry]
    var pressure: MemoryPressure
  }

  /// The queue now. Sweeps the files dead waiters left, as the shims do. A lock folder that
  /// fails the shims' checks (another account's, open to others, a symlink) is read as empty, as
  /// the shims run unqueued beside it: its records are nobody's to show, nor its files to delete.
  @concurrent
  private nonisolated static func read(
    slotCount: Int, candidates: [MatchCandidate]
  ) async -> Reading {
    let paths = BuildSlotPaths.standard()
    guard (try? paths.verifyDirectories()) != nil else {
      return Reading(holders: [], waiters: [], pressure: MemoryPressure.current())
    }
    let state = QueueReader.read(paths, slotCount: slotCount, sweep: true)
    // A holder's cwd is resolved before it is recorded; a Codex thread's is as Codex wrote it,
    // which may be `/tmp/…` for `/private/tmp/…`.
    let resolvedCandidates = candidates.map { candidate in
      var copy = candidate
      if candidate.vendor == "codex" { copy.cwd = resolved(candidate.cwd) }
      return copy
    }
    func entry(_ queued: QueueEntry, holding: Bool) -> MonitoredEntry {
      let ancestors = ProcessTree.ancestors(of: queued.record.pid)
      let names = ancestors.compactMap(ProcessTree.executableName)
      let session = SessionMatch.match(
        ancestors: ancestors, ancestorNames: names, holderCwd: queued.record.cwd,
        candidates: resolvedCandidates)
      let original = session.flatMap { match in
        candidates.first { $0.id == match.id && $0.vendor == match.vendor }
      }
      return MonitoredEntry(
        id: queued.record.pid, slot: queued.slot, record: queued.record, session: original,
        isHolding: holding, waitsOnMemory: !holding && !state.freeSlots.isEmpty,
        viaCodex: names.contains("codex"))
    }
    return Reading(
      holders: state.holders.map { entry($0, holding: true) },
      waiters: state.waiters.map { entry($0, holding: false) },
      pressure: MemoryPressure.current())
  }

  private nonisolated static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }
}
