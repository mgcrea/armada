import AVFoundation
import ArmadaSupervisor
import Speech

/// The microphone and on-device dictation for one spoken question.
///
/// **The microphone runs only between `start` and `finish` or `cancel`**, so the menu bar's
/// orange dot is on exactly while the overlay says it is listening. There is no always-on
/// capture and no wake phrase.
///
/// **`DictationTranscriber`, not `SpeechTranscriber`.** Only dictation honours contextual
/// strings, which is how "Bastion" comes back capitalised as a project rather than as a word.
/// Measured on a recorded question on 2026-09-15: a 5.5 s question transcribed in 0.2 s, and
/// speech-recognition authorization was never asked for.
///
/// **Results are segments.** With `frequentFinalization`, finished stretches arrive final and
/// the one still being revised arrives volatile, replacing the last volatile one; the
/// question is every final segment and then the volatile one. Without it no result was ever
/// marked final in the same measurement.
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

  private(set) var transcript = ""

  var onTranscript: ((String) -> Void)?
  var onLevel: ((Float) -> Void)?
  /// The question ended, or never started. Reported once per question.
  var onPause: ((SilenceDetector.Verdict) -> Void)?
  /// Speech assets for the language are being installed, which only the first question waits on.
  var onPreparing: ((Bool) -> Void)?

  private var engine: AVAudioEngine?
  private var analyzer: SpeechAnalyzer?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var results: Task<Void, Never>?
  private var levels: Task<Void, Never>?
  private var finalized = ""
  private var volatile = ""
  private var detector = SilenceDetector()
  private var reportedPause = false

  func start(hints: [String]) async throws {
    guard await Self.microphoneAllowed() else { throw Failure.microphoneDenied }
    finalized = ""
    volatile = ""
    transcript = ""
    detector = SilenceDetector()
    reportedPause = false

    let transcriber = DictationTranscriber(
      locale: await Self.locale(), contentHints: [.shortForm], transcriptionOptions: [.punctuation],
      reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      onPreparing?(true)
      defer { onPreparing?(false) }
      try await request.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]
    )
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    if !hints.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = hints
      try await analyzer.setContext(context)
    }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    try await analyzer.start(inputSequence: stream)

    let engine = AVAudioEngine()
    let node = engine.inputNode
    let micFormat = node.outputFormat(forBus: 0)
    guard micFormat.channelCount > 0, micFormat.sampleRate > 0 else {
      continuation.finish()
      await analyzer.cancelAndFinishNow()
      throw Failure.noMicrophone
    }
    let pipe = TapPipe(
      from: micFormat, to: analyzerFormat ?? micFormat, input: continuation,
      levels: levelContinuation)
    node.installTap(onBus: 0, bufferSize: 2048, format: micFormat, block: pipe.block())
    engine.prepare()
    do {
      try engine.start()
    } catch {
      node.removeTap(onBus: 0)
      continuation.finish()
      await analyzer.cancelAndFinishNow()
      throw error
    }

    self.engine = engine
    self.analyzer = analyzer
    self.input = continuation
    results = Task { [weak self] in
      do {
        for try await result in transcriber.results { self?.absorb(result) }
      } catch {}
    }
    levels = Task { [weak self] in
      for await level in levelStream { self?.observe(level) }
    }
  }

  /// Stop listening and return the whole question.
  func finish() async -> String {
    stopEngine()
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
    levels?.cancel()
    analyzer = nil
    results = nil
    levels = nil
    return transcript
  }

  /// Stop listening and drop whatever was heard.
  func cancel() {
    stopEngine()
    input?.finish()
    input = nil
    results?.cancel()
    levels?.cancel()
    results = nil
    levels = nil
    if let analyzer {
      self.analyzer = nil
      Task { await analyzer.cancelAndFinishNow() }
    }
  }

  private func stopEngine() {
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
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

/// The audio thread's half: each microphone buffer converted to the analyzer's format, and its
/// level measured.
///
/// `@unchecked Sendable` because the converter is only ever touched from the tap's own thread,
/// one buffer at a time; the two continuations it yields to are `Sendable` themselves. The
/// closure is built here, in a nonisolated type, so it is never inferred to belong to the main
/// actor and trapped when the audio thread calls it.
nonisolated private final class TapPipe: @unchecked Sendable {
  private let converter: AVAudioConverter?
  private let outputFormat: AVAudioFormat
  private let input: AsyncStream<AnalyzerInput>.Continuation
  private let levels: AsyncStream<Float>.Continuation

  init(
    from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat,
    input: AsyncStream<AnalyzerInput>.Continuation, levels: AsyncStream<Float>.Continuation
  ) {
    self.converter =
      inputFormat == outputFormat ? nil : AVAudioConverter(from: inputFormat, to: outputFormat)
    self.outputFormat = outputFormat
    self.input = input
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
    guard let converter else {
      input.yield(AnalyzerInput(buffer: buffer))
      return
    }
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return
    }
    let supplied = Flag()
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied.isSet {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied.isSet = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return }
    input.yield(AnalyzerInput(buffer: output))
  }
}

nonisolated private final class Flag: @unchecked Sendable {
  var isSet = false
}
