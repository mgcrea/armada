import BuildSlotCore
import Testing

// The label a waiting shim prints for each holder ("held by valise/land-gate-f764fa9"). The
// paths are made up, so none exists and `realpath` leaves them as they are; `hasGit` stands in
// for the disk.
struct HolderLabelTests {
  private func gitAt(_ dirs: Set<String>) -> (String) -> Bool { { dirs.contains($0) } }

  @Test func worktreeIsRepoSlashName() {
    let hasGit = gitAt(["/u/p/valise", "/u/p/valise/.claude/worktrees/land-gate-f764fa9"])
    #expect(
      HolderLabel.label(cwd: "/u/p/valise/.claude/worktrees/land-gate-f764fa9", hasGit: hasGit)
        == "valise/land-gate-f764fa9")
  }

  @Test func belowAWorktreeIsStillRepoSlashName() {
    let hasGit = gitAt(["/u/p/valise", "/u/p/valise/.claude/worktrees/land-gate-f764fa9"])
    #expect(
      HolderLabel.label(
        cwd: "/u/p/valise/.claude/worktrees/land-gate-f764fa9/apps/apple", hasGit: hasGit)
        == "valise/land-gate-f764fa9")
  }

  @Test func checkoutIsTheGitRootsName() {
    #expect(
      HolderLabel.label(cwd: "/u/p/maquette/apps/apple", hasGit: gitAt(["/u/p/maquette"]))
        == "maquette")
  }

  @Test func outsideAnyRepoIsTheFoldersName() {
    #expect(HolderLabel.label(cwd: "/tmp/scratch", hasGit: gitAt([])) == "scratch")
  }

  @Test func workingTreeRootIsTheNearestGit() {
    let hasGit = gitAt(["/u/p/valise", "/u/p/valise/.claude/worktrees/x"])
    #expect(
      HolderLabel.workingTreeRoot(of: "/u/p/valise/.claude/worktrees/x/sub", hasGit: hasGit)
        == "/u/p/valise/.claude/worktrees/x")
  }

  @Test func workingTreeRootIsNilOutsideAnyRepo() {
    #expect(HolderLabel.workingTreeRoot(of: "/tmp/scratch", hasGit: gitAt([])) == nil)
  }
}
