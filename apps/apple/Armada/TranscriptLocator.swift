import Foundation

/// Finding a session's transcript on disk.
///
/// `~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`, where the encoding is
/// internal and undocumented. `/Users/olivier/Projects/apps/bastion` becomes
/// `-Users-olivier-Projects-apps-bastion`, but the transform is lossy and not
/// reversible — live directories look like
/// `-private-tmp-claude-501--Users-olivier-…`, where the original path's own
/// hyphens are indistinguishable from separators.
///
/// So this guesses, then falls back to looking. The guesses are cheap
/// (`fileExists` on a constructed path) and the fallback is one directory listing
/// of ~109 entries, done only when both guesses miss.
enum TranscriptLocator {
  /// The transcript for a session, or nil.
  ///
  /// **Nil is a normal answer, not an error**: a session that has never been
  /// prompted has no transcript file at all.
  static func find(sessionId: String, cwd: String, in projectsDir: URL) -> URL? {
    let fileManager = FileManager.default
    let leaf = "\(sessionId).jsonl"

    for encoded in candidates(for: cwd) {
      let url =
        projectsDir
        .appending(path: encoded, directoryHint: .isDirectory)
        .appending(path: leaf, directoryHint: .notDirectory)
      if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
    }

    // The encoding is internal, so when the guesses miss, look. Sorted for a
    // stable answer if two directories somehow hold the same session id.
    let directories =
      (try? fileManager.contentsOfDirectory(atPath: projectsDir.path(percentEncoded: false))) ?? []
    for directory in directories.sorted() {
      let url =
        projectsDir
        .appending(path: directory, directoryHint: .isDirectory)
        .appending(path: leaf, directoryHint: .notDirectory)
      if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
    }
    return nil
  }

  /// The two encodings seen in the wild, in the order they are worth trying.
  static func candidates(for cwd: String) -> [String] {
    let slashes = cwd.replacingOccurrences(of: "/", with: "-")
    let alphanumeric = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return slashes == alphanumeric ? [slashes] : [slashes, alphanumeric]
  }

  /// The session id a changed path would be the transcript of, or nil when its file
  /// name is not `<something>.jsonl`.
  ///
  /// The file name alone rather than a prefix test, because subagent work lands under
  /// `projects/<enc-cwd>/<sessionId>/…` — a directory named for the session, holding
  /// files that are not its transcript. A prefix test would mark the parent session
  /// working every time a subagent wrote anything. The caller looks the id up among
  /// its live sessions, so a file whose own name is no live session's id matches
  /// nothing.
  ///
  /// A string slice rather than a `URL` per path: this runs on every path of every
  /// FSEvents batch.
  static func sessionID(ofTranscriptPath path: String) -> String? {
    let name = path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
    guard name.hasSuffix(".jsonl"), name.count > ".jsonl".count else { return nil }
    return String(name.dropLast(".jsonl".count))
  }
}
