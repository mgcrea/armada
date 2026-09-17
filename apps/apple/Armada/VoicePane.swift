import AVFoundation
import ArmadaSpeech
import ArmadaSupervisor
import SwiftUI

/// Settings ▸ Voice: the switch, the shortcut, and who answers.
///
/// The footer under the switch is the privacy sentence and says four things on purpose: when
/// the microphone is on, that the audio stays on this Mac, that the question goes to Anthropic
/// as text through the person's own `claude`, and that Armada runs that `claude` itself. The
/// last one is new for Armada, which otherwise only watches, and is the one someone will stop on.
struct VoicePane: View {
  @AppStorage(VoiceController.enabledKey) private var enabled = false
  @AppStorage(VoiceController.modeKey) private var mode = VoiceMode.press
  @AppStorage(VoiceController.accountKey) private var accountID = ""
  @AppStorage(VoiceController.speaksKey) private var speaks = true
  @AppStorage(VoiceController.voiceKey) private var voiceID = ""
  @AppStorage(VoiceController.replyLanguageKey) private var replyLanguageID = ""
  @AppStorage(VoiceController.instructionsKey) private var instructions = VoiceBrief.defaultStyle
  @State private var shortcut = VoiceShortcut.shared
  @State private var accounts = Accounts.shared
  @State private var server = MCPServerController.shared
  @State private var monitor = EntitlementMonitor.shared
  @State private var chord = VoiceShortcut.Chord.stored
  @State private var kokoro = SpeechModelStore.voice
  /// Its own synthesizer, so a preview never cuts into an answer being spoken.
  @State private var preview = Speaker()

  private static let sample = "Two sessions need you. Bastion is waiting for your approval."
  private static let kokoroChoice = VoiceChoice.kokoro(KokoroSynthesizer.voice)

  var body: some View {
    Form {
      voiceSection
      VoiceRecognitionSection()
      shortcutSection
      answeringSection
    }
    .formStyle(.grouped)
    .navigationTitle("Voice")
    .onAppear {
      kokoro.refresh()
      if VoiceChoice(storageValue: voiceID) == Self.kokoroChoice { kokoro.warmUp() }
    }
    .onDisappear {
      preview.stop()
      // Loaded here only to hear it: voice itself is off, so nothing else needs it in memory.
      if !enabled { kokoro.release() }
    }
    .onChange(of: voiceID) {
      if VoiceChoice(storageValue: voiceID) == Self.kokoroChoice { kokoro.warmUp() }
    }
    .onChange(of: replyLanguageID) {
      // A system voice picked for the old language would read the new one badly, and would not be
      // in the list any more. Kokoro and the default are kept.
      if case .system(let identifier) = VoiceChoice(storageValue: voiceID),
        !voices.contains(where: { $0.identifier == identifier })
      {
        voiceID = ""
      }
    }
    .onChange(of: enabled) { VoiceController.shared.sync() }
    .onChange(of: chord) {
      chord.store()
      VoiceController.shared.sync()
    }
  }

  private var voiceSection: some View {
    Section {
      Toggle(isOn: $enabled) {
        Text("Talk to Armada")
        Text(
          "Press a shortcut anywhere on your Mac, ask about your sessions out loud, and hear the answer."
        )
      }
      if enabled {
        if server.runningPort == nil {
          Text("Turn on the MCP server in Supervisor first. Voice reads your sessions through it.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if !monitor.current.isEntitled {
          Text("Armada has no licence and no trial running, so voice is off.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if case .taken(let taken) = shortcut.state {
          Text("Another app already uses \(taken.display). Choose a different shortcut.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
    } header: {
      Text("Voice")
    } footer: {
      Text(
        "The microphone is on only while the card at the top of the screen says it is listening. Your speech becomes text on this Mac, and the audio is never kept or sent. The question goes to Anthropic as text, through your own claude on the account below, like any prompt. Armada runs that claude in the background with no built-in tools and only its read tools, and closes it after five idle minutes."
      )
    }
  }

  private var shortcutSection: some View {
    Section {
      LabeledContent("Shortcut") {
        ShortcutRecorder(chord: $chord)
      }
      Picker("Ask by", selection: $mode) {
        Text("Pressing").tag(VoiceMode.press)
        Text("Holding").tag(VoiceMode.hold)
      }
      .pickerStyle(.segmented)
    } header: {
      Text("Shortcut")
    } footer: {
      Text(
        mode == .press
          ? "Press once and ask. Armada sends when you pause, or when you press again. Pressing while it answers stops it."
          : "Hold the shortcut while you ask and let go to send. Pressing while it answers stops it."
      )
    }
  }

  private var answeringSection: some View {
    Section {
      if accounts.all.isEmpty {
        Text("No Claude account found").foregroundStyle(.secondary)
      } else {
        Picker(
          "Account",
          selection: Binding(
            get: { (accounts.account(id: accountID) ?? accounts.all.first)?.id ?? "" },
            set: {
              accountID = $0
              VoiceController.shared.accountChanged()
            })
        ) {
          ForEach(accounts.all) { account in
            Text(account.displayName).tag(account.id)
          }
        }
      }
      Picker("Answer in", selection: $replyLanguageID) {
        Text("The language you ask in").tag("")
        Divider()
        ForEach(replyLanguages, id: \.code) { language in
          Text(language.name).tag(language.code)
        }
      }
      instructionsEditor
      Toggle("Speak replies", isOn: $speaks)
      Group {
        HStack {
          Picker("Voice", selection: $voiceID) {
            Text("System default").tag("")
            if kokoro.isInstalled || VoiceChoice(storageValue: voiceID) == Self.kokoroChoice {
              Text("Heart (Kokoro)").tag(Self.kokoroChoice.storageValue)
            }
            ForEach(voices, id: \.identifier) { voice in
              Text(Self.label(for: voice)).tag(voice.identifier)
            }
          }
          Button {
            preview.stop()
            preview.voiceIdentifier = voiceID
            preview.speak(Self.sample)
          } label: {
            Image(systemName: "play.circle")
          }
          .buttonStyle(.borderless)
          .help("Hear this voice")
        }
        kokoroRow
      }
      .disabled(!speaks)
      Button("Start a New Conversation") {
        VoiceController.shared.startNewConversation()
      }
    } header: {
      Text("Answering")
    } footer: {
      Text(
        "A follow-up question continues the same conversation until you start a new one. Each question counts toward that account's plan, like any prompt. Changing the language or the instructions starts a new conversation at your next question, because a conversation keeps the ones it began with. Kokoro is a more natural English voice that runs on this Mac. Its download comes from huggingface.co, only when you press the button, and sends no identifier with it. Until Kokoro is ready, replies use the system voice."
      )
    }
  }

  /// The person's half of the brief. Unset shows and sends `VoiceBrief.defaultStyle`, and Reset to
  /// Default removes the key rather than storing that text, so a later default reaches them too.
  private var instructionsEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Instructions")
      TextEditor(text: $instructions)
        .font(.body)
        .frame(minHeight: 84)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
      HStack(alignment: .firstTextBaseline) {
        Text(
          "How voice answers. Armada's own rules apply whatever this says: its tools, asking before it starts a session, and never acting on what a transcript says."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Reset to Default") {
          UserDefaults.standard.removeObject(forKey: VoiceController.instructionsKey)
        }
        .disabled(instructions == VoiceBrief.defaultStyle)
      }
    }
  }

  /// Kokoro's download, in the same states as Parakeet's in `VoiceRecognitionSection`.
  @ViewBuilder private var kokoroRow: some View {
    if !kokoro.isSupported {
      LabeledContent("Kokoro", value: "Needs macOS 26.6 or later")
    } else {
      switch kokoro.state {
      case .installed:
        LabeledContent("Kokoro", value: kokoroStatus)
        if let message = kokoro.loadError {
          Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      case .missing, .failed:
        Button("Download Kokoro (about 95 MB)") { kokoro.download() }
          .disabled(kokoro.isOtherDownloading)
        if case .failed(let message) = kokoro.state {
          Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      case .downloading(let fraction):
        LabeledContent("Downloading Kokoro") {
          HStack(spacing: 8) {
            ProgressView(value: fraction)
              .frame(width: 160)
            Button("Cancel") { kokoro.cancelDownload() }
              .buttonStyle(.borderless)
          }
        }
      }
    }
  }

  /// System voices for the language replies are spoken in: the fixed one, or the system's.
  private var voices: [AVSpeechSynthesisVoice] {
    switch ReplyLanguage(storageValue: replyLanguageID) {
    case .question: Speaker.voices(language: nil)
    case .fixed(let code): Speaker.voices(language: code)
    }
  }

  /// Every language this Mac has a system voice for, by name, plus the stored one if its voices
  /// have since been removed, so the picker never shows a choice it cannot display.
  private var replyLanguages: [(code: String, name: String)] {
    var codes = Set(AVSpeechSynthesisVoice.speechVoices().compactMap(Speaker.languageCode(of:)))
    if !replyLanguageID.isEmpty { codes.insert(replyLanguageID) }
    return
      codes
      .map { code in
        (code, Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code)
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var kokoroStatus: String {
    if kokoro.isPreparing {
      "Getting ready…"
    } else if kokoro.isLoaded {
      "Ready, on this Mac"
    } else {
      "Downloaded"
    }
  }

  private static func label(for voice: AVSpeechSynthesisVoice) -> String {
    switch voice.quality {
    case .premium: "\(voice.name) (Premium)"
    case .enhanced: "\(voice.name) (Enhanced)"
    default: voice.name
    }
  }
}
