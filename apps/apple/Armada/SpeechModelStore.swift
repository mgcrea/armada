import ArmadaSpeech
import Foundation
import Observation

/// Whether a speech model is on this Mac, and the download that puts it there when it is not. Two
/// of them: Parakeet, which hears the question, and Kokoro, which can read the answer.
///
/// **A model is looked for, not owned.** Both live in FluidAudio's shared folders, so a copy
/// another app already downloaded is used as it is. Until Parakeet is there, voice listens with
/// Apple's dictation, which hears one language per question; until Kokoro is, and loaded, replies
/// are read in a system voice.
///
/// **The downloads are Armada's second network exception** after the update check, and like it,
/// nothing starts them but a button in Settings ▸ Voice. See `ParakeetRecognizer.download` and
/// `KokoroSynthesizer.download` for what they send.
@MainActor @Observable
final class SpeechModelStore {
  enum State: Equatable {
    case installed
    case missing
    case downloading(Double)
    case failed(String)
  }

  enum Model {
    case parakeet
    case kokoro
  }

  static let recognizer = SpeechModelStore(.parakeet)
  static let voice = SpeechModelStore(.kokoro)

  let model: Model
  private(set) var state: State = .missing
  /// In memory and ready to use, so a caller can choose it without waiting.
  private(set) var isLoaded = false
  private(set) var isPreparing = false
  /// Why the last load failed. The model stays unused, and a fresh download is the fix.
  private(set) var loadError: String?

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var loadGeneration = 0

  private init(_ model: Model) {
    self.model = model
    state = onDisk ? .installed : .missing
  }

  var isInstalled: Bool { state == .installed }

  var isSupported: Bool {
    switch model {
    case .parakeet: true
    case .kokoro: KokoroSynthesizer.isSupported
    }
  }

  /// The other model is downloading. FluidAudio's offline switch is one for the whole process, so
  /// the download that finishes first would turn it back on under the other.
  var isOtherDownloading: Bool {
    let other = model == .parakeet ? Self.voice : Self.recognizer
    if case .downloading = other.state { return true }
    return false
  }

  var directory: URL {
    switch model {
    case .parakeet: ParakeetRecognizer.modelDirectory
    case .kokoro: KokoroSynthesizer.modelDirectory
    }
  }

  private var onDisk: Bool {
    switch model {
    case .parakeet: ParakeetRecognizer.isInstalled
    case .kokoro: KokoroSynthesizer.isInstalled
    }
  }

  /// Load the model before it is needed rather than on first use: the very first load on a Mac
  /// compiles it for the Neural Engine, 12.8 s measured for Parakeet and about 20 s for Kokoro,
  /// and a question should never wait on that.
  func warmUp() {
    refresh()
    guard state == .installed, isSupported, !isLoaded, !isPreparing else { return }
    isPreparing = true
    loadError = nil
    let generation = loadGeneration
    Task { [weak self] in
      guard let self else { return }
      do {
        try await prepare()
        guard generation == loadGeneration else { return }
        isLoaded = true
      } catch {
        guard generation == loadGeneration else { return }
        loadError = error.localizedDescription
      }
      isPreparing = false
    }
  }

  /// Drop the loaded model as voice is switched off.
  func release() {
    loadGeneration += 1
    isLoaded = false
    isPreparing = false
    let model = model
    Task {
      switch model {
      case .parakeet: await ParakeetRecognizer.shared.unload()
      case .kokoro: await KokoroSynthesizer.shared.unload()
      }
    }
  }

  private func prepare() async throws {
    switch model {
    case .parakeet: try await ParakeetRecognizer.shared.prepare()
    case .kokoro: try await KokoroSynthesizer.shared.prepare()
    }
  }

  /// Look again, for a model another app put there while Armada was running.
  func refresh() {
    if case .downloading = state { return }
    state = onDisk ? .installed : .missing
  }

  func download() {
    guard task == nil, !isOtherDownloading else { return }
    state = .downloading(0)
    // Newest value only: a 480 MB transfer reports progress thousands of times, and a bar
    // cannot draw the values in between anyway. Cadence measured the flood this avoids.
    let (updates, continuation) = AsyncStream<Double>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let progress = Task { [weak self] in
      for await fraction in updates {
        guard let self, case .downloading = state else { continue }
        state = .downloading(fraction)
      }
    }
    let model = model
    task = Task { [weak self] in
      defer {
        continuation.finish()
        progress.cancel()
      }
      do {
        switch model {
        case .parakeet: try await ParakeetRecognizer.download { continuation.yield($0) }
        case .kokoro: try await KokoroSynthesizer.download { continuation.yield($0) }
        }
        guard let self else { return }
        state = .installed
        loadError = nil
        task = nil
        VoiceController.shared.sync()
      } catch {
        guard let self else { return }
        state = Task.isCancelled ? .missing : .failed(error.localizedDescription)
        task = nil
      }
    }
  }

  func cancelDownload() {
    task?.cancel()
    task = nil
    state = onDisk ? .installed : .missing
  }
}
