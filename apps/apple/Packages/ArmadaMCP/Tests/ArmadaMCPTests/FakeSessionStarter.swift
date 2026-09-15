import Foundation

@testable import ArmadaMCP

/// A starter that opens no terminal: it records what it was asked and answers as told.
final class FakeSessionStarter: SessionStarter, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [StartSessionRequest] = []

  var outcome: StartSessionOutcome = .started(
    StartedSession(
      project: "Armada site", path: "/Users/me/armada/web", vendor: "codex",
      accountID: "/Users/me/.codex", account: "Codex", terminal: "Terminal", withPrompt: true))

  var requests: [StartSessionRequest] { lock.withLock { recorded } }

  func startSession(_ request: StartSessionRequest) async -> StartSessionOutcome {
    lock.withLock { recorded.append(request) }
    return outcome
  }
}
