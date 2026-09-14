import Foundation

/// A folder an account has run a session in, for the New Session menu to offer.
///
/// **Per account, because the two vendors record it in different places and neither
/// is a list of projects.** Claude Code keeps a `projects` map inside the same
/// `.claude.json` the identity and the usage cache come from — 116 entries here on
/// 2026-09-13, keyed by absolute path, each with a `lastStartTime` — so a Claude
/// account's recents cost nothing beyond the parse `Account.refreshConfig` already
/// does. Codex keeps no such map: its rollouts carry a `cwd` each, so the recents are
/// derived from the sessions `CodexWatcher` has already read, which is a shorter and
/// more recent list by construction (the watcher keeps the last 12 hours).
///
/// The asymmetry is left in place rather than evened out. Reading every rollout on
/// disk to lengthen the Codex list would be minutes of I/O for a menu.
nonisolated struct RecentProject: Identifiable, Hashable, Sendable {
  let path: String

  /// When a session last started here. Nil for an entry Claude Code wrote before it
  /// recorded that, which sorts last rather than being dropped.
  let lastStartedAt: Date?

  var id: String { path }

  var url: URL { URL(filePath: path, directoryHint: .isDirectory) }

  /// The folder, as a person names it.
  var name: String {
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
  }

  var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

  /// How many the overview offers. Long enough to reach yesterday's work, short enough
  /// that the section stays a shortcut rather than a folder picker with extra steps —
  /// and short enough to leave the account's own summary above the fold beneath it.
  static let limit = 6

  /// Claude Code's `projects` map, newest first.
  ///
  /// **Sorted before anything is checked on disk.** The map is every folder the
  /// account has ever run in, and stat-ing all 116 of them on the main actor every
  /// thirty seconds — `Account.refreshConfig`'s cadence — to build a menu of ten would
  /// be the most expensive thing in the app's idle loop. Sorting first means the walk
  /// stops as soon as ten live folders are found.
  ///
  /// **Scratchpads are dropped.** Four of the five newest entries here were
  /// `/private/tmp/claude-501/…/scratchpad` directories — the per-session working
  /// space agents are handed, which exist, are genuinely the newest thing on the list,
  /// and are the last place anybody wants to start a session. Matching on the
  /// temporary directories rather than on the word "scratchpad": it is the location
  /// that makes them throwaway, and the naming convention is not Armada's to rely on.
  static func decode(root: [String: Any]) -> [RecentProject] {
    guard let projects = root["projects"] as? [String: Any] else { return [] }
    let candidates =
      projects
      .compactMap { path, value -> RecentProject? in
        guard !isTemporary(path) else { return nil }
        // Epoch milliseconds, like `SessionRegistry.startedAt`.
        let started = (value as? [String: Any])?["lastStartTime"] as? Double
        return RecentProject(
          path: path,
          lastStartedAt: started.map { Date(timeIntervalSince1970: $0 / 1000) })
      }
      .sorted { ($0.lastStartedAt ?? .distantPast) > ($1.lastStartedAt ?? .distantPast) }

    return existing(candidates)
  }

  /// The folders Codex has run in lately, newest first, one row per folder.
  ///
  /// Deduplicated on the path: a home with six sessions in one repo should offer that
  /// repo once. Sessions arrive from `CodexWatcher` already parsed, so this is a walk
  /// over a handful of structs and is safe to recompute whenever the menu is drawn.
  ///
  /// Main-actor isolated where the rest of this type is not, because `CodexSession` is
  /// the watcher's live main-actor object and this reads it.
  @MainActor
  static func recent(in sessions: [CodexSession]) -> [RecentProject] {
    var seen: Set<String> = []
    let candidates =
      sessions
      .sorted { ($0.lastEventAt ?? .distantPast) > ($1.lastEventAt ?? .distantPast) }
      .compactMap { session -> RecentProject? in
        let path = session.meta.cwd
        guard !path.isEmpty, !isTemporary(path), seen.insert(path).inserted else { return nil }
        return RecentProject(path: path, lastStartedAt: session.lastEventAt)
      }

    return existing(candidates)
  }

  /// The first `limit` candidates that are still directories on disk.
  private static func existing(_ candidates: [RecentProject]) -> [RecentProject] {
    let fileManager = FileManager.default
    var found: [RecentProject] = []
    for candidate in candidates {
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { continue }
      found.append(candidate)
      if found.count == limit { break }
    }
    return found
  }

  /// Whether a path is somewhere the system throws away.
  ///
  /// `/private/tmp` as well as `/tmp` because the two are the same directory reached
  /// two ways, and Claude Code records the resolved one; `/var/folders` is where
  /// `NSTemporaryDirectory` lives, and therefore where Armada's own scripts go.
  private static func isTemporary(_ path: String) -> Bool {
    let temporary = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
    return temporary.contains { path.hasPrefix($0) }
  }
}
