import AVFoundation
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
  @State private var shortcut = VoiceShortcut.shared
  @State private var accounts = Accounts.shared
  @State private var server = MCPServerController.shared
  @State private var monitor = EntitlementMonitor.shared
  @State private var chord = VoiceShortcut.Chord.stored
  /// Its own synthesizer, so a preview never cuts into an answer being spoken.
  @State private var preview = Speaker()

  private static let sample = "Two sessions need you. Bastion is waiting for your approval."

  var body: some View {
    Form {
      voiceSection
      VoiceRecognitionSection()
      shortcutSection
      answeringSection
    }
    .formStyle(.grouped)
    .navigationTitle("Voice")
    .onDisappear { preview.stop() }
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
      Toggle("Speak replies", isOn: $speaks)
      HStack {
        Picker("Voice", selection: $voiceID) {
          Text("System default").tag("")
          ForEach(Speaker.voices, id: \.identifier) { voice in
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
      .disabled(!speaks)
      Button("Start a New Conversation") {
        VoiceController.shared.startNewConversation()
      }
    } header: {
      Text("Answering")
    } footer: {
      Text(
        "A follow-up question continues the same conversation until you start a new one. Each question counts toward that account's plan, like any prompt."
      )
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
