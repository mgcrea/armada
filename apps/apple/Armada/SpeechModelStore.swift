import ArmadaSpeech
import Foundation
import Observation

/// Whether Parakeet is on this Mac, and the download that puts it there when it is not.
///
/// **The model is looked for, not owned.** It lives in FluidAudio's shared folder, so a copy
/// another app already downloaded is used as it is. Until one is there, voice listens with
/// Apple's dictation instead, which hears one language per question.
///
/// **The download is Armada's second network exception** after the update check, and like it,
/// nothing starts it but a button: Settings ▸ Voice ▸ Download. See `ParakeetRecognizer.download`
/// for what it sends.
@MainActor @Observable
final class SpeechModelStore {
  enum State: Equatable {
    case installed
    case missing
    case downloading(Double)
    case failed(String)
  }

  static let shared = SpeechModelStore()

  private(set) var state: State = ParakeetRecognizer.isInstalled ? .installed : .missing

  @ObservationIgnored private var task: Task<Void, Never>?

  private init() {}

  var isInstalled: Bool { state == .installed }

  /// Load Parakeet as voice is switched on rather than on the first press: the very first load on
  /// a Mac compiles the model for the Neural Engine, which took 12.8 s when measured, and a
  /// question should never wait on that.
  func warmUp() {
    refresh()
    guard state == .installed else { return }
    Task { try? await ParakeetRecognizer.shared.prepare() }
  }

  /// Drop the loaded model as voice is switched off.
  func release() {
    Task { await ParakeetRecognizer.shared.unload() }
  }

  /// Look again, for a model another app put there while Armada was running.
  func refresh() {
    if case .downloading = state { return }
    state = ParakeetRecognizer.isInstalled ? .installed : .missing
  }

  func download() {
    guard task == nil else { return }
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
    task = Task { [weak self] in
      defer {
        continuation.finish()
        progress.cancel()
      }
      do {
        try await ParakeetRecognizer.download { continuation.yield($0) }
        guard let self else { return }
        state = .installed
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
    state = ParakeetRecognizer.isInstalled ? .installed : .missing
  }
}
