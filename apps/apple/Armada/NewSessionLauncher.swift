import AppKit
import SwiftUI
import os

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

  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "new-session")

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

  func start(
    _ agent: NewSession.Agent, in project: URL, start: NewSession.Start = .fresh
  ) {
    trustIfSaved(agent, in: project)
    if let message = NewSession.start(
      agent, in: project, terminal: terminal, start: start,
      completion: { [weak self] message in self?.failure = message })
    {
      failure = message
    }
  }

  /// The same launch, from the menu bar panel, which has no alert of its own.
  ///
  /// `newSessionFailureAlert()` is attached by panes, and the popover is not a pane —
  /// so a launch that fails from there would set `failure` with nothing on screen to
  /// show it, which is precisely the button-that-does-nothing `NewSession` exists to
  /// prevent. Opening the main window gives the alert somewhere to land.
  ///
  /// Only the synchronous half is caught here. A LaunchServices failure arrives after
  /// this returns and shows the next time a pane is on screen, which is the same
  /// deferral every other caller already lives with.
  func startFromMenuBar(
    _ agent: NewSession.Agent, in project: URL, start: NewSession.Start = .fresh
  ) {
    self.start(agent, in: project, start: start)
    if failure != nil { AppDelegate.shared?.showMain() }
  }

  /// When an agent last started a session through `armada_start_session`, for its throttle.
  private(set) var lastAgentLaunchAt: Date?

  /// A launch an agent asked for, through `SessionStarterBridge`.
  ///
  /// **Returns the failure rather than setting `failure`.** Nobody clicked anything, so an
  /// alert would arrive out of nowhere; the sentence goes back to the agent instead. Only the
  /// asynchronous LaunchServices half still lands in `failure`, because by then the tool has
  /// answered and a pane is the one place left to say so.
  func startForAgent(_ agent: NewSession.Agent, in project: URL, prompt: String?) -> String? {
    trustIfSaved(agent, in: project)
    let message = NewSession.start(
      agent, in: project, terminal: terminal, prompt: prompt,
      completion: { [weak self] message in self?.failure = message })
    if message == nil { lastAgentLaunchAt = Date() }
    return message
  }

  /// Start a Claude Code session with Armada's MCP server attached, which is all a
  /// supervisor is. See `NewSession.Supervisor` and `SupervisorPane`.
  ///
  /// Refuses rather than starting a plain session when the server is off: a supervisor with
  /// no server answers every question about the fleet with a connection error, which is a
  /// worse way to learn the switch is off than this sentence.
  func startSupervisor(on folder: ClaudeConfigFolder, in project: URL) {
    let controller = MCPServerController.shared
    guard let port = controller.runningPort else {
      failure =
        "Turn on the MCP server in Settings ▸ Supervisor first. The supervisor reads your sessions through it."
      return
    }
    let token = controller.token
    guard !token.isEmpty else {
      failure =
        "Armada could not read the MCP server's token from the keychain"
        + (controller.tokenError.map { ": \($0)" } ?? ".")
      return
    }
    trustIfSaved(.claude(folder), in: project)
    if let message = NewSession.start(
      .claude(folder), in: project, terminal: terminal,
      supervisor: NewSession.Supervisor(port: port, token: token),
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

  /// Mark a saved project trusted on the Claude account about to open it, so the session
  /// starts on its prompt rather than on Claude Code's folder trust dialog. See `ClaudeTrust`.
  ///
  /// **Saved projects only, matched on the folder itself.** Saving a folder is the decision
  /// the dialog asks for; a folder picked for one launch is not, and neither is a subfolder
  /// of a saved project. Every launch rather than once when the project is added, so the
  /// projects saved before this existed are covered, and so is a project moved to another
  /// account. A write that is skipped is logged and nothing more: the dialog then asks, as it
  /// always did.
  private func trustIfSaved(_ agent: NewSession.Agent, in project: URL) {
    guard case .claude(let folder) = agent,
      let saved = ProjectStore.shared.project(at: project.path(percentEncoded: false))
    else { return }
    if case .skipped(let reason) = ClaudeTrust.ensure(
      folder: saved.path, configFile: folder.usageJSON)
    {
      Self.logger.info("trust not written: \(reason, privacy: .public)")
    }
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
