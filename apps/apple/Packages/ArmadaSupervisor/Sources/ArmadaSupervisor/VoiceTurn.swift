/// How the shortcut asks a question.
public enum VoiceMode: String, CaseIterable, Sendable {
  /// Press once to start; the question ends at a pause or on a second press.
  case press
  /// Hold to talk; the question ends on release.
  case hold
}

/// Whether the microphone opens again by itself once a reply is over, so a question the reply
/// asked ("Should I go ahead?") can be answered without pressing the shortcut. Press mode only:
/// someone who chose to hold has chosen to keep the microphone to the key.
public enum VoiceFollowUp: String, CaseIterable, Sendable {
  case never
  case afterQuestion
  case afterEveryReply
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
/// overlay is only waiting to hide starts a follow-up question instead. The stop key does the
/// first without the second: it stops whatever voice is doing, a question included, and never
/// starts one.
///
/// **A reply can listen for its answer.** With `followUp` set, a reply that is over opens the
/// microphone again instead of waiting to hide. Silence then closes the card quietly: nobody
/// asked a question, so "Didn't catch that" would be wrong.
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
    /// The stop key, held only while `isStoppable`.
    case stop
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
  public var followUp: VoiceFollowUp
  /// The microphone opened by itself after a reply, not on a press.
  public private(set) var listensForAnswer = false
  /// The reply's latest sentence ends with a question mark.
  private var replyAsks = false

  public init(mode: VoiceMode, speaksReplies: Bool = true, followUp: VoiceFollowUp = .never) {
    self.mode = mode
    self.speaksReplies = speaksReplies
    self.followUp = followUp
  }

  /// Voice is listening, thinking or speaking, so the stop key has something to stop. Not while
  /// the card only waits to hide, when the key goes back to the app you are in.
  public var isStoppable: Bool {
    switch phase {
    case .listening, .thinking: true
    case .answering(let replyDone, let speechDone): !(replyDone && speechDone)
    case .idle, .failed: false
    }
  }

  public mutating func handle(_ event: Event) -> [Effect] {
    let effects = step(event)
    if case .listening = phase {} else { listensForAnswer = false }
    return effects
  }

  /// Whether a sentence asks something, looking past the closing quotes, brackets and markdown
  /// emphasis a reply may end on.
  public static func endsWithQuestion(_ sentence: String) -> Bool {
    let trailing: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "*", "_"]
    guard
      let last = sentence.last(where: { !$0.isWhitespace && !trailing.contains($0) })
    else { return false }
    return ["?", "？", "؟"].contains(last)
  }

  /// The reply has arrived and been spoken: listen for an answer, or wait to hide.
  private mutating func replyFinished() -> [Effect] {
    let listens =
      switch followUp {
      case .never: false
      case .afterQuestion: replyAsks
      case .afterEveryReply: true
      }
    guard mode == .press, listens else {
      phase = .answering(replyDone: true, speechDone: true)
      return [.scheduleDismiss]
    }
    phase = .listening(finishing: false)
    listensForAnswer = true
    return [.startCapture]
  }

  private mutating func step(_ event: Event) -> [Effect] {
    if case .sentence(let text) = event {
      switch phase {
      case .thinking, .answering:
        if text.contains(where: { !$0.isWhitespace }) { replyAsks = Self.endsWithQuestion(text) }
      default: break
      }
    }
    switch (phase, event) {
    case (.idle, .shortcutDown), (.failed, .shortcutDown),
      (.answering(replyDone: true, speechDone: true), .shortcutDown):
      phase = .listening(finishing: false)
      listensForAnswer = false
      return [.startCapture]

    case (.listening(finishing: false), .shortcutDown) where mode == .press,
      (.listening(finishing: false), .speechEnded) where mode == .press,
      (.listening(finishing: false), .shortcutUp) where mode == .hold:
      phase = .listening(finishing: true)
      return [.finishCapture]

    case (.listening, .transcriptFinal(let text)):
      let question = text.trimmingWhitespace
      guard !question.isEmpty else {
        if listensForAnswer {
          phase = .idle
          return [.hide]
        }
        phase = .failed(Self.emptyTranscriptMessage)
        return [.scheduleDismiss]
      }
      phase = .thinking
      replyAsks = false
      return [.send(question)]

    case (.thinking, .sentence(let text)):
      phase = .answering(replyDone: false, speechDone: !speaksReplies)
      return speaksReplies ? [.speak(text)] : []

    case (.answering(let replyDone, _), .sentence(let text)):
      guard speaksReplies else { return [] }
      phase = .answering(replyDone: replyDone, speechDone: false)
      return [.speak(text)]

    case (.thinking, .turnEnded(error: nil)):
      return replyFinished()

    case (.answering(_, let speechDone), .turnEnded(error: nil)):
      guard speechDone else {
        phase = .answering(replyDone: true, speechDone: false)
        return []
      }
      return replyFinished()

    case (.answering(let replyDone, speechDone: false), .speechFinished):
      guard replyDone else {
        phase = .answering(replyDone: false, speechDone: true)
        return []
      }
      return replyFinished()

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

    case (.listening, .stop):
      phase = .idle
      return [.cancelCapture, .hide]

    case (.thinking, .stop):
      phase = .idle
      return [.interrupt, .hide]

    case (.answering(replyDone: false, _), .stop):
      phase = .idle
      return [.interrupt, .stopSpeaking, .hide]

    // The reply is complete, so there is nothing to interrupt: only the voice to stop.
    case (.answering(replyDone: true, _), .closed), (.answering(replyDone: true, _), .stop):
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
