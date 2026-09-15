import ArmadaSpeech
import SwiftUI

/// Settings ▸ Voice ▸ Recognition: which recognizer hears you, and the download that switches to
/// Parakeet.
///
/// The footer says where the download comes from and when, because it is Armada's second
/// network request after the update check, and says that a copy another app already fetched is
/// used instead, because that is the question someone with Cadence or MacWhisper installed asks.
struct VoiceRecognitionSection: View {
  @State private var store = SpeechModelStore.recognizer

  var body: some View {
    Section {
      switch store.state {
      case .installed:
        LabeledContent("Recognizer", value: "Parakeet v3, on this Mac")
        Text(Self.location)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      case .missing, .failed:
        LabeledContent("Recognizer", value: "Apple dictation")
        Button("Download Parakeet v3 (about 480 MB)") { store.download() }
          .disabled(store.isOtherDownloading)
        if case .failed(let message) = store.state {
          Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      case .downloading(let fraction):
        LabeledContent("Downloading Parakeet v3") {
          HStack(spacing: 8) {
            ProgressView(value: fraction)
              .frame(width: 160)
            Button("Cancel") { store.cancelDownload() }
              .buttonStyle(.borderless)
          }
        }
      }
    } header: {
      Text("Recognition")
    } footer: {
      Text(
        store.isInstalled
          ? "Parakeet recognises 25 European languages and works out which one you are speaking, question by question, even when you mix them. It runs on this Mac, from the copy in FluidAudio's shared models folder."
          : "Until Parakeet is here, voice uses Apple's dictation in your system language, which hears one language per question. The download comes from huggingface.co, only when you press the button, and sends no identifier with it. If another app has already put Parakeet in FluidAudio's shared models folder, Armada uses that copy instead."
      )
    }
    .onAppear { store.refresh() }
  }

  private static var location: String {
    (ParakeetRecognizer.modelDirectory.path(percentEncoded: false) as NSString)
      .abbreviatingWithTildeInPath
  }
}
