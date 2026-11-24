import BuildSlotCore
import Darwin
import Foundation
import Testing

// The kernel reads behind the nesting rule and the holder record's pid-reuse guard, pinned on
// this test process: a misread `kinfo_proc` field would show as a wrong parent or a start time
// of 1970, not as a crash.
struct ProcessTreeTests {
  @Test func nearestAncestorIsParent() {
    #expect(ProcessTree.ancestors(of: getpid()).first == getppid())
  }

  @Test func startTimeIsInThePast() throws {
    let start = try #require(ProcessTree.startTime(of: getpid()))
    #expect(start <= .now)
    // This process started during this test run, not at the epoch.
    #expect(start > Date.now.addingTimeInterval(-24 * 3600))
  }

  @Test func missingProcessReadsAsNothing() throws {
    // Above macOS's PID_MAX (99 999), so never a live process.
    #expect(ProcessTree.ancestors(of: 99_999_999) == [])
    #expect(ProcessTree.startTime(of: 99_999_999) == nil)

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    let pid = child.processIdentifier
    #expect(ProcessTree.ancestors(of: pid) == [])
    #expect(ProcessTree.startTime(of: pid) == nil)
  }
}
