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

  /// When it took its slot, or when it started waiting.
  var since: Date? { record.startedAt ?? record.waitingSince }

  /// `swift test`, `xcodebuild build`.
  var command: String { WaitMessages.command(record) }

  /// `40 s`, `2 min`; empty for a record carrying neither date.
  func age(at now: Date) -> String {
    since.map { WaitMessages.duration(now.timeIntervalSince($0)) } ?? ""
  }
}

/// The queue as Armada shows it: who holds a slot, who waits, and which session each belongs to.
///
/// **Polled, not watched.** A `kill -9`'d holder releases its lock with no file event, and its
/// record stays on disk, so FSEvents would never say it left. Every 2 s while the switch is on or
/// the lock folder has anything in it; each poll is a few `open` + `F_GETLK` + small reads, plus
/// a `sysctl` per ancestor of each entry, all off the main actor. The account stores are read on
/// the main actor, before the hop.
@MainActor
@Observable
final class BuildSlotMonitor {
  static let shared = BuildSlotMonitor()

  static let interval: Duration = .seconds(2)

  private(set) var holders: [MonitoredEntry] = []
  private(set) var waiters: [MonitoredEntry] = []
  private(set) var pressure = MemoryPressure.normal

  private var task: Task<Void, Never>?

  private init() {}

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.poll()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  /// The holder or waiter a session started, holding first.
  func entry(forSession id: String) -> MonitoredEntry? {
    holders.first { $0.session?.id == id } ?? waiters.first { $0.session?.id == id }
  }

  private func poll() async {
    let slots = BuildSlots.shared
    let reading = await Self.read(
      enabled: slots.isEnabled, slotCount: slots.settings.slots,
      candidates: Self.liveCandidates())
    let next = reading ?? Reading(holders: [], waiters: [], pressure: .normal)
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

  /// The queue now, or nil when there is nothing to read: the switch is off and the lock folder
  /// is empty. Sweeps the files dead waiters left, as the shims do.
  @concurrent
  private nonisolated static func read(
    enabled: Bool, slotCount: Int, candidates: [MatchCandidate]
  ) async -> Reading? {
    let paths = BuildSlotPaths.standard()
    guard enabled || hasFiles(paths) else { return nil }
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
      let session = SessionMatch.match(
        ancestors: ancestors, ancestorNames: ancestors.compactMap(ProcessTree.executableName),
        holderCwd: queued.record.cwd, candidates: resolvedCandidates)
      let original = session.flatMap { match in
        candidates.first { $0.id == match.id && $0.vendor == match.vendor }
      }
      return MonitoredEntry(
        id: queued.record.pid, slot: queued.slot, record: queued.record, session: original,
        isHolding: holding, waitsOnMemory: !holding && !state.freeSlots.isEmpty)
    }
    return Reading(
      holders: state.holders.map { entry($0, holding: true) },
      waiters: state.waiters.map { entry($0, holding: false) },
      pressure: MemoryPressure.current())
  }

  private nonisolated static func hasFiles(_ paths: BuildSlotPaths) -> Bool {
    [paths.slotsDir, paths.waitingDir].contains { dir in
      !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }
  }

  private nonisolated static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }
}
