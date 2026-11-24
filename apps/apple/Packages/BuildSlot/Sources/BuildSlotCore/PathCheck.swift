import Darwin

/// Whether a `PATH` reaches the shims before the real tool. Settings warns when the login shell's
/// does not, since every agent and terminal started from it would then skip the queue.
public enum PathCheck {
  /// True when `binDir` is on `path` and no entry naming one of `realToolDirs` comes first.
  /// Entries compare after resolving links, so `~/.local/bin` reached through a symlinked home
  /// still counts; empty entries are skipped, as the shell skips them for a command lookup.
  public static func shimsComeFirst(
    path: String, binDir: String, realToolDirs: [String] = ["/usr/bin"]
  ) -> Bool {
    let shims = normalized(binDir)
    let real = Set(realToolDirs.map(normalized))
    for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
      let directory = normalized(String(entry))
      if directory == shims { return true }
      if real.contains(directory) { return false }
    }
    return false
  }

  /// The resolved path, or for a folder that does not exist, the spelling without trailing
  /// slashes.
  private static func normalized(_ path: String) -> String {
    if let real = realpath(path, nil) {
      defer { free(real) }
      return String(cString: real)
    }
    var trimmed = Substring(path)
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
  }
}
