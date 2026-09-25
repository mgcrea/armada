import AppKit
import Foundation
import Observation
import os

/// When the archive is copied, and what the panes say about it.
///
/// **Off until the person turns it on for an account**, and then only into the folder they
/// picked. `TranscriptArchive` has the rules for what is copied; this decides when.
///
/// **Behind the entitlement gate**, like the usage index, because it reads the same folders.
///
/// **When.** A pass runs a minute and a half after launch, behind the index's first read; then
/// every thirty minutes, ten minutes after a watcher reports a write, as soon as a volume is
/// mounted, and whenever the settings change. Low Power Mode and a hot Mac put it off.
///
/// **A folder that is not there is waited for, never made.** A NAS share that is not mounted
/// leaves `/Volumes/<share>` missing, or worse, an empty folder on the startup disk. The pass
/// checks that the picked folder exists and is still on the volume it was picked on, and
/// otherwise reports the folder unavailable and tries again later.
@MainActor
@Observable
final class TranscriptArchiver {
  static let shared = TranscriptArchiver()

  static let targetKey = "ArchiveTarget"
  static let volumeKey = "ArchiveVolume"
  static let accountsKey = "ArchiveAccounts"
  static let retentionKey = "ArchiveRetentionDays"

  /// Keep forever, then the periods the picker offers.
  static let retentionChoices = [0, 30, 90, 180, 365, 730]

  enum Status: Equatable {
    case idle
    case copying
    /// The folder is not mounted or no longer exists.
    case unavailable
    case failed(String)
  }

  private(set) var target: URL?
  private(set) var enabled: Set<String>
  private(set) var retentionDays: Int
  private(set) var status: Status = .idle
  private(set) var lastReport: TranscriptArchive.Report?
  private(set) var lastSuccessAt: Date?
  /// Files done and total during a pass.
  private(set) var progress: (done: Int, total: Int)?

  @ObservationIgnored private let worker = ArchiveWorker()
  @ObservationIgnored private var loop: Task<Void, Never>?
  /// The copy running now, so a change of folder or retention can stop it.
  @ObservationIgnored private var work: Task<Result<TranscriptArchive.Report, Error>, Never>?
  /// Bumped whenever a running pass's result stops meaning anything: a pass that finds it
  /// changed under it reports nothing.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var activity = false
  @ObservationIgnored private var wake = false
  @ObservationIgnored private var mountObserver: NSObjectProtocol?

  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "archive")

  private init() {
    let defaults = UserDefaults.standard
    target = defaults.string(forKey: Self.targetKey).map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    enabled = Set(defaults.stringArray(forKey: Self.accountsKey) ?? [])
    retentionDays = defaults.integer(forKey: Self.retentionKey)
  }

  var isOn: Bool { target != nil && !enabled.isEmpty }

  func isEnabled(_ account: String) -> Bool { enabled.contains(account) }

  /// The archive's own folder, inside the picked one.
  var root: URL? { target.map(TranscriptArchive.root(forPicked:)) }

  var displayRoot: String? {
    root.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath }
  }

  // MARK: - Settings

  func setEnabled(_ on: Bool, account: String) {
    if on, target == nil, !chooseFolder() { return }
    if on { enabled.insert(account) } else { enabled.remove(account) }
    UserDefaults.standard.set(enabled.sorted(), forKey: Self.accountsKey)
    requestPass()
  }

  /// Ask for the folder. False when the person cancelled.
  @discardableResult
  func chooseFolder() -> Bool {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = target ?? URL(filePath: "/Volumes", directoryHint: .isDirectory)
    panel.prompt = "Choose"
    panel.message =
      "Choose where Armada keeps copies of your transcripts, such as a folder on a NAS or an external disk. Armada makes an “\(TranscriptArchive.folderName)” folder inside it."
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    target = url
    UserDefaults.standard.set(url.path(percentEncoded: false), forKey: Self.targetKey)
    UserDefaults.standard.set(Self.volume(of: url), forKey: Self.volumeKey)
    abandonPass()
    lastReport = nil
    lastSuccessAt = nil
    status = .idle
    Task { await worker.forget() }
    requestPass()
    return true
  }

  /// Stop archiving altogether. The copies already made stay where they are.
  func forgetFolder() {
    target = nil
    enabled = []
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: Self.targetKey)
    defaults.removeObject(forKey: Self.volumeKey)
    defaults.removeObject(forKey: Self.accountsKey)
    abandonPass()
    lastReport = nil
    lastSuccessAt = nil
    status = .idle
    Task { await worker.forget() }
  }

  func setRetention(_ days: Int) {
    retentionDays = days
    UserDefaults.standard.set(days, forKey: Self.retentionKey)
    // A pass under the old period would prune copies the new one keeps.
    abandonPass()
    if status == .copying { status = .idle }
    // What was skipped as too old under the last period may be kept under this one.
    Task { await worker.forget() }
    requestPass()
  }

  func showInFinder() {
    guard let root else { return }
    let path = root.path(percentEncoded: false)
    if FileManager.default.fileExists(atPath: path) {
      NSWorkspace.shared.activateFileViewerSelecting([root])
    } else if let target, FileManager.default.fileExists(atPath: target.path(percentEncoded: false))
    {
      NSWorkspace.shared.activateFileViewerSelecting([target])
    }
  }

  // MARK: - The loop

  func start() {
    guard loop == nil else { return }
    mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in TranscriptArchiver.shared.requestPass() }
    }
    loop = Task { await run() }
  }

  func stop() {
    loop?.cancel()
    loop = nil
    abandonPass()
    if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
    mountObserver = nil
    progress = nil
    if status == .copying { status = .idle }
  }

  /// A watcher saw a transcript or rollout written.
  func noteActivity() { activity = true }

  /// Run a pass at the next check, rather than waiting out the interval.
  func requestPass() { wake = true }

  /// Stop the running pass, if any, and make sure nothing it reports lands.
  private func abandonPass() {
    generation += 1
    work?.cancel()
    work = nil
    progress = nil
  }

  private func run() async {
    try? await Task.sleep(for: .seconds(90))
    while !Task.isCancelled {
      // Cleared before the pass, not after it, so a request made while it copies still
      // brings the next one forward.
      activity = false
      wake = false
      if isOn, !Self.shouldDefer { await pass() }
      await idle()
    }
  }

  private func idle() async {
    let started = Date()
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(15))
      let waited = Date().timeIntervalSince(started)
      if wake || waited >= 30 * 60 || (activity && waited >= 10 * 60) { return }
    }
  }

  private func pass() async {
    guard let target, let root else { return }
    guard Self.isAvailable(target) else {
      status = .unavailable
      return
    }
    let sources = sources()
    guard !sources.isEmpty else { return }
    status = .copying
    let cutoff = TranscriptArchive.cutoff(days: retentionDays, now: Date())
    let worker = self.worker
    let mine = generation
    let work = Task.detached(priority: .background) {
      await worker.run(
        sources: sources, root: root, cutoff: cutoff,
        progress: { done, total in
          Task { @MainActor in
            TranscriptArchiver.shared.receive(done: done, total: total, generation: mine)
          }
        })
    }
    self.work = work
    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    // The folder or the period changed while it ran: whoever changed it has already reset
    // what the panes show.
    guard generation == mine else { return }
    self.work = nil
    progress = nil
    switch result {
    case .success(let report):
      lastReport = report
      if report.failures == 0 {
        lastSuccessAt = Date()
        status = .idle
      } else {
        status = .failed(report.firstFailure ?? "Some files could not be copied.")
      }
      Self.logger.info(
        "archive pass: \(report.filesCopied) new, \(report.filesAppended) grown, \(report.filesPruned) pruned, \(report.failures) failed"
      )
    case .failure(let error):
      status = Task.isCancelled ? .idle : .failed(error.localizedDescription)
    }
  }

  private func receive(done: Int, total: Int, generation: Int) {
    guard generation == self.generation, status == .copying else { return }
    progress = (done, total)
  }

  /// Every account switched on, as the worker needs it.
  private func sources() -> [TranscriptArchive.Source] {
    Accounts.shared.all.filter { enabled.contains($0.id) }.map {
      TranscriptArchive.Source(
        account: $0.id, vendor: .claude, base: $0.folder.base, label: $0.displayName)
    }
      + CodexAccounts.shared.all.filter { enabled.contains($0.id) }.map {
        TranscriptArchive.Source(
          account: $0.id, vendor: .codex, base: $0.home.base, label: $0.displayName)
      }
  }

  // MARK: - The destination

  /// The folder exists, and sits on the volume it was picked on: a share that is not mounted
  /// can leave an empty mount point on the startup disk, and copying there fills the Mac.
  private static func isAvailable(_ target: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: target.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    guard let picked = UserDefaults.standard.string(forKey: volumeKey) else { return true }
    return volume(of: target) == picked
  }

  private static func volume(of url: URL) -> String? {
    (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path(percentEncoded: false)
  }

  private static var shouldDefer: Bool {
    let info = ProcessInfo.processInfo
    return info.isLowPowerModeEnabled || info.thermalState == .serious
      || info.thermalState == .critical
  }
}

/// The pass itself, off the main actor.
///
/// **Remembers what it already found in sync**, by source path, size and date, so a pass after
/// the first stats the sources on this Mac and touches the archive only for what changed. Over
/// SMB every stat is a round trip, and a few thousand of them each pass would be the whole cost.
/// Forgotten when the folder changes, so a new destination is checked file by file, and not
/// trusted for an archive that has lost its manifest or an account's folder, which is what a
/// folder deleted by hand or a different disk under the same name looks like.
actor ArchiveWorker {
  private struct Seen: Equatable {
    let size: Int64
    let mtime: Double
  }

  private var seen: [String: Seen] = [:]

  func forget() { seen = [:] }

  func run(
    sources: [TranscriptArchive.Source], root: URL, cutoff: Double?,
    progress: @Sendable (Int, Int) -> Void
  ) -> Result<TranscriptArchive.Report, Error> {
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let existing = TranscriptArchive.readManifest(at: root)
      if existing == nil { seen = [:] }
      var manifest = existing ?? TranscriptArchive.Manifest()
      let assigned = TranscriptArchive.assign(sources, in: manifest)
      if assigned != manifest {
        try TranscriptArchive.writeManifest(assigned, at: root)
        manifest = assigned
      }

      var report = TranscriptArchive.Report()
      let work = sources.map { source in
        (source: source, items: TranscriptArchive.enumerate(source))
      }
      let total = work.reduce(0) { $0 + $1.items.count }
      var done = 0
      for (source, items) in work {
        guard let entry = manifest.accounts[source.account] else { continue }
        let folder = root.appending(path: entry.folder, directoryHint: .isDirectory)
        let trusted = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
        for item in items {
          try Task.checkCancellation()
          report.filesSeen += 1
          done += 1
          if done % 200 == 0 { progress(done, total) }
          let key = item.url.path(percentEncoded: false)
          let now = Seen(size: item.size, mtime: item.mtime)
          if trusted, seen[key] == now { continue }
          do {
            let outcome = try TranscriptArchive.sync(item, into: folder, cutoff: cutoff)
            report.record(outcome)
            seen[key] = now
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            report.fail(item.relativePath, error)
          }
        }
      }
      if let cutoff {
        try Task.checkCancellation()
        report.filesPruned = TranscriptArchive.prune(root: root, manifest: manifest, cutoff: cutoff)
      }
      return .success(report)
    } catch {
      return .failure(error)
    }
  }
}
