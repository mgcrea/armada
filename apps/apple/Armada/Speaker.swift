import AVFoundation
import ArmadaSpeech
import ArmadaSupervisor
import Synchronization

/// Reads the supervisor's reply aloud, a sentence at a time, on this Mac.
///
/// Two voices, chosen per sentence from `voiceIdentifier` (a `VoiceChoice`): a system voice, or
/// Kokoro through `KokoroSynthesizer` once it is downloaded and loaded. Nothing is sent anywhere
/// to be spoken either way. `stop()` is immediate, because a press to cut an answer off that let
/// the sentence finish would not feel like it worked.
///
/// **Both voices play through `VoiceAudio`**, the engine the microphone shares, so a reply that
/// may be talked over is cancelled out of the microphone listening for that. The system voice is
/// rendered with `AVSpeechSynthesizer.write` rather than spoken, which is what puts it in that
/// engine. Measured on 2026-10-12: a warm sentence renders in 0.13–0.26 s, 15 to 30 times faster
/// than it plays, and the first one of a process takes 0.8 s.
///
/// **Rendering runs ahead and never makes an answer wait.** Each sentence is rendered as soon as
/// it arrives and plays once the one before it has finished. Kokoro is tried first when chosen
/// and loaded, and the system voice renders a sentence Kokoro could not. A sentence nothing could
/// render or play is spoken by `AVSpeechSynthesizer` directly, the way every reply was before,
/// and cannot be cancelled out of the microphone.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  /// Everything queued has been spoken. Not called for a queue that `stop()` cleared.
  var onFinished: (() -> Void)?
  var voiceIdentifier: String?
  /// The language replies are asked for. A fixed one is what a system voice falls back to, so an
  /// English answer is never read by the default voice of a French Mac.
  var replyLanguage: ReplyLanguage = .question
  /// From 0 to 1, relative to the Mac's output volume, for both voices and straight away.
  var volume: Float = 1 {
    didSet { audio.volume = volume }
  }

  private let audio: VoiceAudio
  /// Speaks a sentence that could not be rendered, the last resort.
  private let synthesizer = AVSpeechSynthesizer()
  /// Renders system-voice sentences into buffers, one at a time.
  private let renderer = AVSpeechSynthesizer()
  /// The utterance being spoken and the sentence waiting on it. A stopped utterance's late cancel
  /// callback finds nothing and is ignored.
  private var live: [ObjectIdentifier: (AVSpeechUtterance, CheckedContinuation<Void, Never>)] = [:]

  /// The last sentence queued, which the next one waits for.
  private var tail: Task<Void, Never>?
  /// The last system-voice render queued, which the next one waits for: the renderer takes one
  /// utterance at a time.
  private var renderTail: Task<Rendered?, Never>?
  private var rendering: [Task<Rendered?, Never>] = []
  private var pending = 0
  /// Bumped by `stop()`, so sentences queued before it drop out wherever they are.
  private var generation = 0

  /// `audio` is shared with `VoiceCapture`.
  init(audio: VoiceAudio) {
    self.audio = audio
    super.init()
    synthesizer.delegate = self
    audio.volume = volume
  }

  func speak(_ text: String) {
    let choice = VoiceChoice(storageValue: voiceIdentifier)
    let language = replyLanguage
    let generation = generation
    let previous = tail
    let rendered = render(text, choice: choice, language: language)
    pending += 1
    tail = Task { [weak self] in
      await previous?.value
      let audio = await rendered.value
      guard let self, generation == self.generation else { return }
      var played = false
      if let buffer = audio?.buffer() { played = await play(buffer) }
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
    renderTail = nil
    for task in rendering { task.cancel() }
    rendering.removeAll()
    renderer.stopSpeaking(at: .immediate)
    let waiting = live.values.map(\.1)
    live.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    for continuation in waiting { continuation.resume() }
    audio.stopPlaying()
    if audio.mode == .speaking { audio.close() }
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
    renderTail = nil
    rendering.removeAll()
    // A reply that may be answered keeps the engine: its microphone is the answer's.
    if audio.mode == .speaking { audio.close() }
    onFinished?()
  }

  // MARK: - Rendering

  /// `text` as audio, started now: Kokoro's when it is the choice and loaded, the system voice's
  /// otherwise or when Kokoro fails on it. Nil when neither could.
  private func render(_ text: String, choice: VoiceChoice, language: ReplyLanguage)
    -> Task<Rendered?, Never>
  {
    var kokoro: Task<[Float]?, Never>?
    if case .kokoro(let voice) = choice, SpeechModelStore.voice.isLoaded {
      kokoro = Task.detached {
        try? await KokoroSynthesizer.shared.samples(for: text, voice: voice) {
          PhonemeSplit.pieces($0)
        }
      }
    }
    let previous = renderTail
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(for: choice, language: language)
    let renderer = renderer
    let task = Task { () -> Rendered? in
      if let samples = await kokoro?.value, !samples.isEmpty {
        return Rendered(samples: samples, sampleRate: KokoroSynthesizer.sampleRate)
      }
      // One utterance at a time through the renderer, in order.
      _ = await previous?.value
      guard !Task.isCancelled else { return nil }
      return await SystemVoice.render(utterance, with: renderer)
    }
    renderTail = task
    rendering.append(task)
    return task
  }

  /// Play `buffer` to the end through the shared engine, or return false when it could not, so
  /// the sentence can be spoken directly instead. A question being listened for has the engine,
  /// and is never torn down for a reply.
  private func play(_ buffer: AVAudioPCMBuffer) async -> Bool {
    guard audio.mode != .listening else { return false }
    do {
      try audio.open(.speaking)
    } catch {
      return false
    }
    return await audio.play(buffer)
  }

  // MARK: - Speaking directly

  private func say(_ text: String, choice: VoiceChoice, language: ReplyLanguage) async {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(for: choice, language: language)
    utterance.volume = volume
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
}

/// A system voice rendered into one buffer instead of spoken.
///
/// Nonisolated so the callback `write` calls on its own queue is never inferred to belong to the
/// main actor and trapped there.
nonisolated private enum SystemVoice {
  /// The whole of `utterance` as mono samples in the voice's own format, or nil when the voice
  /// rendered nothing, or the task was cancelled before it finished.
  static func render(_ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer)
    async -> Rendered?
  {
    let collected = Collected()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        collected.wait(continuation)
        synthesizer.write(utterance) { buffer in
          guard let pcm = buffer as? AVAudioPCMBuffer else { return }
          if pcm.frameLength == 0 {
            collected.finish()
          } else {
            collected.append(pcm)
          }
        }
      }
    } onCancel: {
      // A stopped synthesizer is not promised to send the empty buffer that ends a render.
      collected.finish(cancelled: true)
    }
    return collected.rendered()
  }

  /// What `write` has handed over so far, and the render waiting on the rest. `write` calls back
  /// on its own queue and cancellation arrives on any thread, hence the lock.
  private final class Collected: Sendable {
    private struct State: @unchecked Sendable {
      var samples: [Float] = []
      var sampleRate: Double = 0
      var cancelled = false
      var continuation: CheckedContinuation<Void, Never>?
      var finished = false
    }

    private let state = Mutex(State())

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
      let resumeNow = state.withLock { state in
        guard !state.finished else { return true }
        state.continuation = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }

    func append(_ pcm: AVAudioPCMBuffer) {
      let count = Int(pcm.frameLength)
      var floats: [Float] = []
      if let data = pcm.floatChannelData?[0] {
        floats = Array(UnsafeBufferPointer(start: data, count: count))
      } else if let data = pcm.int16ChannelData?[0] {
        floats = UnsafeBufferPointer(start: data, count: count).map { Float($0) / 32768 }
      }
      state.withLock { state in
        state.sampleRate = pcm.format.sampleRate
        state.samples += floats
      }
    }

    func finish(cancelled: Bool = false) {
      let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
        guard !state.finished else { return nil }
        state.finished = true
        state.cancelled = cancelled
        defer { state.continuation = nil }
        return state.continuation
      }
      continuation?.resume()
    }

    func rendered() -> Rendered? {
      let (samples, sampleRate, cancelled) = state.withLock {
        ($0.samples, $0.sampleRate, $0.cancelled)
      }
      guard !cancelled, !samples.isEmpty, sampleRate > 0 else { return nil }
      return Rendered(samples: samples, sampleRate: sampleRate)
    }
  }
}

/// A sentence's audio, mono, between the render that made it and the engine that plays it. Plain
/// samples rather than an `AVAudioPCMBuffer`, which is not `Sendable` and so cannot be what a
/// render task returns.
nonisolated private struct Rendered: Sendable {
  var samples: [Float]
  var sampleRate: Double

  func buffer() -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { source in
      if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
    }
    return buffer
  }
}
