import Foundation

/// Whether a shim is part of a build that already holds a slot, so it must not queue behind its
/// own parent. The caller walks the process tree, resolves symlinks in the paths and looks for
/// `.git` on disk; this decides from what it found.
public enum Nesting {
  public static let holderVariable = "ARMADA_BUILDSLOT_HOLDER"

  /// Ancestry: the holder's pid from the environment must be one of our ancestors, so a variable
  /// leaked into an unrelated process cannot skip the queue. Same tree: a cwd at or below a
  /// holder's, in the same working tree, catches what ancestry cannot see (`xcodebuild test`
  /// starts its test host through launchd), and costs nothing since builds in one tree already
  /// serialise on its `.build` or derived data.
  public static func passesThrough(
    environment: [String: String], ancestors: [Int32], cwd: String, holders: [SlotRecord],
    workingTreeRoot: (String) -> String?
  ) -> Bool {
    if let value = environment[holderVariable], let pid = Int32(value), ancestors.contains(pid) {
      return true
    }
    let holdersAbove = holders.filter { isAtOrBelow(cwd, $0.cwd) }
    guard !holdersAbove.isEmpty, let root = workingTreeRoot(cwd) else { return false }
    return holdersAbove.contains { workingTreeRoot($0.cwd) == root }
  }

  /// By whole components: `/r/apple` is not below `/r/app`.
  private static func isAtOrBelow(_ path: String, _ ancestor: String) -> Bool {
    if path == ancestor { return true }
    let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
    return path.hasPrefix(prefix)
  }
}
