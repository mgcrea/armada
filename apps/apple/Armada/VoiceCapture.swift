import AVFoundation
import ArmadaSpeech
import ArmadaSupervisor
import Speech

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
/// capture and no wake phrase.
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

  private var engine: AVAudioEngine?
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
    stopEngine()
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
    stopEngine()
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
    try startEngine(output: .samples(continuation), format: format)
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
      try startEngine(output: .analyzer(continuation), format: analyzerFormat)
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

  /// Start the input tap, converting to `format` (the microphone's own when nil).
  private func startEngine(output: TapPipe.Output, format: AVAudioFormat?) throws {
    let engine = AVAudioEngine()
    let node = engine.inputNode
    let micFormat = node.outputFormat(forBus: 0)
    guard micFormat.channelCount > 0, micFormat.sampleRate > 0 else { throw Failure.noMicrophone }
    let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    let pipe = TapPipe(
      from: micFormat, to: format ?? micFormat, output: output, levels: levelContinuation)
    node.installTap(onBus: 0, bufferSize: 2048, format: micFormat, block: pipe.block())
    engine.prepare()
    do {
      try engine.start()
    } catch {
      node.removeTap(onBus: 0)
      levelContinuation.finish()
      throw error
    }
    self.engine = engine
    levels = Task { [weak self] in
      for await level in levelStream { self?.observe(level) }
    }
  }

  private func stopEngine() {
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
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

  func block() -> AVAudioNodeTapBlock {
    { [self] buffer, _ in receive(buffer) }
  }

  private func receive(_ buffer: AVAudioPCMBuffer) {
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

nonisolated private final class Flag: @unchecked Sendable {
  var isSet = false
}
