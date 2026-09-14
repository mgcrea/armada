import CoreServices
import Foundation

private nonisolated func configEventCallback(
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
  let accounts = Unmanaged<Accounts>.fromOpaque(info).takeUnretainedValue()
  Task { @MainActor in accounts.handle(paths: cfPaths) }
}

/// Every Claude config folder on this Mac, watched at once.
///
/// One timer and one FSEvents stream for all of them rather than a pair each: the
/// `.claude.json` files are a handful of documents on an unpredictable cadence,
/// so there is nothing to gain from separate clocks and one less thing to leak.
/// Session watching is the opposite and stays per account — each folder has its
/// own `sessions/` and `projects/` trees, and routing one merged stream back to
/// the right folder would be work for nothing.
@MainActor
@Observable
final class Accounts {
  static let shared = Accounts()

  /// `.claude.json` is one document rewritten whenever an API response updates
  /// the cache, so there is no event that means "usage changed". The poll is the
  /// floor; the watch below only shortens the wait when a write does land.
  static let refreshInterval: TimeInterval = 30

  /// How often to ask the accounts directly. See `UsageProbe`.
  ///
  /// **Two orders of magnitude slower than the file poll, deliberately.** Each probe
  /// is a `claude` process and about a second, per config folder; at the poll's
  /// cadence that would be a process every 30 seconds forever to redraw two meters.
  /// Three minutes is inside the five-hour window's own resolution — a percentage
  /// point of it is three minutes — so nothing observable is lost, and the popover
  /// opening probes anyway, which covers the moment somebody actually looks.
  static let probeInterval: TimeInterval = 3 * 60

  /// Floor between probes of the same account, so that opening and closing the
  /// popover repeatedly does not spawn a process each time.
  static let probeThrottle: TimeInterval = 20

  private(set) var all: [Account] = []

  private var stream: FSEventStreamRef?
  private var timer: DispatchSourceTimer?
  private var probeTimer: DispatchSourceTimer?
  private var lastProbe: [String: Date] = [:]
  /// The probe last started for each account, held so `stop()` can cancel one that
  /// has not reached its `claude` yet.
  private var probes: [String: Task<Void, Never>] = [:]
  private let queue = DispatchQueue(label: "io.mgcrea.armada.config")

  /// Every live session across every account, newest first — what the menu bar
  /// summarises and what decides whether the status item is filled.
  var allSessions: [Session] {
    all.flatMap(\.sessions.sessions)
      .sorted { ($0.registry.startedAt ?? 0, $0.id) > ($1.registry.startedAt ?? 0, $1.id) }
  }

  var workingSessionCount: Int {
    all.reduce(0) { $0 + $1.sessions.sessions.count { $0.state != .idle } }
  }

  /// Strictly `.working`, where `workingSessionCount` above is "not idle" and so
  /// also counts `.runningTool`. The menu bar halo needs the two apart: its first
  /// rung is the one that rests on nothing inferred, and a session sitting on an
  /// unanswered `tool_use` is inferred. See `MenuBarHalo`.
  var writingSessionCount: Int {
    all.reduce(0) { $0 + $1.sessions.sessions.count { $0.state == .working } }
  }

  /// Sessions that look like they want you: `.waiting`, plus `.runningTool`.
  ///
  /// **The two rest on completely different evidence and are counted together on
  /// purpose.** `.waiting` is reported — Claude Code says the session is stopped and
  /// names what it wants in `waitingFor`. `.runningTool` is the old inference, an
  /// unanswered `tool_use` that is a long-running tool as often as a prompt nobody has
  /// answered. The halo asks one question, "is anything asking for me", and a rung
  /// that lit for the guess but not for the certainty would be indefensible.
  var blockedSessionCount: Int {
    all.reduce(0) {
      $0 + $1.sessions.sessions.count(where: \.wantsAttention)
    }
  }

  var totalSessionCount: Int {
    all.reduce(0) { $0 + $1.sessions.sessions.count }
  }

  func account(id: String) -> Account? {
    all.first { $0.id == id }
  }

  /// Whether the recorded history has been read this process. Once is enough: a
  /// second read after the entitlement monitor restarts the watchers would load
  /// the file over readings recorded since.
  private var didLoadHistory = false

  func start() {
    // Guarded on the clock rather than on `all`: `EntitlementMonitor` calls this on
    // every key entered and every trial started, and on a Mac with no Claude folder
    // `all` stays empty after discovery, so an `all.isEmpty` guard would stack a new
    // pair of timers each time.
    guard timer == nil else { return }
    // Before the accounts, so the first `refreshConfig` below appends to the
    // recorded history rather than starting a fresh one every launch.
    if !didLoadHistory {
      UsageHistory.shared.load()
      didLoadHistory = true
    }
    all = ClaudeConfigFolder.discoverAll().map(Account.init(folder:))
    for account in all { account.start() }

    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now() + Self.refreshInterval, repeating: Self.refreshInterval)
    tick.setEventHandler { MainActor.assumeIsolated { self.refreshAll() } }
    tick.resume()
    timer = tick

    // Straight away as well as on the interval: the cache read above may be hours
    // old, and the first thing anyone does after launching is open the panel.
    probeAll()
    let probe = DispatchSource.makeTimerSource(queue: .main)
    probe.schedule(deadline: .now() + Self.probeInterval, repeating: Self.probeInterval)
    probe.setEventHandler { MainActor.assumeIsolated { self.probeAll() } }
    probe.resume()
    probeTimer = probe

    startWatchingConfigFiles()
  }

  /// Stop everything `start()` started, and forget the accounts.
  ///
  /// Called by `EntitlementMonitor` when the entitlement is refused — a trial
  /// window closing, or a key removed — so an unlicensed Armada is not quietly
  /// polling folders and spawning `claude` probes behind a locked panel. That includes
  /// a probe already started: its task is cancelled here, and `ClaudeControl` checks
  /// for that immediately before it spawns anything.
  ///
  /// Streams before objects. Every FSEvents context here holds its watcher
  /// UNRETAINED, so each stream is stopped and invalidated before the list that
  /// keeps the watchers alive is emptied; a callback arriving after that would
  /// otherwise reach a freed object.
  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    timer?.cancel()
    timer = nil
    probeTimer?.cancel()
    probeTimer = nil
    for probe in probes.values { probe.cancel() }
    probes = [:]
    for account in all { account.sessions.stop() }
    all = []
    lastProbe = [:]
  }

  /// Re-read every folder's `.claude.json` now.
  ///
  /// Internal rather than private because the menu bar popover calls it when it
  /// opens: someone who clicks to check their limits should not be shown the tail
  /// end of a 30-second poll. Cheap by construction — the document is one the page
  /// cache already holds, and a decode that fails leaves the last good snapshot.
  func refreshAll() {
    for account in all { account.refreshConfig() }
  }

  /// Ask every account for its current windows, throttled per account.
  ///
  /// Each folder gets its own task rather than a serial loop: the cost is almost all
  /// process start-up, so two accounts probed together take about as long as one.
  func probeAll() {
    let now = Date()
    for account in all
    where now.timeIntervalSince(lastProbe[account.id] ?? .distantPast) >= Self.probeThrottle {
      lastProbe[account.id] = now
      probes[account.id] = Task { await account.probeUsage() }
    }
  }

  /// Watch each usage file's own path, not the directory it sits in.
  ///
  /// **The directory was `$HOME`.** The default folder's `.claude.json` sits beside
  /// `~/.claude` rather than inside it, and FSEvents watches a directory recursively,
  /// so this stream used to receive an event for every file touched anywhere under the
  /// home folder, only for `handle` to throw nearly all of them away.
  ///
  /// The directory was chosen for fear that an atomic rewrite, which replaces the
  /// inode, would leave a watch on the file following the one thrown away. FSEvents is
  /// path based and does not. Measured on 2026-09-14 with a throwaway stream on a file
  /// path: a temp file renamed over it, Foundation's `atomically: true` write, an
  /// in-place append, a delete and recreate, and the file first appearing after the
  /// stream started were all reported, and a write to a sibling in the same directory
  /// was not.
  private func startWatchingConfigFiles() {
    let files = Set(all.map { $0.folder.usageJSON.path(percentEncoded: false) })
    guard !files.isEmpty, stream == nil else { return }

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
    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault, configEventCallback, &context, Array(files) as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
    else { return }
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created
  }

  /// Matched on the exact usage paths. Every folder's file arrives on this one
  /// stream, and an event should re-parse the 153KB document it names, not all of
  /// them.
  fileprivate func handle(paths: [String]) {
    for account in all
    where paths.contains(account.folder.usageJSON.path(percentEncoded: false)) {
      account.refreshConfig()
    }
  }
}
