import BuildSlotCore
import Foundation
import Testing

// Whether a `swift` typed in the login shell reaches the shims: their folder on PATH, ahead of
// the folder holding the real tool. Settings warns when it does not.
struct PathCheckTests {
  @Test func binDirBeforeUsrBin() {
    #expect(PathCheck.shimsComeFirst(path: "/u/.local/bin:/usr/bin:/bin", binDir: "/u/.local/bin"))
  }

  @Test func binDirAfterUsrBin() {
    #expect(!PathCheck.shimsComeFirst(path: "/usr/bin:/u/.local/bin", binDir: "/u/.local/bin"))
  }

  @Test func binDirAbsent() {
    #expect(!PathCheck.shimsComeFirst(path: "/usr/bin:/bin", binDir: "/u/.local/bin"))
  }

  @Test func otherRealToolDir() {
    #expect(
      !PathCheck.shimsComeFirst(
        path: "/opt/homebrew/bin:/u/.local/bin:/usr/bin", binDir: "/u/.local/bin",
        realToolDirs: ["/opt/homebrew/bin"]))
  }

  @Test func emptyEntriesIgnored() {
    #expect(PathCheck.shimsComeFirst(path: "::/u/.local/bin::/usr/bin:", binDir: "/u/.local/bin"))
  }

  @Test func trailingSlashCounts() {
    #expect(PathCheck.shimsComeFirst(path: "/u/.local/bin/:/usr/bin", binDir: "/u/.local/bin"))
  }

  @Test func symlinkedSpellingCounts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("buildslot-pathcheck-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real/bin")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: root.appendingPathComponent("real"))
    #expect(
      PathCheck.shimsComeFirst(path: link.path + "/bin:/usr/bin", binDir: real.path))
  }
}
