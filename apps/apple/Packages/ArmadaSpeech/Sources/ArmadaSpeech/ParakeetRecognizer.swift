import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 on this Mac, through FluidAudio: 25 European languages, detected
/// per question rather than chosen up front.
///
/// **Why Parakeet rather than Apple's dictation.** Apple's transcriber must be given one locale
/// before you speak, so a French question with English words in it goes through a French-only
/// model, and an English one through nothing useful. Measured on four spoken French questions on
/// 2026-09-15: Parakeet detected French by itself on every one and heard "Salut Armada" and
/// "roadmap" where Apple heard "Hermana" and "Run map", in 0.07–0.14 s a question.
///
/// **Live words come from transcribing again, not from a streaming model.** FluidAudio's streaming
/// managers are English-only (Parakeet Unified) or a separate, weaker multilingual model. The
/// same v3 model run over the growing buffer every half second took at most 0.125 s on a 16 s
/// question, and its early guesses corrected themselves within a pass.
///
/// **It never downloads on its own.** `prepare()` turns FluidAudio's offline mode on before asking
/// it for anything. The one network call is `download`, which only Settings ▸ Voice starts.
public actor ParakeetRecognizer {
  public static let shared = ParakeetRecognizer()

  /// Samples per second the model takes. Callers convert the microphone to this, mono.
  public static let sampleRate: Double = 16_000

  /// Where FluidAudio keeps the model for an unsandboxed app:
  /// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`.
  ///
  /// Shared with anything else on the Mac that runs FluidAudio unsandboxed, which is the point:
  /// a model already there is used as it is and never fetched again. A sandboxed app such as
  /// Cadence keeps its own copy inside its container, which Armada does not read.
  public static var modelDirectory: URL { AsrModels.defaultCacheDirectory(for: .v3) }

  public static var isInstalled: Bool { AsrModels.modelsExist(at: modelDirectory, version: .v3) }

  private var manager: AsrManager?

  private init() {}

  public var isLoaded: Bool { manager != nil }

  /// Load the model from disk. The first load on a Mac compiles it for the Neural Engine, which
  /// took 12.8 s when measured; every later one took 0.13 s.
  public func prepare() async throws {
    guard manager == nil else { return }
    ModelHub.offlineMode = true
    let models = try await AsrModels.loadFromCache(version: .v3)
    let manager = AsrManager(config: ASRConfig(melChunkContext: false))
    try await manager.loadModels(models)
    self.manager = manager
  }

  /// The words in `samples`, 16 kHz mono, in whichever of the 25 languages they are spoken.
  public func transcribe(_ samples: [Float]) async throws -> String {
    try await prepare()
    guard let manager else { return "" }
    var audio = samples
    // Under a second is padded with silence rather than handed over short.
    let minimum = Int(Self.sampleRate)
    if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(audio, decoderState: &state, language: nil)
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Drop the loaded model, for when voice is switched off.
  public func unload() {
    manager = nil
  }

  public enum DownloadFailure: LocalizedError {
    case incomplete

    public var errorDescription: String? {
      "The download finished without every model file in place. Try again."
    }
  }

  /// Fetch the model from huggingface.co into `modelDirectory`, reporting 0…1.
  ///
  /// The only network request voice makes, and only when the person presses Download:
  ///
  /// - **The host is pinned.** FluidAudio reads `REGISTRY_URL` and `MODEL_REGISTRY_URL` from the
  ///   environment; an address set in code wins over both.
  /// - **No identifier goes with it.** FluidAudio forwards a Hugging Face token found in the
  ///   environment as a bearer header. The model is public, so those variables are removed from
  ///   this process first.
  /// - **Offline mode comes back on** however the download ends.
  public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    ModelRegistry.baseURL = "https://huggingface.co"
    for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN"] {
      unsetenv(name)
    }
    ModelHub.offlineMode = false
    defer { ModelHub.offlineMode = true }
    _ = try await AsrModels.download(
      version: .v3, progressHandler: { update in progress(update.fractionCompleted) })
    guard isInstalled else { throw DownloadFailure.incomplete }
  }
}
