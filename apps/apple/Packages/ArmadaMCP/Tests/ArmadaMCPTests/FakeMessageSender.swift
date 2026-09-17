import Foundation

@testable import ArmadaMCP

/// A sender that writes nothing: it records what it was asked and answers as told.
final class FakeMessageSender: MessageSender, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [SendMessageRequest] = []

  var outcome: SendMessageOutcome = .delivered(name: "Docs", project: "armada")

  var requests: [SendMessageRequest] { lock.withLock { recorded } }

  func sendMessage(_ request: SendMessageRequest) async -> SendMessageOutcome {
    lock.withLock { recorded.append(request) }
    return outcome
  }
}
