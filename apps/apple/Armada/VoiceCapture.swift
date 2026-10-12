import AVFoundation
import ArmadaSpeech
import ArmadaSupervisor
import Speech
import Synchronization

/// The microphone, and the on-device recognizer that turns one spoken question into text.
///
/// **Two recognizers, Parakeet first.** Parakeet v3 (`ParakeetRecognizer`) works out which of 25
/// languages is being spoken, question by question. Apple's `DictationTranscriber` has to be told
/// one locale before you speak, so a French question with English words in it goes through a
/// French-only model. Voice uses Parakeet whenever the model is in FluidAudio's shared folder,
/// and Apple's dictation until then; see `SpeechModelStore`.
///
/// **The microphone runs only between `start` and `finish` or `cancel`**, so the menu bar's
/// orange dot is on exactly while the overlay says it is listening. There is no always-on
/// capture and no wake phrase. The one exception is `standBy`: with a follow-up set, the
/// microphone also runs while a reply is spoken, so it can be talked over and answered.
///
/// **Parakeet's live words come from transcribing again.** Every half second the audio so far is
/// transcribed whole, each pass replacing the last guess, and `finish` transcribes it once more.
/// Measured on a 16 s question on 2026-09-15: never more than 0.125 s a pass, and early
/// mishearings corrected within one.
///
/// **Apple's results are segments.** With `frequentFinalization`, finished stretches arrive final
/// and the one still being revised arrives volatile, replacing the last volatile one. Only
/// dictation honours contextual strings, which is why it is `DictationTranscriber`.
@MainActor
final class VoiceCapture {
  enum Failure: LocalizedError {
    case microphoneDenied
    case noMicrophone

    var errorDescription: String? {
      switch self {
      case .microphoneDenied:
        "Allow Armada to use the microphone in System Settings ▸ Privacy & Security ▸ Microphone."
      case .noMicrophone: "Armada found no microphone to listen with."
      }
    }
  }

  enum Recognizer: Equatable {
    case parakeet
    case apple
  }

  static let liveInterval: Duration = .milliseconds(500)

  private(set) var transcript = ""
  private(set) var recognizer: Recognizer = .apple

  var onTranscript: ((String) -> Void)?
  var onLevel: ((Float) -> Void)?
  /// The question ended, or never started. Reported once per question.
  var onPause: ((SilenceDetector.Verdict) -> Void)?
  /// The recognizer is getting ready: Apple's language assets, or Parakeet's first load.
  var onPreparing: ((Bool) -> Void)?

  /// The engine shared with the `Speaker`.
  private let engine: VoiceAudio
  /// The microphone kept open through a reply, until `start` takes it over or it is closed.
  private var standby: StandbyPipe?
  private var watching: Task<Void, Never>?
  private var levels: Task<Void, Never>?
  private var detector = SilenceDetector()
  private var reportedPause = false

  // Apple dictation.
  private var analyzer: SpeechAnalyzer?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var results: Task<Void, Never>?
  private var finalized = ""
  private var volatile = ""

  // Parakeet.
  private var samples: AsyncStream<[Float]>.Continuation?
  private var collecting: Task<Void, Never>?
  private var live: Task<Void, Never>?
  private var audio: [Float] = []

  /// `audio` is shared with the `Speaker`, so a reply it plays is cancelled out of this microphone.
  init(audio: VoiceAudio) {
    self.engine = audio
  }

  func start(hints: [String]) async throws {
    guard await Self.microphoneAllowed() else { throw Failure.microphoneDenied }
    transcript = ""
    finalized = ""
    volatile = ""
    audio = []
    detector = SilenceDetector()
    reportedPause = false
    if ParakeetRecognizer.isInstalled {
      recognizer = .parakeet
      try startParakeet()
    } else {
      recognizer = .apple
      try await startApple(hints: hints)
    }
  }

  /// Stop listening and return the whole question.
  func finish() async -> String {
    stopMicrophone()
    switch recognizer {
    case .apple:
      input?.finish()
      input = nil
      if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
      if let results {
        // A sequence that never ends after finalizing must not hold the question hostage.
        let deadline = Task {
          try? await Task.sleep(for: .seconds(3))
          results.cancel()
        }
        await results.value
        deadline.cancel()
      }
      analyzer = nil
      results = nil
    case .parakeet:
      samples?.finish()
      samples = nil
      await collecting?.value
      live?.cancel()
      await live?.value
      collecting = nil
      live = nil
      if !audio.isEmpty, let text = try? await ParakeetRecognizer.shared.transcribe(audio) {
        transcript = text
        onTranscript?(text)
      }
      audio = []
    }
    levels?.cancel()
    levels = nil
    return transcript
  }

  /// Stop listening and drop whatever was heard.
  func cancel() {
    stopMicrophone()
    levels?.cancel()
    levels = nil
    input?.finish()
    input = nil
    results?.cancel()
    results = nil
    if let analyzer {
      self.analyzer = nil
      Task { await analyzer.cancelAndFinishNow() }
    }
    samples?.finish()
    samples = nil
    collecting?.cancel()
    collecting = nil
    live?.cancel()
    live = nil
    audio = []
  }

  // MARK: - Parakeet

  private func startParakeet() throws {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: ParakeetRecognizer.sampleRate, channels: 1,
        interleaved: false)
    else { throw Failure.noMicrophone }
    let (stream, continuation) = AsyncStream<[Float]>.makeStream()
    // The microphone first, then the model: a question started while the model is still loading
    // is recorded from its first word rather than cut.
    try startMicrophone(output: .samples(continuation), format: format)
    samples = continuation
    collecting = Task { [weak self] in
      for await chunk in stream { self?.audio += chunk }
    }
    let parakeet = ParakeetRecognizer.shared
    live = Task { [weak self] in
      if await !parakeet.isLoaded {
        self?.onPreparing?(true)
        try? await parakeet.prepare()
        self?.onPreparing?(false)
      }
      var transcribed = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.liveInterval)
        guard let self, !Task.isCancelled else { return }
        let heard = audio
        // Nothing new worth a pass: under a quarter of a second since the last one.
        guard heard.count >= transcribed + Int(ParakeetRecognizer.sampleRate / 4) else { continue }
        transcribed = heard.count
        guard let text = try? await parakeet.transcribe(heard), !Task.isCancelled else { continue }
        transcript = text
        onTranscript?(text)
      }
    }
  }

  // MARK: - Apple dictation

  private func startApple(hints: [String]) async throws {
    let transcriber = DictationTranscriber(
      locale: await Self.locale(), contentHints: [.shortForm], transcriptionOptions: [.punctuation],
      reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      onPreparing?(true)
      defer { onPreparing?(false) }
      try await request.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [transcriber])
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    if !hints.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = hints
      try await analyzer.setContext(context)
    }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: stream)
    do {
      try startMicrophone(output: .analyzer(continuation), format: analyzerFormat)
    } catch {
      continuation.finish()
      await analyzer.cancelAndFinishNow()
      throw error
    }

    self.analyzer = analyzer
    self.input = continuation
    results = Task { [weak self] in
      do {
        for try await result in transcriber.results { self?.absorb(result) }
      } catch {}
    }
  }

  private func absorb(_ result: DictationTranscriber.Result) {
    let text = String(result.text.characters)
    if result.isFinal {
      finalized += text
      volatile = ""
    } else {
      volatile = text
    }
    transcript = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    onTranscript?(transcript)
  }

  // MARK: - The microphone

  /// Open the microphone for a reply that may be talked over, and call `onVoice` once if someone
  /// does. The microphone is echo-cancelled (`VoiceAudio`'s duplex mode), so the reply the same
  /// engine plays is not heard as a voice, and the last `StandbyPipe.keep` seconds are kept so
  /// that `start` begins the answer from its first word rather than from when it was noticed.
  func standBy(onVoice: @escaping () -> Void) throws {
    // Synchronous, so the engine is open before the first sentence plays: a question was just
    // heard, so the microphone is already allowed.
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw Failure.microphoneDenied
    }
    try engine.open(.duplex)
    guard let format = engine.microphoneFormat else { throw Failure.noMicrophone }
    let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    let pipe = StandbyPipe(sampleRate: format.sampleRate, levels: levelContinuation)
    standby = pipe
    engine.setMicrophone(pipe.receiver)
    watching = Task { [weak self] in
      var onset = VoiceOnset()
      for await level in levelStream {
        guard let self, standby === pipe else { return }
        // The warm-up counts from the reply's first sound, not from the microphone opening:
        // its first sentence can take most of a second to render.
        guard engine.hasPlayed else { continue }
        if onset.feed(level: level, at: ProcessInfo.processInfo.systemUptime) {
          onVoice()
          return
        }
      }
    }
  }

  var isStandingBy: Bool { standby != nil }

  /// Start reading the microphone, converting to `format` (the microphone's own when nil). The
  /// one standing by through a reply when there is one, with what it kept; otherwise a
  /// microphone of its own, without voice processing, since nothing is playing to cancel.
  private func startMicrophone(output: TapPipe.Output, format: AVAudioFormat?) throws {
    if standby == nil { try engine.open(.listening) }
    guard let micFormat = engine.microphoneFormat else { throw Failure.noMicrophone }
    let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    let pipe = TapPipe(
      from: micFormat, to: format ?? micFormat, output: output, levels: levelContinuation)
    if let standby {
      watching?.cancel()
      watching = nil
      standby.forward(to: pipe)
    } else {
      engine.setMicrophone(pipe.receiver)
    }
    levels = Task { [weak self] in
      for await level in levelStream { self?.observe(level) }
    }
  }

  /// Close the microphone, and the engine with it unless it is only playing.
  private func stopMicrophone() {
    watching?.cancel()
    watching = nil
    standby = nil
    engine.setMicrophone(nil)
    if engine.mode == .listening || engine.mode == .duplex { engine.close() }
  }

  private func observe(_ level: Float) {
    onLevel?(level)
    guard !reportedPause else { return }
    let verdict = detector.feed(level: level, at: ProcessInfo.processInfo.systemUptime)
    guard verdict != .listening else { return }
    reportedPause = true
    onPause?(verdict)
  }

  private static func microphoneAllowed() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  /// The system language when dictation supports it, the same language in another region
  /// next, and English last.
  private static func locale() async -> Locale {
    let supported = await DictationTranscriber.supportedLocales
    let current = Locale.current
    return supported.first { $0.identifier(.bcp47) == current.identifier(.bcp47) }
      ?? supported.first { $0.language.languageCode == current.language.languageCode }
      ?? Locale(identifier: "en-US")
  }
}

/// The audio thread's half: each microphone buffer converted to the recognizer's format, and its
/// level measured.
///
/// `@unchecked Sendable` because the converter is only ever touched from the tap's own thread,
/// one buffer at a time; the continuations it yields to are `Sendable` themselves. The closure is
/// built here, in a nonisolated type, so it is never inferred to belong to the main actor and
/// trapped when the audio thread calls it.
nonisolated private final class TapPipe: @unchecked Sendable {
  enum Output {
    /// Buffers for Apple's analyzer.
    case analyzer(AsyncStream<AnalyzerInput>.Continuation)
    /// 16 kHz mono samples for Parakeet.
    case samples(AsyncStream<[Float]>.Continuation)
  }

  private let converter: AVAudioConverter?
  private let outputFormat: AVAudioFormat
  private let output: Output
  private let levels: AsyncStream<Float>.Continuation

  init(
    from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat, output: Output,
    levels: AsyncStream<Float>.Continuation
  ) {
    self.converter =
      inputFormat == outputFormat ? nil : AVAudioConverter(from: inputFormat, to: outputFormat)
    self.outputFormat = outputFormat
    self.output = output
    self.levels = levels
  }

  var receiver: @Sendable (AVAudioPCMBuffer) -> Void {
    { [self] buffer in receive(buffer) }
  }

  func receive(_ buffer: AVAudioPCMBuffer) {
    if let channel = buffer.floatChannelData?[0] {
      levels.yield(
        SilenceDetector.level(
          of: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }
    guard let converted = convert(buffer) else { return }
    switch output {
    case .analyzer(let continuation):
      continuation.yield(AnalyzerInput(buffer: converted))
    case .samples(let continuation):
      guard let channel = converted.floatChannelData?[0] else { return }
      continuation.yield(
        Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
    }
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return buffer }
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return nil
    }
    let supplied = Flag()
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
      if supplied.isSet {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied.isSet = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, converted.frameLength > 0 else { return nil }
    return converted
  }
}

/// The microphone while a reply is spoken: its level for `VoiceOnset`, and the last `keep`
/// seconds of what it heard, until `forward` hands both to the answer's `TapPipe`.
///
/// The hand-over happens under the lock the audio thread takes for each buffer, so the answer
/// gets what was kept and then every buffer after it, none twice and none lost. The buffers are
/// `VoiceAudio`'s own copies, so keeping them is safe.
nonisolated private final class StandbyPipe: Sendable {
  /// Enough to hold a voice from its first word: `VoiceOnset` warms up for 0.6 s and holds for
  /// 0.25 s, and the main actor takes a moment to act on it.
  static let keep: Double = 1.5

  private enum State: @unchecked Sendable {
    case keeping([AVAudioPCMBuffer], frames: Int)
    case forwarding(TapPipe)
  }

  private let state = Mutex(State.keeping([], frames: 0))
  private let limit: Int
  private let levels: AsyncStream<Float>.Continuation

  init(sampleRate: Double, levels: AsyncStream<Float>.Continuation) {
    self.limit = Int(sampleRate * Self.keep)
    self.levels = levels
  }

  var receiver: @Sendable (AVAudioPCMBuffer) -> Void {
    { [self] buffer in receive(buffer) }
  }

  private func receive(_ buffer: AVAudioPCMBuffer) {
    let pipe: TapPipe? = state.withLock { state in
      switch state {
      case .forwarding(let pipe):
        return pipe
      case .keeping(var kept, var frames):
        kept.append(buffer)
        frames += Int(buffer.frameLength)
        while frames - Int(kept[0].frameLength) >= limit {
          frames -= Int(kept.removeFirst().frameLength)
        }
        state = .keeping(kept, frames: frames)
        return nil
      }
    }
    if let pipe { return pipe.receive(buffer) }
    if let channel = buffer.floatChannelData?[0] {
      levels.yield(
        SilenceDetector.level(
          of: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }
  }

  /// Give the answer what was kept, and every buffer from now on.
  func forward(to pipe: TapPipe) {
    state.withLock { state in
      if case .keeping(let kept, _) = state {
        for buffer in kept { pipe.receive(buffer) }
      }
      state = .forwarding(pipe)
    }
    levels.finish()
  }
}

nonisolated private final class Flag: @unchecked Sendable {
  var isSet = false
}
