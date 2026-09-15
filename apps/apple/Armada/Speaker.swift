import AVFoundation

/// Reads the supervisor's reply aloud, a sentence at a time, on this Mac.
///
/// `AVSpeechSynthesizer` with a system voice: nothing is sent anywhere to be spoken, which is
/// why voice adds no network allowance. `stop()` is immediate, because a press to cut an
/// answer off that let the sentence finish would not feel like it worked.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  /// Everything queued has been spoken, or the queue was stopped.
  var onFinished: (() -> Void)?
  var voiceIdentifier: String?

  private let synthesizer = AVSpeechSynthesizer()
  /// Utterances still to finish, held strongly so an identifier is never reused while it is
  /// here. A stopped utterance's late cancel callback finds nothing and is ignored.
  private var live: [ObjectIdentifier: AVSpeechUtterance] = [:]

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(identifier: voiceIdentifier)
    live[ObjectIdentifier(utterance)] = utterance
    synthesizer.speak(utterance)
  }

  func stop() {
    live.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
  }

  /// Voices for the system language, best quality first.
  static var voices: [AVSpeechSynthesisVoice] {
    let language = Locale.current.language.languageCode?.identifier ?? "en"
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix(language) }
      .sorted {
        $0.quality.rawValue != $1.quality.rawValue
          ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name
      }
  }

  private static func voice(identifier: String?) -> AVSpeechSynthesisVoice? {
    if let identifier, !identifier.isEmpty,
      let voice = AVSpeechSynthesisVoice(identifier: identifier)
    {
      return voice
    }
    return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
  }

  private func ended(_ id: ObjectIdentifier) {
    guard live.removeValue(forKey: id) != nil, live.isEmpty else { return }
    onFinished?()
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id) } }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id) } }
  }
}
