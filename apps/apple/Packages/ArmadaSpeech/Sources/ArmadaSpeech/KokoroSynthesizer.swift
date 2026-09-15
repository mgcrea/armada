import FluidAudio
import Foundation

/// Kokoro-82M on this Mac, through FluidAudio: the voice a reply is read in when the person picks
/// it over a system voice.
///
/// **Why Kokoro.** `AVSpeechSynthesizer` offers apps the system voices and nothing better: neither
/// macOS 26 nor 27 added one, and Siri's voices are not open to apps. Kokoro is 82M parameters,
/// Apache-2.0 for its code and weights, runs on the Neural Engine, and on 2026-09-15 tied NVIDIA's
/// Magpie, four times its size, on Artificial Analysis's speech arena. FluidAudio reads text into
/// phonemes with a lexicon and a small G2P model, so no GPL eSpeak comes with it.
///
/// **English, one voice.** `af_heart` is the voice pack the download includes. FluidAudio at this
/// revision fetches no other on demand, and its Kokoro reads English phonemes only.
///
/// **It never downloads on its own**, like `ParakeetRecognizer`. `prepare()` turns FluidAudio's
/// offline mode on first, and `isInstalled` asks for every file `initialize()` would otherwise
/// fetch, the lexicon included, because that one comes through a downloader offline mode does not
/// govern.
public actor KokoroSynthesizer {
  public static let shared = KokoroSynthesizer()

  /// Samples per second of what `samples(for:voice:split:)` returns, mono.
  public static let sampleRate: Double = 24_000

  /// The one voice pack the download brings.
  public static let voice = "af_heart"

  /// macOS 26.4 through 26.5.x crash inside Apple's BNNS during synthesis, whatever the compute
  /// units (FluidAudio #844), and 26.6 fixed it. FluidAudio only logs a warning there, so Armada
  /// does not offer Kokoro at all.
  public static var isSupported: Bool {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return !(version.majorVersion == 26 && (4...5).contains(version.minorVersion))
  }

  /// `~/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE`: the seven stages, their vocabulary and
  /// the voice pack. Shared with anything else on the Mac that runs FluidAudio's Kokoro unsandboxed,
  /// so a copy already there is used as it is.
  public static var modelDirectory: URL {
    modelsRoot.appending(path: Repo.kokoroAne.folderName, directoryHint: .isDirectory)
  }

  public static var isInstalled: Bool {
    let frontend = modelsRoot.appending(path: Repo.kokoro.folderName, directoryHint: .isDirectory)
    return present(ModelNames.KokoroAne.requiredModels, in: modelDirectory)
      && present(ModelNames.G2P.requiredModels.union([lexicon]), in: frontend)
  }

  /// FluidAudio's text-to-speech root, worked out here rather than through
  /// `TtsCacheDirectory.ensure()`, which creates the folder: looking must not leave a trace.
  private static var modelsRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".cache/fluidaudio/Models", directoryHint: .isDirectory)
  }

  private static let lexicon = "us_lexicon_cache.json"

  private static func present(_ names: Set<String>, in directory: URL) -> Bool {
    names.allSatisfy { name in
      let path = directory.appending(path: name).path(percentEncoded: false)
      return FileManager.default.fileExists(atPath: path)
    }
  }

  private var manager: KokoroAneManager?
  private var loading: Task<KokoroAneManager, Error>?
  /// Bumped by `unload()`, so a load still compiling when voice is switched off is not kept.
  private var generation = 0

  private init() {}

  public var isLoaded: Bool { manager != nil }

  /// Load the model from disk. The first load on a Mac compiles the seven stages for the Neural
  /// Engine, which FluidAudio measured at about 20 s on an M1; later loads take about 0.3 s.
  public func prepare() async throws {
    if manager != nil { return }
    let current = generation
    let task: Task<KokoroAneManager, Error>
    if let loading {
      task = loading
    } else {
      ModelHub.offlineMode = true
      task = Task {
        let manager = KokoroAneManager(variant: .english, defaultVoice: Self.voice)
        try await manager.initialize()
        return manager
      }
      loading = task
    }
    do {
      let loaded = try await task.value
      guard current == generation else { return }
      loading = nil
      manager = loaded
    } catch {
      // A failed load is not kept, so the next `prepare()` tries again.
      if current == generation { loading = nil }
      throw error
    }
  }

  public enum Failure: LocalizedError {
    case notLoaded
    case incompleteDownload

    public var errorDescription: String? {
      switch self {
      case .notLoaded: "Kokoro has not loaded yet."
      case .incompleteDownload:
        "The download finished without every Kokoro file in place. Try again."
      }
    }
  }

  /// `sentence` read aloud in `voice`, as `sampleRate` mono samples.
  ///
  /// `split` cuts the sentence's phonemes into pieces Kokoro takes in one call, which is
  /// `PhonemeSplit.pieces` from ArmadaSupervisor, where it is tested. It is handed in rather than
  /// linked: this framework linking that package as well as the app would put it in two images.
  public func samples(
    for sentence: String, voice: String = KokoroSynthesizer.voice,
    split: @Sendable (String) -> [String]
  ) async throws -> [Float] {
    guard let manager else { throw Failure.notLoaded }
    let phonemes = try await manager.phonemes(for: sentence)
    var samples: [Float] = []
    for piece in split(phonemes) {
      try Task.checkCancellation()
      samples += try await manager.synthesizeFromPhonemesDetailed(piece, voice: voice).samples
    }
    return samples
  }

  /// Drop the loaded model, for when voice is switched off.
  public func unload() async {
    generation += 1
    loading = nil
    let manager = self.manager
    self.manager = nil
    await manager?.cleanup()
  }

  /// Fetch Kokoro from huggingface.co into FluidAudio's shared folder, reporting 0…1.
  ///
  /// Only when the person presses Download, and on the same terms as
  /// `ParakeetRecognizer.download`: the host pinned in code, Hugging Face tokens removed from
  /// this process, offline mode back on however it ends. Three file sets: the model and voice,
  /// the G2P model, and the lexicon.
  public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    ModelRegistry.baseURL = "https://huggingface.co"
    for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN"] {
      unsetenv(name)
    }
    ModelHub.offlineMode = false
    defer { ModelHub.offlineMode = true }
    // Weighted by size: the model is about 82 MB, the G2P model 2 MB and the lexicon 10 MB.
    try await KokoroAneResourceDownloader.ensureModels(variant: .english) {
      progress($0.fractionCompleted * 0.85)
    }
    try await KokoroAneResourceDownloader.ensureG2PAssets {
      progress(0.85 + $0.fractionCompleted * 0.03)
    }
    _ = await KokoroAneResourceDownloader.ensureEnglishLexicon()
    progress(1)
    guard isInstalled else { throw Failure.incompleteDownload }
  }
}
