import Foundation

/// The short name a waiting shim gives each holder: `valise/land-gate-f764fa9` for a worktree,
/// `maquette` for a checkout, the folder's own name outside any repository.
public enum HolderLabel {
  /// Whether `dir` holds a `.git`, a directory in a checkout or a file in a worktree.
  public static func defaultHasGit(_ dir: String) -> Bool {
    FileManager.default.fileExists(atPath: dir + "/.git")
  }

  public static func label(cwd: String, hasGit: (String) -> Bool = HolderLabel.defaultHasGit)
    -> String
  {
    let path = resolved(cwd)
    let components = path.split(separator: "/").map(String.init)
    // The innermost `<repo>/.claude/worktrees/<name>`, for a worktree made inside another.
    if components.count >= 4 {
      for index in stride(from: components.count - 3, through: 1, by: -1)
      where components[index] == ".claude" && components[index + 1] == "worktrees" {
        return components[index - 1] + "/" + components[index + 2]
      }
    }
    if let root = workingTreeRoot(of: path, hasGit: hasGit) { return basename(root) }
    return basename(path)
  }

  /// The nearest directory at or above `path` holding a `.git`. A worktree has its own `.git`
  /// file, so it is its own working tree and not part of its main checkout's.
  public static func workingTreeRoot(
    of path: String, hasGit: (String) -> Bool = HolderLabel.defaultHasGit
  ) -> String? {
    var dir = resolved(path)
    while true {
      if hasGit(dir) { return dir }
      if dir == "/" { return nil }
      let parent = (dir as NSString).deletingLastPathComponent
      dir = parent.isEmpty ? "/" : parent
    }
  }

  /// `path` with symlinks resolved (`/tmp` is `/private/tmp`), so two spellings of one folder
  /// compare equal. A path that does not exist is kept as given, standardised.
  private static func resolved(_ path: String) -> String {
    if let real = realpath(path, nil) {
      defer { free(real) }
      return String(cString: real)
    }
    return (path as NSString).standardizingPath
  }

  private static func basename(_ path: String) -> String {
    path == "/" ? "/" : (path as NSString).lastPathComponent
  }
}
