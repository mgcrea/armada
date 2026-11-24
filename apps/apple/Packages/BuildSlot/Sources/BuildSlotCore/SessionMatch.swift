/// A live agent session a holder or waiter might belong to, as the app's account stores see it.
public struct MatchCandidate: Sendable, Equatable {
  public var id: String
  /// `claude`, `codex` or `grok`.
  public var vendor: String
  /// The session's process. Claude Code's registry and Grok Build record one; Codex does not.
  public var pid: Int32?
  public var cwd: String
  public var title: String

  public init(id: String, vendor: String, pid: Int32?, cwd: String, title: String) {
    self.id = id
    self.vendor = vendor
    self.pid = pid
    self.cwd = cwd
    self.title = title
  }
}

/// Which session a build in the queue was started by. Pure, so the rules are tested without a
/// process table: the caller passes the holder's ancestors and their executable names.
public enum SessionMatch {
  /// The nearest ancestor that is a candidate's pid names the session. Failing that, and only
  /// when an ancestor runs `codex`, the Codex session whose cwd is the holder's or a folder above
  /// it, deepest first; two sessions at that depth are a guess, so neither is named.
  public static func match(
    ancestors: [Int32], ancestorNames: [String], holderCwd: String,
    candidates: [MatchCandidate]
  ) -> MatchCandidate? {
    for pid in ancestors {
      if let found = candidates.first(where: { $0.pid == pid }) { return found }
    }
    guard ancestorNames.contains("codex") else { return nil }
    let holder = components(holderCwd)
    let containing = candidates.compactMap { candidate -> (MatchCandidate, Int)? in
      guard candidate.vendor == "codex" else { return nil }
      let own = components(candidate.cwd)
      guard !own.isEmpty, holder.starts(with: own) else { return nil }
      return (candidate, own.count)
    }
    guard let depth = containing.map(\.1).max() else { return nil }
    let deepest = containing.filter { $0.1 == depth }
    return deepest.count == 1 ? deepest[0].0 : nil
  }

  /// Whole path components, so `/r/app` is not above `/r/apple`.
  private static func components(_ path: String) -> [Substring] {
    path.split(separator: "/")
  }
}
