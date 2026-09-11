import CoreServices
import Foundation

private nonisolated func usageEventCallback(
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
  let tracker = Unmanaged<UsageTracker>.fromOpaque(info).takeUnretainedValue()
  Task { @MainActor in tracker.handle(paths: cfPaths) }
}

/// Current usage against the 5-hour and 7-day plan limits.
///
/// Timer-first, unlike `SessionWatcher`. `~/.claude.json` is one 153KB document
/// rewritten whenever an API response updates the cache, so there is no directory
/// of small files to watch and no event that means "a window changed" rather than
/// "some unrelated key did". A 30s poll is the floor; the FSEvents watch on the
/// containing directory only shortens the wait when a write does land.
@MainActor
@Observable
final class UsageTracker {
  static let shared = UsageTracker()

  static let refreshInterval: TimeInterval = 30

  private(set) var snapshot: UsageSnapshot?

  /// True once a read has been attempted, so the pane can tell "nothing yet" from
  /// "nothing there".
  private(set) var didRead = false

  let folder: ClaudeConfigFolder

  private var stream: FSEventStreamRef?
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "io.mgcrea.armada.usage")

  init(folder: ClaudeConfigFolder = .default) {
    self.folder = folder
  }

  var fiveHour: UsageWindow? { snapshot?.fiveHour }
  var sevenDay: UsageWindow? { snapshot?.sevenDay }

  func start() {
    guard timer == nil else { return }
    refresh()

    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now() + Self.refreshInterval, repeating: Self.refreshInterval)
    tick.setEventHandler { MainActor.assumeIsolated { self.refresh() } }
    tick.resume()
    timer = tick

    // The file's own directory, because an atomic rewrite replaces the inode and a
    // watch on the file itself would follow the one that was thrown away.
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
    let directory = folder.usageJSON.deletingLastPathComponent().path(percentEncoded: false)
    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault, usageEventCallback, &context, [directory] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
    else { return }
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created
  }

  fileprivate func handle(paths: [String]) {
    let target = folder.usageJSON.path(percentEncoded: false)
    guard paths.contains(where: { $0 == target }) else { return }
    refresh()
  }

  func refresh() {
    didRead = true
    // A nil read leaves the last good snapshot in place rather than blanking the
    // pane: the common cause is catching the file mid-rewrite, and the next tick
    // is a second away.
    if let fresh = UsageSnapshot.read(from: folder.usageJSON) {
      snapshot = fresh
    }
  }
}
