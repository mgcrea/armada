/// How the shortcut asks a question.
public enum VoiceMode: String, CaseIterable, Sendable {
  /// Press once to start; the question ends at a pause or on a second press.
  case press
  /// Hold to talk; the question ends on release.
  case hold
}

/// What one spoken question is doing, and what the app must do next, as a pure reducer.
///
/// Every rule about the shortcut lives here rather than in the controller, so the question
/// "what does a press do while it is still speaking?" has one answer and a test. The
/// controller feeds it events from the shortcut, the microphone, the `claude` process and
/// the synthesizer, and performs the effects it returns, in order.
///
/// **Pressing again always wins.** A press while the answer is still coming or still being
/// spoken cuts it off and hides the overlay. A press once the answer is finished and the
/// overlay is only waiting to hide starts a follow-up question instead.
public struct VoiceTurn: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle
    /// The microphone is open. `finishing` once the question has ended and the final
    /// transcript is awaited.
    case listening(finishing: Bool)
    /// The question is sent and no reply text has arrived yet.
    case thinking
    /// Reply text is arriving or being spoken.
    case answering(replyDone: Bool, speechDone: Bool)
    case failed(String)
  }

  public enum Event: Equatable, Sendable {
    case shortcutDown
    case shortcutUp
    /// The microphone heard the question end (press mode only).
    case speechEnded
    case transcriptFinal(String)
    case toolUse(String)
    case sentence(String)
    /// The reply is complete. A message when it failed.
    case turnEnded(error: String?)
    /// The synthesizer has nothing left to say.
    case speechFinished
    case failure(String)
    case dismissTimerFired
    /// The card's close button, which it shows only once the reply is in.
    case closed
  }

  public enum Effect: Equatable, Sendable {
    case startCapture
    case finishCapture
    case cancelCapture
    case send(String)
    case interrupt
    case speak(String)
    case stopSpeaking
    case scheduleDismiss
    case hide
  }

  public static let emptyTranscriptMessage = "Didn't catch that."

  public private(set) var phase: Phase = .idle
  public var mode: VoiceMode
  public var speaksReplies: Bool

  public init(mode: VoiceMode, speaksReplies: Bool = true) {
    self.mode = mode
    self.speaksReplies = speaksReplies
  }

  public mutating func handle(_ event: Event) -> [Effect] {
    switch (phase, event) {
    case (.idle, .shortcutDown), (.failed, .shortcutDown),
      (.answering(replyDone: true, speechDone: true), .shortcutDown):
      phase = .listening(finishing: false)
      return [.startCapture]

    case (.listening(finishing: false), .shortcutDown) where mode == .press,
      (.listening(finishing: false), .speechEnded) where mode == .press,
      (.listening(finishing: false), .shortcutUp) where mode == .hold:
      phase = .listening(finishing: true)
      return [.finishCapture]

    case (.listening, .transcriptFinal(let text)):
      let question = text.trimmingWhitespace
      guard !question.isEmpty else {
        phase = .failed(Self.emptyTranscriptMessage)
        return [.scheduleDismiss]
      }
      phase = .thinking
      return [.send(question)]

    case (.thinking, .sentence(let text)):
      phase = .answering(replyDone: false, speechDone: !speaksReplies)
      return speaksReplies ? [.speak(text)] : []

    case (.answering(let replyDone, _), .sentence(let text)):
      guard speaksReplies else { return [] }
      phase = .answering(replyDone: replyDone, speechDone: false)
      return [.speak(text)]

    case (.thinking, .turnEnded(error: nil)):
      phase = .answering(replyDone: true, speechDone: true)
      return [.scheduleDismiss]

    case (.answering(_, let speechDone), .turnEnded(error: nil)):
      phase = .answering(replyDone: true, speechDone: speechDone)
      return speechDone ? [.scheduleDismiss] : []

    case (.answering(let replyDone, speechDone: false), .speechFinished):
      phase = .answering(replyDone: replyDone, speechDone: true)
      return replyDone ? [.scheduleDismiss] : []

    case (.thinking, .turnEnded(error: let message?)),
      (.answering, .turnEnded(error: let message?)):
      phase = .failed(message)
      return [.stopSpeaking, .scheduleDismiss]

    case (.thinking, .shortcutDown):
      phase = .idle
      return [.interrupt, .hide]

    case (.answering(let replyDone, _), .shortcutDown):
      phase = .idle
      return (replyDone ? [] : [.interrupt]) + [.stopSpeaking, .hide]

    case (.listening, .failure(let message)):
      phase = .failed(message)
      return [.cancelCapture, .scheduleDismiss]

    case (.thinking, .failure(let message)), (.answering, .failure(let message)):
      phase = .failed(message)
      return [.stopSpeaking, .scheduleDismiss]

    case (.idle, .failure(let message)):
      phase = .failed(message)
      return [.scheduleDismiss]

    // The reply is complete, so there is nothing to interrupt: only the voice to stop.
    case (.answering(replyDone: true, _), .closed):
      phase = .idle
      return [.stopSpeaking, .hide]

    case (.failed, .dismissTimerFired),
      (.answering(replyDone: true, speechDone: true), .dismissTimerFired):
      phase = .idle
      return [.hide]

    default:
      return []
    }
  }
}

extension String {
  fileprivate var trimmingWhitespace: String {
    var text = Substring(self)
    while text.first?.isWhitespace == true { text.removeFirst() }
    while text.last?.isWhitespace == true { text.removeLast() }
    return String(text)
  }
}
