import Foundation

/// Which ended sessions a project lists under "Recently ended".
///
/// **From the usage ledger, not from a scan of its own.** The indexer already keeps one row per
/// session with the folder it ran in and when it last wrote, so this is a filter over a value
/// already in memory. A project owns a session by the rule `ProjectStats` counts them by, the
/// deepest saved project containing its folder, so this list and the session count beside it
/// cannot disagree.
///
/// **Claude Code only.** Resume is what the list is for, and Codex resume is unmeasured.
nonisolated enum RecentSessions {
  static let limit = 8

  /// - Parameter live: ids Armada is watching now. They are in "Live sessions" above, and
  ///   resuming one would put two writers on its transcript.
  static func pick(
    from sessions: [UsageSessionRow], project id: String, candidates: [ProjectPath.Candidate],
    live: Set<String>, limit: Int = limit
  ) -> [UsageSessionRow] {
    var owners: [String: String?] = [:]
    func owner(of cwd: String) -> String? {
      if let known = owners[cwd] { return known }
      let found = ProjectPath.deepest(for: cwd, in: candidates)
      owners[cwd] = found
      return found
    }

    // The ledger's key is (account, vendor, id), so one id can have a row per account, and two
    // rows would be two Resume buttons on one conversation. Continuing on another account does
    // not normally make a second: the copy it stages is a pure mirror, and `UsageIndexer` makes
    // no session of a file that counted nothing. It could if the copy were read before the
    // original, since first-seen wins the messages. That order is unverified, hence the guard.
    var seen: Set<String> = []
    return
      sessions
      .filter { $0.vendor == .claude && !$0.isChild && !live.contains($0.sessionID) }
      .filter { owner(of: $0.cwd) == id }
      .sorted {
        if $0.lastAt != $1.lastAt { return $0.lastAt > $1.lastAt }
        if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
        return $0.account < $1.account
      }
      .filter { seen.insert($0.sessionID).inserted }
      .prefix(limit)
      .map { $0 }
  }
}
