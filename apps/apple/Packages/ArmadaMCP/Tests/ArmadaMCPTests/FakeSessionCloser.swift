import Foundation

@testable import ArmadaMCP

/// A closer that signals nothing: it records what it was asked and answers as told.
final class FakeSessionCloser: SessionCloser, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [CloseSessionRequest] = []

  var outcome: CloseSessionOutcome = .closed(
    ClosedSession(name: "Idle one", project: "armada", state: "idle", killed: false, exited: true))

  var requests: [CloseSessionRequest] { lock.withLock { recorded } }

  func closeSession(_ request: CloseSessionRequest) async -> CloseSessionOutcome {
    lock.withLock { recorded.append(request) }
    return outcome
  }
}
