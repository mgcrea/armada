import Foundation

@testable import ArmadaMCP

/// A focuser that raises nothing: it records what it was asked and answers as told.
final class FakeSessionFocuser: SessionFocuser, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [FocusSessionRequest] = []

  var outcome: FocusSessionOutcome = .focused(
    FocusedSession(
      name: "Fix login", project: "armada", app: "Code", reach: .window,
      accessibilityGranted: true))

  var requests: [FocusSessionRequest] { lock.withLock { recorded } }

  func focusSession(_ request: FocusSessionRequest) async -> FocusSessionOutcome {
    lock.withLock { recorded.append(request) }
    return outcome
  }
}
