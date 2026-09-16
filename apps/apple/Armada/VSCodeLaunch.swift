import AppKit
import ApplicationServices
import os

/// Start a fresh Claude Code session in the project's own Visual Studio Code window, opening
/// one when there is none.
///
/// **The other way `NewSession` can go, and a narrower one.** A terminal is handed a script
/// that *is* the session; VS Code has no document to hand. What it has is the extension's
/// `vscode://anthropic.claude-code/open` link, which opens a fresh conversation tab — and VS
/// Code gives an incoming link to whichever window it last focused, not to the one showing the
/// folder. Measured 2026-09-16: `code <folder>` on a folder already open did not bring that
/// window forward, and two links sent after it both opened a tab in another project's window.
/// So the link goes only once `HostWindow` has raised the window naming the project and VS Code
/// reports that window focused, the same gate `FocusSession.reveal` sends its link through.
///
/// **What it does not do, and why each stays with the terminal.** A fork: the link's `session`
/// resumes rather than forks, which is two writers on one transcript. Codex: its extension's
/// routes are not measured. A supervisor: the link carries no `--mcp-config`. And an opening
/// message is **typed into the tab, not sent** — the extension starts no `claude` until a
/// message is sent, so the session reaches Armada's list once the person presses Return.
///
/// **The account is the hard part.** A window runs Claude Code with the environment it was
/// opened with and keeps it. A window Armada opens gets the account stated outright, as a
/// terminal script does; a window already open is used only when every VS Code window is on
/// that account. See `EditorLaunch.hostsAgree`.
@MainActor
enum VSCodeLaunch {
  static let bundleID = "com.microsoft.VSCode"
  static let name = "Visual Studio Code"
  static let defaultsKey = "armada.newSessionInVSCode"

  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "new-session")

  static var applicationURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  static var isInstalled: Bool { applicationURL != nil }

  /// Whether the person chose VS Code in Settings, and it is still here to use. An uninstalled
  /// VS Code falls back to the terminal rather than leaving the button dead.
  static var isChosen: Bool { UserDefaults.standard.bool(forKey: defaultsKey) && isInstalled }

  /// The launches this can take. Everything else goes to the terminal, as before.
  static func handles(_ agent: NewSession.Agent, start: NewSession.Start, supervisor: Bool)
    -> Bool
  {
    guard isChosen, !supervisor, start == .fresh, case .claude = agent else { return false }
    return true
  }

  /// Projects with a launch under way, so a second click while a window is still opening does
  /// not open a second window on the same folder — which would then be two windows with the
  /// same title, and a launch that refuses itself.
  private static var launching: Set<String> = []

  /// Open `project` in VS Code on `folder`'s account and start a conversation there.
  ///
  /// Returns nil when the launch is under way, or a sentence to put in front of the person —
  /// the same contract as `NewSession.start`. Most of the work waits on VS Code, so a failure
  /// found after this returns is reported through `completion`.
  static func start(
    _ folder: ClaudeConfigFolder, accountName: String, in project: URL, prompt: String?,
    completion: @escaping @MainActor (String) -> Void
  ) -> String? {
    let path = project.standardizedFileURL.path(percentEncoded: false)
    let projectName = project.standardizedFileURL.lastPathComponent
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return "\((path as NSString).abbreviatingWithTildeInPath) is not there any more."
    }
    guard HostWindow.isTrusted else {
      return
        "Starting a session in \(name) needs Accessibility, so Armada can bring \(projectName)'s window to the front before it opens the session. Allow it in Settings ▸ General, or turn off \(name) there to start in your terminal."
    }
    guard let application = applicationURL,
      let scheme = ExtensionTab.urlScheme(of: application),
      let url = EditorLaunch.openURL(scheme: scheme, prompt: prompt)
    else {
      return "Armada could not find \(name). Choose a terminal in Settings ▸ General."
    }
    guard hasClaudeExtension else {
      return
        "The Claude Code extension is not installed in \(name). Install it from the Marketplace, or turn off \(name) in Settings ▸ General to start in your terminal."
    }
    if let refusal = settingsRefusal(project: project) { return refusal }
    guard !launching.contains(path) else {
      return "Armada is still opening \(projectName) in \(name)."
    }

    let configDirectory = folder.isDefault ? nil : folder.path
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    if let running {
      let open = HostWindow.windows(inApplication: running.processIdentifier, naming: projectName)
      if open.count > 1 { return ambiguous(projectName) }
      if let window = open.first {
        guard
          EditorLaunch.hostsAgree(
            extensionHostConfigDirectories(), configDirectory: configDirectory)
        else {
          return
            "\(projectName) is already open in \(name), and at least one \(name) window runs Claude Code on another account than \(accountName). A window keeps the account it was opened on and Armada cannot tell which one that is, so it did not start the session there. Close \(projectName)'s window and try again, or turn off \(name) in Settings ▸ General to start in your terminal."
        }
        launching.insert(path)
        Task {
          defer { launching.remove(path) }
          if let failure = await deliver(
            url, to: window, of: running, application: application, projectName: projectName)
          {
            completion(failure)
          }
        }
        return nil
      }
    }

    launching.insert(path)
    Task {
      defer { launching.remove(path) }
      if let failure = await openWindow(
        path: path, projectName: projectName, configDirectory: configDirectory,
        application: application, url: url)
      {
        completion(failure)
      }
    }
    return nil
  }

  // MARK: - A window that is not open yet

  /// How long VS Code gets to show a window it was asked to open. A cold start of VS Code
  /// restoring a dozen windows is the slow case.
  private static let windowTimeout: Duration = .seconds(30)

  private static func openWindow(
    path: String, projectName: String, configDirectory: String?, application: URL, url: URL
  ) async -> String? {
    guard let shell = await loginShellEnvironment() else {
      return
        "Armada could not read your login shell's environment, which the new \(name) window needs so your tools are on its PATH. Start the session from your terminal instead."
    }
    let environment = EditorLaunch.windowEnvironment(
      shell: shell, configDirectory: configDirectory)
    let cli = application.appending(path: "Contents/Resources/app/bin/code")
    if let failure = await run(cli, arguments: ["--new-window", path], environment: environment) {
      return "\(name) could not open \(projectName): \(failure)"
    }

    let deadline = ContinuousClock.now + windowTimeout
    while ContinuousClock.now < deadline {
      if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first
      {
        let open = HostWindow.windows(inApplication: running.processIdentifier, naming: projectName)
        if open.count > 1 { return ambiguous(projectName) }
        if let window = open.first {
          return await deliver(
            url, to: window, of: running, application: application, projectName: projectName)
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return
      "\(name) did not show a window for \(projectName) within \(windowTimeout.components.seconds) seconds, so Armada did not start the session."
  }

  /// The person's login shell, run the way VS Code runs it when opened from the Dock. See
  /// `EditorLaunch.shellEnvironment` for why Armada's own environment will not do.
  ///
  /// Measured at 70ms on this Mac. Cut off after five seconds, so a profile that waits on
  /// something turns into a sentence rather than a launch that never happens.
  private static func loginShellEnvironment() async -> [String: String]? {
    let shell = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    let command = "printf %s \(EditorLaunch.environmentMarker); /usr/bin/env -0"
    return await Task.detached {
      let process = Process()
      process.executableURL = URL(filePath: shell)
      process.arguments = ["-ilc", command]
      process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch { return nil }
      let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      timeout.cancel()
      return EditorLaunch.shellEnvironment(data)
    }.value
  }

  /// VS Code's own `code` command, from inside its bundle so nobody has to have installed it
  /// on their PATH. It hands the request to a running VS Code, with this environment for the
  /// new window, and returns; measured 2026-09-16, the extension host of the window it opened
  /// carried the variables it was run with, VS Code already running or not.
  private static func run(_ executable: URL, arguments: [String], environment: [String: String])
    async -> String?
  {
    await Task.detached {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.environment = environment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch { return error.localizedDescription }
      let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
      process.waitUntilExit()
      timeout.cancel()
      return process.terminationStatus == 0
        ? nil : "its command line exited with status \(process.terminationStatus)."
    }.value
  }

  // MARK: - The window that is open

  /// How long VS Code gets to settle on the raised window: 60 checks, 50ms apart. Longer than
  /// the second `FocusSession.reveal` allows, because a window that has only just appeared is
  /// still loading.
  private static let focusAttempts = 60

  /// How many checks in a row the window has to stay focused before the link goes.
  private static let focusSettledChecks = 3

  /// Raise `window`, wait until VS Code keeps it focused, and send the link.
  ///
  /// **Raised again while VS Code settles, and it needs to be.** Measured 2026-09-16 with the
  /// first version of this, which raised once, then activated: the project's window reported
  /// focused, and a moment later VS Code's activation put its previous front window back, so the
  /// check before sending failed. So the raise is repeated until the window has stayed focused
  /// for a few checks in a row.
  ///
  /// **Checked again right before sending**, because the Restricted Mode walk takes most of a
  /// second; a window lost in that second is brought back once before giving up, and a person
  /// who clicked elsewhere twice gets a sentence rather than a session in the wrong window.
  private static func deliver(
    _ url: URL, to window: AXUIElement, of app: NSRunningApplication, application: URL,
    projectName: String
  ) async -> String? {
    let pid = app.processIdentifier
    // An `AXUIElement` is a CF reference to another process's element, and every call on it is
    // IPC that is safe from any thread; Swift only lacks the annotation to know it.
    nonisolated(unsafe) let element = window
    var checkedTrust = false
    for _ in 0..<2 {
      guard await bringForward(window, of: app) else {
        return
          "\(name) did not bring \(projectName)'s window to the front, so Armada did not open the session, which would have landed in another window."
      }
      if !checkedTrust {
        checkedTrust = true
        if await Task.detached(operation: { HostWindow.showsRestrictedMode(element) }).value {
          return
            "\(name) has \(projectName) open in Restricted Mode, where the Claude Code extension does not run. Trust the folder in that window, then start the session again."
        }
      }
      guard isFocused(window, pid: pid) else { continue }
      NSWorkspace.shared.open(
        [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration(),
        completionHandler: nil)
      logger.info("opened a Claude Code tab in \(projectName, privacy: .public)")
      return nil
    }
    return
      "Another window kept coming to the front while \(projectName)'s was opening, so Armada did not open the session there. Start it again."
  }

  private static func bringForward(_ window: AXUIElement, of app: NSRunningApplication) async
    -> Bool
  {
    let pid = app.processIdentifier
    HostWindow.raiseWindow(window)
    NSApp.yieldActivation(to: app)
    app.activate(from: .current, options: [])
    var settled = 0
    for _ in 0..<focusAttempts {
      if isFocused(window, pid: pid) {
        settled += 1
        if settled >= focusSettledChecks { return true }
      } else {
        settled = 0
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
          HostWindow.raiseWindow(window)
        }
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  private static func isFocused(_ window: AXUIElement, pid: pid_t) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      && HostWindow.isFocused(window, inApplication: pid)
  }

  // MARK: - Checks

  private static func ambiguous(_ projectName: String) -> String {
    "More than one \(name) window is titled \(projectName), and Armada tells windows apart by their titles alone, so it did not guess. Close the other one, or start the session from your terminal."
  }

  /// `CLAUDE_CONFIG_DIR` of every running VS Code extension host, nil where unset.
  ///
  /// One extension host per window, recognised by the variable VS Code sets on it
  /// (`VSCODE_CRASH_REPORTER_PROCESS_TYPE=extensionHost`, read with `ps -E` on 2026-09-16) and
  /// by its executable living inside VS Code's bundle, so Cursor's windows are not counted.
  private static func extensionHostConfigDirectories() -> [String?] {
    guard let bundle = applicationURL?.standardizedFileURL.path(percentEncoded: false) else {
      return []
    }
    let prefix = bundle.hasSuffix("/") ? bundle : bundle + "/"
    return ProcessAncestry.allPIDs().compactMap { pid -> String?? in
      guard ProcessAncestry.executablePath(of: pid)?.hasPrefix(prefix) == true,
        let environment = ProcessAncestry.environment(of: pid),
        environment["VSCODE_CRASH_REPORTER_PROCESS_TYPE"] == "extensionHost"
      else { return nil }
      return .some(environment["CLAUDE_CONFIG_DIR"])
    }
  }

  private static var hasClaudeExtension: Bool {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: ".vscode/extensions", directoryHint: .isDirectory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.contains(where: EditorLaunch.isClaudeExtension)
  }

  /// A refusal when VS Code's settings name the account instead of the window. See
  /// `EditorLaunch.settingsSetConfigDirectory`.
  private static func settingsRefusal(project: URL) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let files = [
      home.appending(path: "Library/Application Support/Code/User/settings.json"),
      project.appending(path: ".vscode/settings.json"),
    ]
    for file in files {
      guard let text = try? String(contentsOf: file, encoding: .utf8),
        EditorLaunch.settingsSetConfigDirectory(text)
      else { continue }
      return
        "\((file.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath) sets CLAUDE_CONFIG_DIR in claudeCode.environmentVariables, which decides the account in every \(name) window whatever Armada opens it with. Start the session from your terminal instead."
    }
    return nil
  }
}
