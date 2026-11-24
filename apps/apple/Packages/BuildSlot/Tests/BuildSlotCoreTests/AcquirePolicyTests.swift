import BuildSlotCore
import Testing

// What a shim does on each poll, from the queue it read, the settings and the memory pressure.
struct AcquirePolicyTests {
  private func state(holders: Int, free: [Int]) -> QueueState {
    QueueState(
      holders: (0..<holders).map { QueueEntry(slot: $0, record: record(pid: 100 + Int32($0))) },
      waiters: [], freeSlots: free)
  }

  private func decide(
    _ state: QueueState, rule: MemoryRule = .warning, pressure: MemoryPressure = .normal,
    waitedForSlot: Double = 0, waitedForMemory: Double = 0
  ) -> AcquireStep {
    var settings = BuildSlotSettings.defaults
    settings.memoryRule = rule
    return AcquirePolicy.decide(
      state: state, settings: settings, pressure: pressure, waitedForSlot: waitedForSlot,
      waitedForMemory: waitedForMemory)
  }

  @Test func takesFirstFree() {
    #expect(decide(state(holders: 1, free: [1])) == .take(slot: 1))
  }

  @Test func firstBuildIgnoresPressure() {
    #expect(decide(state(holders: 0, free: [0, 1]), pressure: .critical) == .take(slot: 0))
  }

  @Test func waitsOnMemoryWhileOthersBuild() {
    #expect(decide(state(holders: 1, free: [1]), pressure: .warning) == .waitForMemory(.warning))
  }

  @Test func memoryCapRunsAnyway() {
    #expect(
      decide(state(holders: 1, free: [1]), pressure: .warning, waitedForMemory: 600)
        == .takeAnyway(slot: 1, reason: .memoryCap))
  }

  @Test func ruleCriticalIgnoresWarning() {
    #expect(
      decide(state(holders: 1, free: [1]), rule: .critical, pressure: .warning) == .take(slot: 1))
  }

  @Test func ruleOffIgnoresCritical() {
    #expect(decide(state(holders: 1, free: [1]), rule: .off, pressure: .critical) == .take(slot: 1))
  }

  @Test func waitsForSlot() {
    #expect(decide(state(holders: 2, free: [])) == .waitForSlot)
  }

  @Test func slotCapRunsAnyway() {
    #expect(
      decide(state(holders: 2, free: []), waitedForSlot: 1800)
        == .takeAnyway(slot: nil, reason: .slotCap))
  }
}
