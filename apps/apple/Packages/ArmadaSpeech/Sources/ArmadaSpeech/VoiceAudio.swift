import AVFoundation
import Synchronization

/// The one audio engine voice listens and speaks through, so that a reply can be cancelled out
/// of the microphone that hears the answer.
///
/// **Why one engine.** Voice processing removes from the microphone only what the same engine
/// plays. Measured on 2026-10-12 on a MacBook Pro's own microphone and speakers, a spoken reply
/// rose above the room by about 27 dB through `AVSpeechSynthesizer.speak`, 18 dB through a second
/// engine and 5.5 dB through this one, and the ring left after it ended was gone too.
///
/// **Three modes, one at a time.** `listening` is the microphone alone, as a question has it.
/// `speaking` is the player alone, so a reply nobody will answer keeps the orange dot off.
/// `duplex` is both, with voice processing on: a reply that may be talked over. An engine is
/// built for one mode, and `open` with a mode the running one does not serve stops it and
/// builds another, ending whatever it played.
///
/// **What voice processing asks of the graph,** each found by a failed start on macOS 27
/// (`-10875` from the output unit's `kAUInitialize`), and none documented:
/// - The microphone then reports nine identical channels. The tap takes them with `format: nil`
///   and passes on the first, which is why `microphoneFormat` is mono there.
/// - Nothing else may read the microphone node's format: connecting it to a mixer, even a muted
///   one, fails the start.
/// - The mixer has to be connected to the output with an explicit format.
/// Other apps' audio is ducked as little as the system allows, so music playing under a reply
/// is barely quieter.
@MainActor
public final class VoiceAudio {
  public enum Mode: Sendable {
    case listening
    case speaking
    case duplex

    /// Whether an engine built for `self` can also do what `needed` asks.
    func serves(_ needed: Mode) -> Bool { self == needed || self == .duplex }
  }

  public enum Failure: LocalizedError {
    case noMicrophone

    public var errorDescription: String? {
      switch self {
      case .noMicrophone: "Armada found no microphone to listen with."
      }
    }
  }

  /// What the player takes: Kokoro's own format. Anything else is converted on the way in.
  public static let playerFormat = AVAudioFormat(
    standardFormatWithSampleRate: KokoroSynthesizer.sampleRate, channels: 1)!

  public private(set) var mode: Mode?
  /// The format microphone buffers arrive in while a mode with the microphone runs.
  public private(set) var microphoneFormat: AVAudioFormat?
  /// Something has been played since the engine opened. Until then the echo canceller has had
  /// nothing to learn from, so what the microphone hears says nothing about a voice over a reply.
  public private(set) var hasPlayed = false
  /// From 0 to 1. Takes effect straight away, mid-sentence included.
  public var volume: Float = 1 {
    didSet { player?.volume = volume }
  }

  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private let tap = MicrophoneTap()
  /// The buffer playing and the sentence waiting on it, tagged so a late completion from a
  /// stopped buffer never ends the next one.
  private var playing: (token: Int, continuation: CheckedContinuation<Bool, Never>)?
  private var playToken = 0

  public init() {}

  /// Run an engine that serves `needed`, replacing one that does not.
  public func open(_ needed: Mode) throws {
    if let mode, mode.serves(needed) { return }
    close()
    let engine = AVAudioEngine()
    var microphone: AVAudioFormat?
    if needed != .speaking {
      let input = engine.inputNode
      if needed == .duplex {
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
          enableAdvancedDucking: false, duckingLevel: .min)
        let output = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(
          engine.mainMixerNode, to: engine.outputNode,
          format: output.sampleRate > 0
            ? output : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0,
          let mono = AVAudioFormat(standardFormatWithSampleRate: native.sampleRate, channels: 1)
        else { throw Failure.noMicrophone }
        microphone = mono
        input.installTap(
          onBus: 0, bufferSize: 2048, format: nil, block: tap.block(firstChannel: true))
      } else {
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else { throw Failure.noMicrophone }
        microphone = native
        input.installTap(
          onBus: 0, bufferSize: 2048, format: native, block: tap.block(firstChannel: false))
      }
    }
    var player: AVAudioPlayerNode?
    if needed != .listening {
      let node = AVAudioPlayerNode()
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: Self.playerFormat)
      node.volume = volume
      player = node
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      if needed != .speaking { engine.inputNode.removeTap(onBus: 0) }
      throw error
    }
    // A changed output or input device stops the engine without completing the buffer it was
    // playing, or telling the microphone's reader.
    NotificationCenter.default.addObserver(
      self, selector: #selector(configurationChanged),
      name: .AVAudioEngineConfigurationChange, object: engine)
    self.engine = engine
    self.player = player
    self.microphoneFormat = microphone
    self.mode = needed
    hasPlayed = false
  }

  /// Stop the engine, and end whatever it was playing. The player goes before the engine, every
  /// time: an engine stopped under a player left playing restarts with that player stuck, and the
  /// next buffer never plays and never completes. Measured on 2026-09-15, as a second answer that
  /// was never heard.
  public func close() {
    guard let engine else { return }
    NotificationCenter.default.removeObserver(
      self, name: .AVAudioEngineConfigurationChange, object: engine)
    player?.stop()
    if mode != .speaking { engine.inputNode.removeTap(onBus: 0) }
    engine.stop()
    self.engine = nil
    player = nil
    microphoneFormat = nil
    mode = nil
    tap.receiver = nil
    endPlaying(token: playToken, played: true)
  }

  /// Where microphone buffers go, on the audio thread, in `microphoneFormat`. Nil drops them.
  public func setMicrophone(_ receiver: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
    tap.receiver = receiver
  }

  /// Play `buffer` to the end, mono in any sample rate. False when nothing could play it: no
  /// engine with a player, or a buffer that would not convert.
  public func play(_ buffer: AVAudioPCMBuffer) async -> Bool {
    guard let engine, engine.isRunning, let player, let converted = Self.converted(buffer) else {
      return false
    }
    endPlaying(token: playToken, played: true)
    hasPlayed = true
    playToken += 1
    let token = playToken
    return await withCheckedContinuation { continuation in
      playing = (token, continuation)
      player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { @Sendable _ in
        self.bufferPlayed(token: token)
      }
      player.play()
    }
  }

  /// Cut off what is playing, at once, and leave the engine running.
  public func stopPlaying() {
    player?.stop()
    endPlaying(token: playToken, played: true)
  }

  nonisolated private func bufferPlayed(token: Int) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { self.endPlaying(token: token, played: true) }
    }
  }

  private func endPlaying(token: Int, played: Bool) {
    guard let playing, playing.token == token else { return }
    self.playing = nil
    playing.continuation.resume(returning: played)
  }

  /// The system stopped the engine: let it all go, and treat the sentence that was playing as
  /// done, or the queue would wait on it forever.
  @objc nonisolated private func configurationChanged(_ notification: Notification) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { self.close() }
    }
  }

  private static func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard buffer.frameLength > 0, buffer.format.channelCount == 1 else { return nil }
    if buffer.format == playerFormat { return buffer }
    guard let converter = AVAudioConverter(from: buffer.format, to: playerFormat) else {
      return nil
    }
    let ratio = playerFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: capacity) else {
      return nil
    }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
  }
}

/// The audio thread's half: each microphone buffer handed to whoever reads it now.
///
/// Built here, in a nonisolated type, so the tap's closure is never inferred to belong to the
/// main actor and trapped when the audio thread calls it. The reader changes under the lock, so
/// a buffer goes to the old reader or the new one, never to both and never to neither.
private final class MicrophoneTap: Sendable {
  typealias Receiver = @Sendable (AVAudioPCMBuffer) -> Void

  private let current = Mutex<Receiver?>(nil)

  var receiver: Receiver? {
    get { current.withLock { $0 } }
    set { current.withLock { $0 = newValue } }
  }

  /// With `firstChannel`, a copy of channel 0 alone: voice processing's nine channels are the
  /// same signal, and the copy is the reader's to keep.
  func block(firstChannel: Bool) -> AVAudioNodeTapBlock {
    { [self] buffer, _ in
      let receiver = current.withLock { $0 }
      guard let receiver else { return }
      guard firstChannel else { return receiver(buffer) }
      guard let source = buffer.floatChannelData?[0],
        let format = AVAudioFormat(
          standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
        let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
        let target = mono.floatChannelData?[0]
      else { return }
      mono.frameLength = buffer.frameLength
      target.update(from: source, count: Int(buffer.frameLength))
      receiver(mono)
    }
  }
}
