import Foundation

/// Folders the way projects compare them: normalised, and matched on whole path
/// components.
///
/// **A raw string prefix is the bug this exists to prevent.** `/work/armada` is a
/// prefix of `/work/armada-old`, and a project that quietly counted a sibling
/// checkout's sessions would show figures nobody could reconcile. So containment is
/// "the same folder, or below it", decided at a `/`.
///
/// **Subfolders roll up, and the deepest project wins.** A session started in
/// `armada/apps/apple`, or in a worktree under `armada/.claude/worktrees/`, belongs to
/// the `armada` project; if `armada/apps/website` is saved as a project of its own, a
/// session in there is that one's and not both.
///
/// Pure, with no file-system access, so `make unit` can check it. Resolving symlinks is
/// the caller's job — `ProjectStore` adds a project's resolved path as a second key —
/// because it touches the disk and a matcher run over hundreds of folders should not.
nonisolated enum ProjectPath {
  /// One project as the matcher sees it: its id, and every spelling of its folder.
  struct Candidate: Hashable, Sendable {
    let id: String
    let keys: [String]
  }

  /// No trailing slash (except the root's own), and `.` / `..` resolved on the string.
  ///
  /// The trailing slash matters beyond tidiness: `ClaudeConfigFolder.path` documents
  /// what one did to `CLAUDE_CONFIG_DIR`, and a stored project path is handed to a
  /// terminal's `cd` and compared against every session's `cwd`.
  static func normalize(_ raw: String) -> String {
    var path = raw
    // Only paths that could hold a dot segment or a doubled slash pay for the URL.
    if path.contains("/.") || path.contains("//") {
      path = URL(filePath: path, directoryHint: .inferFromPath).standardized
        .path(percentEncoded: false)
    }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// Whether `path` is `root` or somewhere below it.
  static func contains(_ root: String, _ path: String) -> Bool {
    let root = normalize(root)
    let path = normalize(path)
    guard !root.isEmpty, !path.isEmpty else { return false }
    if root == "/" { return path.hasPrefix("/") }
    return path == root || path.hasPrefix(root + "/")
  }

  /// The project `cwd` belongs to: the candidate with the longest key containing it.
  ///
  /// Ties — two projects saved on the same folder, which `ProjectStore` refuses but a
  /// hand-edited file could hold — go to the smaller id, so the answer does not depend
  /// on the order the candidates arrive in.
  static func deepest(for cwd: String, in candidates: [Candidate]) -> String? {
    var best: (id: String, length: Int)?
    for candidate in candidates {
      for key in candidate.keys where contains(key, cwd) {
        let length = normalize(key).count
        if let current = best,
          length < current.length || (length == current.length && candidate.id >= current.id)
        {
          continue
        }
        best = (candidate.id, length)
      }
    }
    return best?.id
  }

  /// Whether a path is somewhere the system throws away.
  ///
  /// `/private/tmp` as well as `/tmp` because the two are the same directory reached
  /// two ways, and Claude Code records the resolved one; `/var/folders` is where
  /// `NSTemporaryDirectory` lives, and therefore where Armada's own scripts go.
  static func isTemporary(_ path: String) -> Bool {
    let temporary = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
    return temporary.contains { path.hasPrefix($0) }
  }
}
