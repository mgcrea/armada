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

  /// Whether a path that changed is *this* session's transcript.
  ///
  /// Exact-match on the file name rather than a prefix test, because subagent work
  /// lands under `projects/<enc-cwd>/<sessionId>/…` — a directory named for the
  /// session, holding files that are not its transcript. A prefix test would mark
  /// the parent session working every time a subagent wrote anything.
  static func isTranscript(path: String, sessionId: String) -> Bool {
    URL(filePath: path).lastPathComponent == "\(sessionId).jsonl"
  }
}
