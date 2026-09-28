import SwiftUI

/// The selected Claude Code session's actions, in the window's toolbar: Focus and Read
/// Transcript, then Fork and Continue on.
///
/// **In the toolbar as well as the session's details, not instead.** The details keep every
/// button with the sentence under it saying what it is about to do (a new session id, turns
/// that stay counted here), and with a session selected those sentences are on screen right
/// below. The toolbar is the one place the actions stay put whichever pane layout, scroll
/// position or selection the details are in. Focus and Read Transcript went first as the
/// ones used most; Fork and Continue on followed once the details were kept beside them.
///
/// **Close is not here.** An idle session closes on one click with no question asked, and in
/// a window's toolbar an `xmark.circle` reads as closing the window, a few points from
/// Focus and Fork. It stays last in the details under its own warning, on the row's
/// right-click and in the menu bar popover.
///
/// **Disabled rather than absent** with no session selected, or several: a toolbar that
/// gained and lost buttons as the selection changed would move under the pointer. The one
/// exception is Continue on with no other Claude account, which is gone for good rather
/// than for this row, as it is in the details. ⌘O, ⌘T and ⌘D ride on the buttons, because
/// Armada is `LSUIElement` and has no menu bar to hold them. Several selected sessions have
/// their own actions in the details (`SessionSelectionDetail`).
///
/// Focus and Read Transcript are Claude Code only. Codex and Grok Build have no Focus (see
/// `CodexPaneView`), and `TranscriptLog` parses Claude Code's JSONL: a Codex rollout has
/// other entry shapes, and pointing the window at one would render a session that had never
/// been prompted. `TranscriptTail` already carries the vendor split, and is the shape to
/// copy when the window grows a second reader. Their panes add `ForkToolbarItem` alone.
struct SessionToolbarItems: ToolbarContent {
  /// The one selected session, or nil for none or several.
  let session: Session?
  let account: Account

  var body: some ToolbarContent {
    // Two groups: getting back to the session, then starting something from it. The spacer
    // is what keeps them two: adjacent groups otherwise share one glass capsule.
    ToolbarItemGroup(placement: .primaryAction) {
      FocusToolbarButton(session: session)
      TranscriptToolbarButton(session: session)
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItemGroup(placement: .primaryAction) {
      ForkToolbarButton(availability: session.map { .claude($0, in: account) })
      HandoverToolbarButton(session: session, account: account)
    }
  }
}

/// Fork for a Codex or Grok Build pane, which has no other session action to put beside it.
struct ForkToolbarItem: ToolbarContent {
  /// Nil with no session selected.
  let availability: ForkAvailability?

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      ForkToolbarButton(availability: availability)
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

/// "Fork Session", the details' `ForkButton` as a glyph. Its note is the tooltip, and a row
/// that cannot fork says why there.
private struct ForkToolbarButton: View {
  let availability: ForkAvailability?

  var body: some View {
    Button {
      guard let target = availability?.target else { return }
      NewSessionLauncher.shared.start(target.agent, in: target.project, start: target.start)
    } label: {
      Label("Fork Session", systemImage: "arrow.triangle.branch")
    }
    .help(help)
    .disabled(availability?.target == nil)
    .keyboardShortcut("d", modifiers: .command)
  }

  private var help: String {
    switch availability {
    case nil: "Fork the selected session"
    case .unavailable(let reason): reason
    case .available(let target): "Fork Session (⌘D). \(target.note)"
    }
  }
}

/// "Continue on <account>", or a menu of accounts when there are several, as the details'
/// `HandoverButton` has it.
///
/// **Drawn from the account list, not from the row**, so it keeps its shape with nothing
/// selected: whether there is another account to continue on does not depend on which
/// session is. No shortcut, because what it does changes with the accounts there are.
private struct HandoverToolbarButton: View {
  let session: Session?
  let account: Account

  @State private var accounts = Accounts.shared
  /// Watched, so the label follows Settings the way the details' does.
  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var copiesOnly = false

  var body: some View {
    let others = accounts.all.filter { $0.id != account.id }
    let availability = session.map {
      HandoverAvailability.claude($0, in: account, among: accounts.all)
    }
    let targets = availability?.targets ?? []
    if let only = others.first, others.count == 1 {
      Button {
        guard let target = targets.first else { return }
        NewSessionLauncher.shared.handOver(target)
      } label: {
        Label(
          copiesOnly ? "Copy to \(only.displayName)" : "Continue on \(only.displayName)",
          systemImage: "arrow.right.arrow.left")
      }
      .help(help(availability, note: targets.first?.note))
      .disabled(targets.isEmpty)
    } else if !others.isEmpty {
      Menu {
        HandoverMenuItems(targets: targets)
      } label: {
        Label(
          copiesOnly ? "Copy to Another Account" : "Continue on Another Account",
          systemImage: "arrow.right.arrow.left")
      }
      .help(help(availability, note: nil))
      .disabled(targets.isEmpty)
    }
  }

  private func help(_ availability: HandoverAvailability?, note: String?) -> String {
    switch availability {
    case nil:
      copiesOnly
        ? "Copy the selected session to another account"
        : "Continue the selected session on another account"
    case .unavailable(let reason): reason
    case .available, .noOtherAccount:
      note
        ?? "Pick an account. The session's details say what happens to the copy and to this session."
    }
  }
}
