import SwiftUI

/// Focus and Read Transcript for the selected Claude Code session, in the window's toolbar.
///
/// **These two and not the rest.** They are how you get back to a session, its terminal
/// or tab or what it has been saying, which makes them the ones used most, and neither
/// changes anything, so a glyph and a tooltip are enough to say what they do. Fork,
/// Continue on and Close stay in the session's details: each is followed there by what it
/// is about to do (a new session id, turns that stay counted here, a turn stopped
/// part-way), and as a glyph beside Focus it would read as just as harmless. All of them
/// are on the row's right-click too.
///
/// **Disabled rather than absent** with no session selected, or several: a toolbar that
/// gained and lost buttons as the selection changed would move under the pointer. ⌘O and
/// ⌘T ride on them, because Armada is `LSUIElement` and has no menu bar to hold them.
///
/// Claude Code only. Codex and Grok Build have no Focus (see `CodexPaneView`), and
/// `TranscriptLog` parses Claude Code's JSONL: a Codex rollout has other entry shapes, and
/// pointing the window at one would render a session that had never been prompted.
/// `TranscriptTail` already carries the vendor split, and is the shape to copy when the
/// window grows a second reader.
struct SessionToolbarItems: ToolbarContent {
  /// The one selected session, or nil for none or several.
  let session: Session?

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      FocusToolbarButton(session: session)
      TranscriptToolbarButton(session: session)
    }
  }
}

/// "Focus in Visual Studio Code".
///
/// **The label names the application, even now that this can reach a tab.** "Go to
/// session" would promise the tab every time, and the tab is reached only for a session
/// the VS Code extension owns, in the window whose title names its folder, when that
/// window shows a tab for it or for a session beside it; everything else lands on the
/// window, or on the app. Naming the app is also the more useful label, because it tells
/// you where you are about to be sent. Why there is nothing to focus, and what Accessibility
/// would add, stay in the session's details (`FocusNote`), where there is room to say it.
private struct FocusToolbarButton: View {
  let session: Session?

  /// Resolved on a selection change rather than on every redraw: the lookup behind it
  /// reaches LaunchServices. See `SessionHostLookup`.
  @State private var host: SessionHost?

  var body: some View {
    Button {
      guard let session, let host else { return }
      FocusSession.focus(host, cwd: session.registry.cwd, session: session)
    } label: {
      Label(host.map { "Focus in \($0.name)" } ?? "Focus", systemImage: "arrow.up.forward.app")
    }
    .help(help)
    .disabled(host == nil)
    .keyboardShortcut("o", modifiers: .command)
    .task(id: session?.id) {
      host = nil
      host = session.flatMap { SessionHostLookup.host(for: $0.registry) }
    }
  }

  private var help: String {
    guard session != nil else { return "Focus the selected session in the app it runs in" }
    guard let host else { return "No window to go back to. The session's details say why." }
    return "Focus in \(host.name) (⌘O)"
  }
}

/// "Read Transcript", opening `TranscriptWindow` on the selected session.
private struct TranscriptToolbarButton: View {
  let session: Session?

  var body: some View {
    Button {
      guard let session, let transcript = session.transcript else { return }
      TranscriptWindow.shared.show(url: transcript, name: session.displayName)
    } label: {
      Label("Read Transcript", systemImage: "text.bubble")
    }
    .help(help)
    .disabled(session?.transcript == nil)
    .keyboardShortcut("t", modifiers: .command)
  }

  private var help: String {
    guard let session else { return "Read the selected session's transcript" }
    guard session.transcript != nil else {
      return "No transcript yet. A session that has never been prompted has no transcript file."
    }
    return "Read Transcript (⌘T)"
  }
}
