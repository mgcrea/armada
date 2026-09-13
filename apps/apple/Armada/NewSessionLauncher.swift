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
