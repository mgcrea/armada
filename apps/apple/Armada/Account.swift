import Foundation

/// One Claude config folder, and everything Armada knows about it.
///
/// The unit the app is organised around, because it is the unit the data is
/// organised around: sessions, transcripts and the usage cache all live inside a
/// config folder, and two folders share nothing. On this Mac that is one
/// Anthropic account in two organizations — a personal Max org and a Team org —
/// which is why the row says the organization rather than the email.
@MainActor
@Observable
final class Account: Identifiable {
  let folder: ClaudeConfigFolder

  private(set) var identity: AccountIdentity?
  private(set) var usage: UsageSnapshot?

  /// True once the usage file has been read at least once, so a pane can tell
  /// "not yet" from "nothing there".
  private(set) var didReadUsage = false

  /// This account's configured model, with its variant suffix — `"opus[1m]"` here.
  /// The default a session starts on, not what any session is necessarily using.
  private(set) var modelID: String?

  let sessions: SessionWatcher

  /// The folders this account has run in lately, for the New Session menu.
  ///
  /// Read from the same parse of `.claude.json` as the identity and the usage cache —
  /// the `projects` map is a third thing that document holds — so the menu costs no
  /// file read of its own. See `RecentProject.decode(root:)`.
  private(set) var recentProjects: [RecentProject] = []

  /// What a session in each of this account's projects loads before its first prompt.
  /// Filled lazily, only for the project whose session is being looked at.
  let compositions: ContextCompositions

  /// The folder path, without a trailing slash.
  ///
  /// This is persisted as the sidebar's remembered selection, so it has to be
  /// stable and predictable rather than merely unique. `URL.path` on a URL built
  /// with `directoryHint: .isDirectory` ends in `/`, which is an artefact of how
  /// the URL was constructed rather than anything about the folder — it would
  /// leak into the defaults key and silently reset the selection the day that
  /// construction changed.
  var id: String {
    let path = folder.base.standardizedFileURL.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  init(folder: ClaudeConfigFolder) {
    self.folder = folder
    sessions = SessionWatcher(folder: folder)
    compositions = ContextCompositions(folder: folder)
  }

  /// The organization's name, falling back to the folder's own.
  ///
  /// The fallback matters for a folder whose `.claude.json` has not been written
  /// yet — a config dir created by `CLAUDE_CONFIG_DIR` before the first sign-in
  /// has `sessions/` and nothing else — and it is why this never returns an empty
  /// string.
  var displayName: String {
    if let name = identity?.displayName, !name.isEmpty { return name }
    return folderName
  }

  /// `~/.claude` reads as "Default"; `~/.claude-skitrust` as "claude-skitrust".
  var folderName: String {
    let last = folder.base.lastPathComponent
    return last == ".claude" ? "Default" : String(last.dropFirst())
  }

  /// "Max 20x", "Team" — nil when the identity did not decode.
  var planLabel: String? { identity?.planLabel }

  /// The path as a person would read it, for the detail pane.
  var displayPath: String {
    (folder.base.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  var usagePath: String {
    (folder.usageJSON.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  /// The newest rate-limit refusal this folder's transcripts have recorded.
  ///
  /// A second usage source beside `usage`, and the only one that is not a cache.
  /// See `QuotaHit`, and `UsageSnapshot.window(_:correctedBy:now:)` for the narrow
  /// circumstances in which it is allowed to overrule the cached figure.
  var quotaHit: QuotaHit? { sessions.newestQuotaHit }

  func start() {
    sessions.start()
    refreshConfig()
  }

  /// Re-read the identity and the usage cache from one parse of `.claude.json`.
  ///
  /// Both live in the same 153KB document, and the identity is re-read rather
  /// than cached at launch because switching organization inside Claude Code
  /// rewrites it under a running Armada.
  ///
  /// **The cache is the fallback now, not the source.** `probeUsage` asks the
  /// account directly and is what the meters normally show; this keeps running
  /// because it is nearly free, it is the only source of the identity, and it is
  /// what answers on a Mac where `claude` cannot be found. A cached reading is
  /// therefore never allowed to overwrite a live one that is still current — see
  /// `adopt`.
  func refreshConfig() {
    didReadUsage = true
    // One field, and only because nothing else on disk records a model id with its
    // variant suffix — see `ClaudeConfigFolder.settingsJSON`. A missing or
    // unreadable file leaves this nil, which `ContextWindow` treats as "fall back",
    // not as an error.
    modelID = ClaudeConfigDocument.read(folder.settingsJSON)?["model"] as? String
    guard let root = ClaudeConfigDocument.read(folder.usageJSON) else { return }
    if let identity = AccountIdentity(root: root) { self.identity = identity }
    recentProjects = RecentProject.decode(root: root)
    // A nil decode leaves the last good snapshot in place rather than blanking
    // the pane: the common cause is catching the file mid-rewrite.
    if let usage = UsageSnapshot.decode(root: root) { adopt(usage) }
  }

  /// Ask this folder's account for its current windows, off the main actor.
  ///
  /// The expensive one — a `claude` process and about a second — so it is driven by
  /// `Accounts`' slow timer and by the popover opening, never by the 30-second file
  /// poll. A failure is silent and changes nothing: `UsageProbe` returns nil for
  /// everything from a missing binary to a timeout, and the cached reading stands.
  func probeUsage() async {
    let folder = self.folder
    guard
      let probed = await Task.detached(
        priority: .utility,
        operation: {
          UsageProbe.run(folder: folder)
        }
      ).value
    else { return }
    adopt(probed)
  }

  /// Take a new reading, unless it would be a step backwards.
  ///
  /// **A cached reading may not displace a live one that is still fresher.** Both
  /// arrive on their own schedules — the file poll every 30s, the probe every few
  /// minutes — so without this the meters would flip between the two on every tick,
  /// and a cache that is hours stale would win simply by arriving last. Same
  /// `staleFraction` the forecast uses for the same reason, rather than a second
  /// idea of how old is too old.
  private func adopt(_ new: UsageSnapshot) {
    if let current = usage, current.source == .live, new.source == .cache,
      let live = current.fetchedAt, let cached = new.fetchedAt, live > cached
    {
      return
    }
    usage = new
    // Recorded here rather than at either call site, because this is the one place
    // a new snapshot is accepted; the store itself drops anything it has seen.
    UsageHistory.shared.record(new, for: id)
  }
}
