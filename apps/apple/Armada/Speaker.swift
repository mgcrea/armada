import AVFoundation
import ArmadaSpeech
import ArmadaSupervisor

/// Reads the supervisor's reply aloud, a sentence at a time, on this Mac.
///
/// Two voices, chosen per sentence from `voiceIdentifier` (a `VoiceChoice`): a system voice through
/// `AVSpeechSynthesizer`, or Kokoro through `KokoroSynthesizer` once it is downloaded and loaded.
/// Nothing is sent anywhere to be spoken either way. `stop()` is immediate, because a press to cut
/// an answer off that let the sentence finish would not feel like it worked.
///
/// **Kokoro never makes an answer wait.** A sentence goes to the system voice while Kokoro is still
/// loading, and whenever Kokoro fails on it. Sentences keep their order across both voices: each
/// is synthesized as soon as it arrives, and plays once the one before it has finished.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  /// Everything queued has been spoken. Not called for a queue that `stop()` cleared.
  var onFinished: (() -> Void)?
  var voiceIdentifier: String?
  /// The language replies are asked for. A fixed one is what a system voice falls back to, so an
  /// English answer is never read by the default voice of a French Mac.
  var replyLanguage: ReplyLanguage = .question

  private let synthesizer = AVSpeechSynthesizer()
  /// The utterance being spoken and the sentence waiting on it. A stopped utterance's late cancel
  /// callback finds nothing and is ignored.
  private var live: [ObjectIdentifier: (AVSpeechUtterance, CheckedContinuation<Void, Never>)] = [:]

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format = AVAudioFormat(
    standardFormatWithSampleRate: KokoroSynthesizer.sampleRate, channels: 1)!
  /// The Kokoro buffer playing and the sentence waiting on it, tagged so a late completion from a
  /// stopped buffer never ends the next one.
  private var playing: (token: Int, continuation: CheckedContinuation<Void, Never>)?
  private var playToken = 0

  /// The last sentence queued, which the next one waits for.
  private var tail: Task<Void, Never>?
  private var rendering: [Task<[Float]?, Never>] = []
  private var pending = 0
  /// Bumped by `stop()`, so sentences queued before it drop out wherever they are.
  private var generation = 0

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String) {
    let choice = VoiceChoice(storageValue: voiceIdentifier)
    let language = replyLanguage
    let generation = generation
    let previous = tail
    var rendered: Task<[Float]?, Never>?
    if case .kokoro(let voice) = choice, SpeechModelStore.voice.isLoaded {
      let task = Task.detached {
        try? await KokoroSynthesizer.shared.samples(for: text, voice: voice) {
          PhonemeSplit.pieces($0)
        }
      }
      rendering.append(task)
      rendered = task
    }
    pending += 1
    tail = Task { [weak self] in
      await previous?.value
      let samples = await rendered?.value
      guard let self, generation == self.generation else { return }
      var played = false
      if let samples, !samples.isEmpty { played = await play(samples) }
      if !played, generation == self.generation {
        await say(text, choice: choice, language: language)
      }
      finishedOne(generation)
    }
  }

  func stop() {
    generation += 1
    pending = 0
    tail = nil
    for task in rendering { task.cancel() }
    rendering.removeAll()
    let waiting = live.values.map(\.1)
    live.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    for continuation in waiting { continuation.resume() }
    stopEngine()
    endPlaying(token: playToken)
  }

  /// Voices for `language`, a language code, or for the system language when it is nil, best
  /// quality first.
  static func voices(language: String?) -> [AVSpeechSynthesisVoice] {
    let language = language ?? Locale.current.language.languageCode?.identifier ?? "en"
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { Self.languageCode(of: $0) == language }
      .sorted {
        $0.quality.rawValue != $1.quality.rawValue
          ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name
      }
  }

  /// `en` for an `en-US` voice.
  static func languageCode(of voice: AVSpeechSynthesisVoice) -> String? {
    Locale(identifier: voice.language).language.languageCode?.identifier
  }

  /// The system voice for `choice`: the one picked; when that is gone, or the choice is Kokoro and
  /// this sentence is not going to it, the best voice for a fixed reply language, and the system
  /// language's default otherwise.
  private static func voice(for choice: VoiceChoice, language: ReplyLanguage)
    -> AVSpeechSynthesisVoice?
  {
    if case .system(let identifier) = choice,
      let voice = AVSpeechSynthesisVoice(identifier: identifier)
    {
      return voice
    }
    if case .fixed(let code) = language, let voice = voices(language: code).first {
      return voice
    }
    return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
  }

  private func finishedOne(_ generation: Int) {
    guard generation == self.generation else { return }
    pending -= 1
    guard pending == 0 else { return }
    tail = nil
    rendering.removeAll()
    stopEngine()
    onFinished?()
  }

  // MARK: - System voice

  private func say(_ text: String, choice: VoiceChoice, language: ReplyLanguage) async {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(for: choice, language: language)
    await withCheckedContinuation { continuation in
      live[ObjectIdentifier(utterance)] = (utterance, continuation)
      synthesizer.speak(utterance)
    }
  }

  private func ended(_ id: ObjectIdentifier) {
    live.removeValue(forKey: id)?.1.resume()
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

  // MARK: - Kokoro

  /// Play `samples` to the end, or return false when the audio engine would not start, so the
  /// sentence can go to the system voice instead.
  private func play(_ samples: [Float]) async -> Bool {
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { return false }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { source in
      if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
    }
    do {
      try startEngine()
    } catch {
      return false
    }
    playToken += 1
    let token = playToken
    await withCheckedContinuation { continuation in
      playing = (token, continuation)
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
        self.bufferPlayed(token: token)
      }
      player.play()
    }
    return true
  }

  nonisolated private func bufferPlayed(token: Int) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.endPlaying(token: token) } }
  }

  private func endPlaying(token: Int) {
    guard let playing, playing.token == token else { return }
    self.playing = nil
    playing.continuation.resume()
  }

  /// Started for the first Kokoro sentence and stopped when the queue drains, so the audio
  /// hardware is not held between answers.
  private func startEngine() throws {
    if player.engine == nil {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      // A changed output device stops the engine without completing the buffer it was playing.
      NotificationCenter.default.addObserver(
        self, selector: #selector(engineConfigurationChanged),
        name: .AVAudioEngineConfigurationChange, object: engine)
    }
    if !engine.isRunning { try engine.start() }
  }

  /// Stop the player before the engine, every time. An engine stopped under a player left playing
  /// restarts with that player stuck: `isPlaying` stays true, `play()` does nothing, and the next
  /// buffer never plays and never completes, so the queue waits on it forever. Measured on
  /// 2026-09-15, as a second answer that was never heard.
  private func stopEngine() {
    guard player.engine != nil else { return }
    player.stop()
    if engine.isRunning { engine.stop() }
  }

  /// The system stopped the engine, but not the player: stop that too, and treat the sentence that
  /// was playing as done, or the queue would wait on it forever.
  @objc nonisolated private func engineConfigurationChanged(_ notification: Notification) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.stopEngine()
        self.endPlaying(token: self.playToken)
      }
    }
  }
}
