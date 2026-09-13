import AppKit
import SwiftUI

/// Starting a session, and saying so when it does not start.
///
/// One object rather than state in the menu, because the menu is not the only place a
/// session is started from: a row's context menu offers "New Session in <project>" too,
/// and a context menu is gone by the time an asynchronous LaunchServices failure comes
/// back. So the failure lands here and whichever pane is on screen shows it.
@MainActor
@Observable
final class NewSessionLauncher {
  static let shared = NewSessionLauncher()

  /// The last failure, until it is dismissed. Nil the rest of the time, which is
  /// almost always — a launch either opens a window or explains itself.
  var failure: String?

  /// The terminal from Settings, resolved per launch rather than held.
  ///
  /// Read straight from `UserDefaults` rather than through `@AppStorage`: this is not
  /// a view, and the value is wanted at the moment of the click rather than watched.
  var terminal: TerminalApp {
    TerminalApp.preferred(
      stored: UserDefaults.standard.string(forKey: TerminalApp.defaultsKey) ?? "")
  }

  func start(_ agent: NewSession.Agent, in project: URL) {
    if let message = NewSession.start(
      agent, in: project, terminal: terminal,
      completion: { [weak self] message in self?.failure = message })
    {
      failure = message
    }
  }

  /// Pick a folder, then start there.
  ///
  /// `runModal` rather than a sheet: Armada's windows are hosted `NSWindow`s (see
  /// `HostedWindow`), and the open panel is the one piece of UI in the app that is
  /// AppKit's to own anyway.
  func chooseFolder(for agent: NewSession.Agent, near suggestion: URL? = nil) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = suggestion
    panel.prompt = "Start Session"
    panel.message = "Choose the folder to start a \(agent.vendorName) session in."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    start(agent, in: url)
  }
}

extension View {
  /// The alert a failed launch shows, attached once per pane.
  func newSessionFailureAlert() -> some View {
    modifier(NewSessionFailureAlert())
  }
}

private struct NewSessionFailureAlert: ViewModifier {
  @State private var launcher = NewSessionLauncher.shared

  func body(content: Content) -> some View {
    content.alert(
      "Could not start a session",
      isPresented: Binding(
        get: { launcher.failure != nil },
        set: { if !$0 { launcher.failure = nil } })
    ) {
      Button("OK") { launcher.failure = nil }
    } message: {
      Text(launcher.failure ?? "")
    }
  }
}

/// "New Session", with this account's recent projects under it.
///
/// **The recents are the whole point of the control.** A folder picker alone would be
/// slower than the terminal the person already has open; a list of the ten folders
/// this account ran in last, one click each, is the thing they do not have. The picker
/// stays underneath for the eleventh.
///
/// Sits beside `SessionSortMenu` in both panes' headers, in the same accessory-bar
/// style and for the same reasons written up there: the panes are hosted windows with
/// no `NSToolbar` to put it in, and the header strip is the chrome that exists.
struct NewSessionMenu: View {
  let agent: NewSession.Agent
  let projects: [RecentProject]

  @State private var launcher = NewSessionLauncher.shared

  var body: some View {
    Menu {
      if projects.isEmpty {
        // A disabled row rather than an empty menu: on a fresh account the menu is
        // otherwise one item and no explanation of why.
        Text("No recent projects")
      } else {
        ForEach(projects) { project in
          Button(label(for: project)) {
            launcher.start(agent, in: project.url)
          }
        }
        Divider()
      }
      Button("Choose Folder…") {
        launcher.chooseFolder(for: agent, near: projects.first?.url)
      }
    } label: {
      Label("New Session", systemImage: "plus")
        .font(.caption)
    }
    .menuStyle(.button)
    .buttonStyle(.accessoryBar)
    // As on `SessionSortMenu`, and for its reason: the header's `Spacer` keeps both
    // controls hard against the trailing edge only while neither can stretch.
    .fixedSize()
    .help("Start a \(agent.vendorName) session in \(launcher.terminal.name)")
  }

  /// The folder's name, and its parent's when that is the only thing telling two rows
  /// apart.
  ///
  /// **A menu of bare folder names is what Finder's Recent Folders and Xcode's Open
  /// Recent both show**, and it is right until two of them are called `website`. The
  /// full path is not the fix — a menu item is one line and a path is the widest thing
  /// Armada could put on it — and a tooltip is not either, since a `.help` on a menu
  /// item is not something macOS reliably shows. So the parent is added, and only to
  /// the rows that need it: `website (mgcrea)` beside `website (apps)`.
  private func label(for project: RecentProject) -> String {
    guard projects.count(where: { $0.name == project.name }) > 1 else { return project.name }
    let parent = ((project.path as NSString).deletingLastPathComponent as NSString)
      .lastPathComponent
    return parent.isEmpty ? project.displayPath : "\(project.name) (\(parent))"
  }
}
