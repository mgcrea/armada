import SwiftUI

/// Start a session on the account whose pane is showing, from the window's toolbar.
///
/// Each account pane adds it itself, so it is absent on Usage, Projects and Voice, where
/// there is no account to start one on. Everything that applies whatever the pane shows,
/// the sidebar toggle and Add Account, is `MainWindowView`'s.
struct NewSessionToolbarItem: ToolbarContent {
  let agent: NewSession.Agent
  /// Where the folder picker opens: the folder this account ran in last.
  let suggestion: URL?

  var body: some ToolbarContent {
    // Its own capsule, apart from the session actions a pane puts before it. Without the
    // spacer, a plain button beside it shares one: on Codex, Fork and New Session read as a
    // pair.
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      NewSessionButton(agent: agent, suggestion: suggestion)
    }
  }
}

/// The control itself.
///
/// **In the toolbar rather than the account's overview, where it was a section.** The
/// overview is what the detail half shows while no session is selected, so the moment one
/// was, the control that starts another went with it. Here it stays whatever is selected,
/// and ⌘N rides on it: Armada is `LSUIElement`, with no File menu to hold the shortcut.
///
/// **It once listed the six folders the account ran in last**, one click each, above a
/// folder picker and the supervisor button. The list took the top of the overview for
/// something the terminal already does as fast, so it made way for the account's usage; a
/// folder's own sessions still offer "New Session in <project>" on their right-click, and
/// the Projects pane starts one in any saved project.
///
/// **A split button on Claude Code**: a click picks a folder, and the menu beside it adds
/// the supervisor. Codex and Grok Build have no supervisor, and a menu of one item is a
/// button with an extra click, so they get the button.
private struct NewSessionButton: View {
  let agent: NewSession.Agent
  let suggestion: URL?

  @State private var launcher = NewSessionLauncher.shared
  @State private var mcp = MCPServerController.shared

  var body: some View {
    control
      .help(help)
      .keyboardShortcut("n", modifiers: .command)
  }

  @ViewBuilder private var control: some View {
    // Claude only: the supervisor is a Claude Code session, and the home folder because it
    // belongs to no one project. Settings ▸ Supervisor offers a folder picker.
    if case .claude(let folder) = agent {
      Menu {
        Button("From Folder…") { chooseFolder() }
        // The reason in the item's own name, because a disabled menu item never shows its
        // tooltip, and the overview's footer that used to say it is gone.
        Button(supervisorTitle) {
          launcher.startSupervisor(
            on: folder, in: FileManager.default.homeDirectoryForCurrentUser)
        }
        .disabled(mcp.runningPort == nil)
      } label: {
        label
      } primaryAction: {
        chooseFolder()
      }
    } else {
      Button {
        chooseFolder()
      } label: {
        label
      }
    }
  }

  private var supervisorTitle: String {
    mcp.runningPort == nil ? "Supervisor Session (needs the MCP server)" : "Supervisor Session"
  }

  private var label: some View {
    Label("New Session", systemImage: "plus")
  }

  private func chooseFolder() {
    launcher.chooseFolder(for: agent, near: suggestion)
  }

  /// Names the terminal, because that is a setting somebody chose once and will not
  /// remember, and it is the whole of what this control does that is not obvious.
  private var help: String {
    launcher.opensInVSCode(agent)
      ? "New Session: opens a \(agent.vendorName) tab in the chosen folder's \(VSCodeLaunch.name) window, or a new window on this account."
      : "New Session: opens \(launcher.terminal.name) with \(agent.commandName) running in the chosen folder, on this account."
  }
}
