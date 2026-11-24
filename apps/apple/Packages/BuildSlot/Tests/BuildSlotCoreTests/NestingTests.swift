import BuildSlotCore
import Testing

// When a shim skips the queue because the build it is part of already holds a slot. The paths
// are made up; `roots` stands in for the disk's `.git` lookup.
struct NestingTests {
  private func holder(cwd: String) -> SlotRecord {
    var holder = record(pid: 500)
    holder.cwd = cwd
    return holder
  }

  private func passes(
    environment: [String: String] = [:], ancestors: [Int32] = [600, 1], cwd: String = "/x",
    holders: [SlotRecord] = [], roots: [String: String] = [:]
  ) -> Bool {
    Nesting.passesThrough(
      environment: environment, ancestors: ancestors, cwd: cwd, holders: holders,
      workingTreeRoot: { roots[$0] })
  }

  @Test func holderEnvAncestor() {
    #expect(passes(environment: ["ARMADA_BUILDSLOT_HOLDER": "500"], ancestors: [600, 500, 1]))
  }

  @Test func holderEnvNotAncestor() {
    #expect(!passes(environment: ["ARMADA_BUILDSLOT_HOLDER": "500"], ancestors: [600, 1]))
  }

  @Test func holderEnvGarbage() {
    #expect(!passes(environment: ["ARMADA_BUILDSLOT_HOLDER": "x"], ancestors: [600, 1]))
  }

  @Test func sameTreeBelowHolder() {
    #expect(
      passes(
        cwd: "/r/apps/apple/Packages/K", holders: [holder(cwd: "/r/apps/apple")],
        roots: ["/r/apps/apple/Packages/K": "/r", "/r/apps/apple": "/r"]))
  }

  @Test func sameTreeAtHolder() {
    #expect(passes(cwd: "/r", holders: [holder(cwd: "/r")], roots: ["/r": "/r"]))
  }

  @Test func sameTreeStopsAtNestedGit() {
    #expect(
      !passes(
        cwd: "/r/.claude/worktrees/x", holders: [holder(cwd: "/r")],
        roots: ["/r": "/r", "/r/.claude/worktrees/x": "/r/.claude/worktrees/x"]))
  }

  @Test func outsideAnyTreeQueues() {
    #expect(!passes(cwd: "/t/fixture", holders: [holder(cwd: "/t")]))
  }

  @Test func siblingFolderQueues() {
    #expect(
      !passes(
        cwd: "/r/Packages/B", holders: [holder(cwd: "/r/Packages/A")],
        roots: ["/r/Packages/A": "/r", "/r/Packages/B": "/r"]))
  }

  @Test func prefixIsByComponent() {
    #expect(
      !passes(
        cwd: "/r/apple", holders: [holder(cwd: "/r/app")],
        roots: ["/r/app": "/r", "/r/apple": "/r"]))
  }
}
