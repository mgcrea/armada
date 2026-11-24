import Foundation

/// What a shim does after one read of the queue.
public enum AcquireStep: Equatable, Sendable {
  case take(slot: Int)
  case waitForSlot
  case waitForMemory(MemoryPressure)
  /// A cap ran out. `slot` is nil when every slot is still busy: the build runs without a lock.
  case takeAnyway(slot: Int?, reason: AnywayReason)
}

public enum AnywayReason: Equatable, Sendable {
  case memoryCap, slotCap
}

public enum AcquirePolicy {
  /// The memory rule only holds a build back while a slot is free and another build holds one:
  /// with nothing building, waiting cannot relieve the pressure, so the first build always
  /// starts. Both caps exist so that chronic pressure or a hung holder never blocks forever.
  public static func decide(
    state: QueueState, settings: BuildSlotSettings, pressure: MemoryPressure,
    waitedForSlot: TimeInterval, waitedForMemory: TimeInterval
  ) -> AcquireStep {
    guard let slot = state.freeSlots.first else {
      return waitedForSlot < TimeInterval(settings.slotWaitCapSeconds)
        ? .waitForSlot : .takeAnyway(slot: nil, reason: .slotCap)
    }
    guard !state.holders.isEmpty, pressure.blocks(under: settings.memoryRule) else {
      return .take(slot: slot)
    }
    return waitedForMemory < TimeInterval(settings.memoryWaitCapSeconds)
      ? .waitForMemory(pressure) : .takeAnyway(slot: slot, reason: .memoryCap)
  }
}
