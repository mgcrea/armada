import BuildSlotCore
import Foundation
import Testing

// The lines a shim prints on stderr, as the spec's "What the shim says" gives them.
struct WaitMessagesTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func holder(_ label: String, pid: Int32, argv: [String], age: TimeInterval)
    -> SlotRecord
  {
    var holder = record(pid: pid, startedAt: now.addingTimeInterval(-age))
    holder.label = label
    holder.argv = argv
    return holder
  }

  private var valise: SlotRecord {
    holder("valise/land-gate-f764fa9", pid: 17804, argv: ["swift", "test"], age: 120)
  }

  private var maquette: SlotRecord {
    holder(
      "maquette/components", pid: 11208, argv: ["/usr/bin/xcodebuild", "test", "-scheme", "M"],
      age: 40)
  }

  @Test func waitingForSlotTwoHolders() {
    #expect(
      WaitMessages.waitingForSlot(holders: [valise, maquette], busy: 2, total: 2, now: now)
        == "buildslot: waiting for a slot (2 of 2 busy), held by valise/land-gate-f764fa9 "
        + "(pid 17804, swift test, 2 min) and maquette/components "
        + "(pid 11208, xcodebuild test, 40 s). Queued, not hung.")
  }

  @Test func waitingForSlotThreeHoldersJoinWithCommas() {
    let armada = holder("armada", pid: 9, argv: ["swift", "-v", "build"], age: 5)
    #expect(
      WaitMessages.waitingForSlot(holders: [valise, maquette, armada], busy: 3, total: 3, now: now)
        == "buildslot: waiting for a slot (3 of 3 busy), held by valise/land-gate-f764fa9 "
        + "(pid 17804, swift test, 2 min), maquette/components "
        + "(pid 11208, xcodebuild test, 40 s) and armada (pid 9, swift build, 5 s). "
        + "Queued, not hung.")
  }

  @Test func waitingForSlotWithoutReadableHolders() {
    #expect(
      WaitMessages.waitingForSlot(holders: [], busy: 2, total: 2, now: now)
        == "buildslot: waiting for a slot (2 of 2 busy). Queued, not hung.")
  }

  @Test func holderWithoutStartTimeHasNoAge() {
    var unknownAge = valise
    unknownAge.startedAt = nil
    #expect(
      WaitMessages.waitingForSlot(holders: [unknownAge], busy: 1, total: 1, now: now)
        == "buildslot: waiting for a slot (1 of 1 busy), held by valise/land-gate-f764fa9 "
        + "(pid 17804, swift test). Queued, not hung.")
  }

  // The action comes from Invocation's parsing, so an option's value is never taken for it.
  @Test(arguments: [
    (["xcodebuild", "-scheme", "A", "test"], "xcodebuild test"),
    (["/usr/bin/xcodebuild", "-project", "A.xcodeproj", "-scheme", "A"], "xcodebuild build"),
    (["xcodebuild", "-scheme", "build", "archive"], "xcodebuild archive"),
    (["swift"], "swift"),
  ])
  func commandShown(argv: [String], text: String) {
    let holder = holder("a", pid: 1, argv: argv, age: 5)
    #expect(
      WaitMessages.waitingForSlot(holders: [holder], busy: 1, total: 1, now: now)
        == "buildslot: waiting for a slot (1 of 1 busy), held by a (pid 1, \(text), 5 s). "
        + "Queued, not hung.")
  }

  @Test func waitingForMemory() {
    #expect(
      WaitMessages.waitingForMemory(.warning, remaining: 480)
        == "buildslot: a slot is free; waiting for memory pressure (warning) to ease, runs anyway "
        + "in 8 min.")
  }

  @Test func memoryCapReached() {
    #expect(
      WaitMessages.memoryCapReached(.warning, after: 600)
        == "buildslot: memory pressure still warning after 10 min; running anyway.")
  }

  @Test func slotCapReached() {
    #expect(
      WaitMessages.slotCapReached(after: 1800) == "buildslot: no slot after 30 min; running anyway."
    )
  }

  @Test func gotSlot() {
    #expect(WaitMessages.gotSlot(1, after: 192) == "buildslot: got slot 1 after 3 min 12 s.")
  }

  @Test func unqueued() {
    #expect(
      WaitMessages.unqueued("cannot write /private/tmp/armada-build-slots-501")
        == "buildslot: cannot write /private/tmp/armada-build-slots-501; running unqueued.")
  }

  @Test(arguments: [
    (0.0, "0 s"), (40.4, "40 s"), (59.9, "59 s"), (60, "1 min"), (120, "2 min"),
    (192, "3 min 12 s"), (3600, "1 h"), (3900, "1 h 5 min"), (-3, "0 s"), (.infinity, "0 s"),
    (.nan, "0 s"), (1e300, "24 h"),
  ])
  func duration(seconds: Double, text: String) {
    #expect(WaitMessages.duration(seconds) == text)
  }
}
