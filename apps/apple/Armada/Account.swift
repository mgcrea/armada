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

  let sessions: SessionWatcher

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
  func refreshConfig() {
    didReadUsage = true
    guard let root = ClaudeConfigDocument.read(folder.usageJSON) else { return }
    if let identity = AccountIdentity(root: root) { self.identity = identity }
    // A nil decode leaves the last good snapshot in place rather than blanking
    // the pane: the common cause is catching the file mid-rewrite.
    if let usage = UsageSnapshot.decode(root: root) {
      self.usage = usage
      // Recorded here rather than in the poll, because this is the one place a new
      // snapshot exists; the store itself drops anything it has already seen.
      UsageHistory.shared.record(usage, for: id)
    }
  }
}
