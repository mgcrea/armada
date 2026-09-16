import Foundation

/// The parts of starting a session in Visual Studio Code that are only text, apart from
/// `VSCodeLaunch`, which also needs AppKit and Accessibility — so `make unit` can check them.
nonisolated enum EditorLaunch {
  /// The line printed before the environment, so whatever a shell profile prints on its way in
  /// is skipped rather than parsed as variables.
  static let environmentMarker = "__ARMADA_ENVIRONMENT__"

  /// What `<shell> -ilc 'printf <marker>; env -0'` printed, as variables.
  ///
  /// **The login shell's environment, because Armada's own is not one.** An app launched from
  /// the Dock or at login gets launchd's, whose `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, and a
  /// VS Code window opened from it keeps exactly that: measured 2026-09-16, the new window's
  /// extension host had that `PATH` whether Armada's was passed or left out. Every MCP server
  /// started with `npx` and every hook calling a Homebrew tool would then fail inside the
  /// session. VS Code reads the login shell for the same reason when it is opened from the Dock.
  ///
  /// `env -0` rather than `env`, because a value can hold a newline and a NUL cannot. Nil when
  /// the marker never arrived: the shell failed before it got there.
  static func shellEnvironment(_ output: Data) -> [String: String]? {
    let marker = Data(environmentMarker.utf8)
    guard let found = output.range(of: marker) else { return nil }
    var environment: [String: String] = [:]
    for entry in output[found.upperBound...].split(separator: 0) {
      let text = String(decoding: entry, as: UTF8.self)
      guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
      environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
    }
    return environment.isEmpty ? nil : environment
  }

  /// Variables that describe the shell Armada ran, or a process that is not the new window's,
  /// and so must not be handed on to it.
  ///
  /// `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` are there for a profile run inside a session; the
  /// VS Code and Electron ones would tell the window it is something it is not. The account's
  /// own variable is not listed: `windowEnvironment` decides it outright.
  static let droppedVariables: Set<String> = [
    "_", "PWD", "OLDPWD", "SHLVL", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
    "ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ATTACH_CONSOLE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
  ]

  /// The environment the new window is opened with: the shell's, with the account stated.
  ///
  /// **Unset for the default folder, set for any other**, for the reason
  /// `NewSession.accountLines` gives: exporting the default folder's own path makes Claude Code
  /// look for an account file that is not there, and a profile that exports another account's
  /// folder would otherwise decide the account silently. `configDirectory` is
  /// `ClaudeConfigFolder.path`, nil for the default folder.
  static func windowEnvironment(shell: [String: String], configDirectory: String?)
    -> [String: String]
  {
    var environment = shell.filter { key, _ in
      !droppedVariables.contains(key) && !key.hasPrefix("VSCODE_")
    }
    environment["CLAUDE_CONFIG_DIR"] = configDirectory
    return environment
  }

  /// Whether every running VS Code window already runs Claude Code on `configDirectory`.
  ///
  /// `hosts` holds each extension host's `CLAUDE_CONFIG_DIR`, nil where it is unset. **A window
  /// keeps the environment it was opened with**: measured 2026-09-16, asking for a folder that
  /// is already open, with `--new-window` or without, only brings the old window forward, and
  /// its extension host keeps the variable it started with. Armada cannot tell which host draws
  /// which window, so the check is on all of them, and a single disagreeing window is enough to
  /// refuse. That errs on the side of saying no, which is the side a wrong account is on.
  static func hostsAgree(_ hosts: [String?], configDirectory: String?) -> Bool {
    func normalized(_ value: String?) -> String? {
      guard let value, !value.isEmpty else { return nil }
      return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }
    let wanted = normalized(configDirectory)
    return hosts.allSatisfy { normalized($0) == wanted }
  }

  /// Whether a VS Code `settings.json` sets `CLAUDE_CONFIG_DIR` for the extension.
  ///
  /// **The setting beats the window's environment.** The extension builds each `claude`'s
  /// environment from its own process and then lays `claudeCode.environmentVariables` over it,
  /// read from the extension on 2026-09-16, so a folder named there decides the account in every
  /// window whatever Armada opens it with. A plain search rather than a parse: the file is JSON
  /// with comments, and a mention in a comment only costs a refusal the person can read.
  static func settingsSetConfigDirectory(_ settings: String) -> Bool {
    settings.contains("claudeCode.environmentVariables") && settings.contains("CLAUDE_CONFIG_DIR")
  }

  /// `<scheme>://anthropic.claude-code/open`, with the opening message when there is one.
  ///
  /// **No `session`, ever.** With one, the extension resumes that session rather than forking
  /// it, which is the two-writers case `NewSession.Start` refuses. Without one it opens a fresh
  /// conversation tab, and puts `prompt` in the input box: measured 2026-09-16, no `claude`
  /// process started and no transcript was written until a message was sent.
  static func openURL(scheme: String, prompt: String?) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = extensionID
    components.path = "/open"
    if let prompt, !prompt.isEmpty {
      components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
    }
    return components.url
  }

  /// The Claude Code extension's id, the same on the Marketplace and Open VSX.
  static let extensionID = "anthropic.claude-code"

  /// Whether a folder in `~/.vscode/extensions` is the Claude Code extension, of any version.
  static func isClaudeExtension(_ folderName: String) -> Bool {
    folderName.lowercased().hasPrefix(extensionID + "-")
  }

  /// A process's arguments and environment, from the bytes `KERN_PROCARGS2` returns.
  ///
  /// The layout, from `sysctl` in xnu: the argument count as a 32-bit integer, the executable
  /// path, NUL padding, then that many arguments and after them the environment, every string
  /// NUL-terminated. It ends at the first empty string after the environment starts.
  static func processArguments(_ bytes: [UInt8]) -> (
    arguments: [String], environment: [String: String]
  )? {
    guard bytes.count >= 4 else { return nil }
    let count = bytes[0..<4].withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    guard count >= 0 else { return nil }
    var index = 4
    // The executable path, then the padding after it.
    while index < bytes.count, bytes[index] != 0 { index += 1 }
    while index < bytes.count, bytes[index] == 0 { index += 1 }

    func next() -> String? {
      guard index < bytes.count else { return nil }
      let start = index
      while index < bytes.count, bytes[index] != 0 { index += 1 }
      let text = String(decoding: bytes[start..<index], as: UTF8.self)
      index += 1
      return text
    }

    var arguments: [String] = []
    for _ in 0..<count {
      guard let argument = next() else { return nil }
      arguments.append(argument)
    }
    var environment: [String: String] = [:]
    while let entry = next(), !entry.isEmpty {
      guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
      environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return (arguments, environment)
  }
}
