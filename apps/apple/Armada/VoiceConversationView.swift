import AppKit
import SwiftUI

/// One spoken question and what came back.
struct VoiceExchange: Identifiable, Equatable {
  let id = UUID()
  let question: String
  var reply = ""
  /// Why no complete reply came, when one didn't.
  var problem: String?
  /// A press stopped the reply before it finished.
  var wasCutOff = false
}

/// The main window's Voice pane: every question of the current conversation and its whole
/// reply, which the card has room for only the end of.
///
/// Opened by a click on the card, through `MainWindowRoute`, or from the sidebar while voice is
/// on. Read from `VoiceController`, which keeps it in memory, rather than from the
/// conversation's transcript: that is JSONL under the account's `projects` folder, and nothing
/// but these two strings a turn is worth showing from it.
struct VoiceConversationView: View {
  private let voice = VoiceController.shared

  var body: some View {
    VStack(spacing: 0) {
      conversation
      Divider()
      footer
    }
    .navigationTitle("Voice")
  }

  @ViewBuilder private var conversation: some View {
    Group {
      if voice.exchanges.isEmpty {
        ContentUnavailableView(
          "No Questions Yet", systemImage: "waveform",
          description: Text(
            "Press \(VoiceShortcut.Chord.stored.display) and ask Armada something. This conversation's questions and replies show up here."
          ))
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
              ForEach(voice.exchanges) { exchange in
                ExchangeRow(exchange: exchange).id(exchange.id)
              }
            }
            .padding(20)
          }
          .onAppear { scrollToEnd(proxy) }
          .onChange(of: voice.exchanges.last?.reply) { scrollToEnd(proxy) }
          .onChange(of: voice.exchanges.count) { scrollToEnd(proxy) }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Not a toolbar: the main window is a hosted `NSWindow` with no `NSToolbar`. See `UsageStrip`.
  private var footer: some View {
    HStack {
      Text("Kept until you start a new conversation, switch accounts or quit Armada.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 12)
      Button("Start a New Conversation") { voice.startNewConversation() }
        .help("The next question starts a new conversation")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private func scrollToEnd(_ proxy: ScrollViewProxy) {
    guard let last = voice.exchanges.last else { return }
    proxy.scrollTo(last.id, anchor: .bottom)
  }
}

private struct ExchangeRow: View {
  let exchange: VoiceExchange
  @State private var copied = false

  private var reply: String { exchange.reply.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(exchange.question)
        .font(.body.weight(.semibold))
        .textSelection(.enabled)
      if !reply.isEmpty {
        HStack(alignment: .top, spacing: 8) {
          Text(reply)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reply, forType: .string)
            copied = true
            Task {
              try? await Task.sleep(for: .seconds(1.5))
              copied = false
            }
          } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
              .contentTransition(.symbolEffect(.replace))
          }
          .buttonStyle(.borderless)
          .help("Copy this reply")
          .accessibilityLabel(copied ? "Copied" : "Copy reply")
        }
      }
      if let problem = exchange.problem {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
      } else if exchange.wasCutOff {
        Text("Stopped before the reply finished.")
          .foregroundStyle(.secondary)
          .font(.callout)
      }
    }
  }
}
