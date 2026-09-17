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
  /// its extension host keeps the variable it started with. This is the check for when Armada
  /// cannot tell which host draws the project's window, so it is on all of them, and a single
  /// disagreeing window is enough to refuse. That errs on the side of saying no, which is the
  /// side a wrong account is on. `windowAgrees` asks it only when it has to.
  static func hostsAgree(_ hosts: [String?], configDirectory: String?) -> Bool {
    let wanted = normalizedPath(configDirectory)
    return hosts.allSatisfy { normalizedPath($0) == wanted }
  }

  /// One VS Code window's extension host: the account it runs Claude Code on, nil for the
  /// default folder, and the folder the window shows, nil when Armada could not find it.
  struct ExtensionHost: Equatable {
    var configDirectory: String?
    var folder: String?
  }

  /// Whether the window showing `folder` runs Claude Code on `configDirectory`.
  ///
  /// **Only the project's own window decides, once it is found.** Measured 2026-09-16, with
  /// Silhouette on the default account and Contour on another: every window was refused, because
  /// `hostsAgree` saw Contour's host. When a host is traced to `folder`, the hosts traced there
  /// are the ones asked, and the others' accounts do not matter. When none is, which of the rest
  /// draws the window is unknown, and `hostsAgree` is asked of all of them, as before.
  static func windowAgrees(_ hosts: [ExtensionHost], folder: String, configDirectory: String?)
    -> Bool
  {
    let own = hosts.filter { traced($0, to: folder) }
    return hostsAgree(
      (own.isEmpty ? hosts : own).map(\.configDirectory), configDirectory: configDirectory)
  }

  /// Whether `host` was traced to the window showing `folder`.
  static func traced(_ host: ExtensionHost, to folder: String) -> Bool {
    host.folder != nil && normalizedPath(host.folder) == normalizedPath(folder)
  }

  /// The `workspaceStorage` folder name of each extension host a window's `exthost.log` names,
  /// by pid.
  ///
  /// **The log is the one place a host names its window.** Read on 2026-09-16: every window's
  /// `logs/<session>/window<n>/exthost/exthost.log` opens with `Extension host with pid <pid>
  /// started`, and the next line names `…/User/workspaceStorage/<id>`, whose `workspace.json`
  /// holds the folder. Reloading a window appends a second host's pair of lines to the same file,
  /// so each host's storage is taken from the lines after its own, up to the next host's.
  static func hostStorages(log: String) -> [Int32: String] {
    let marker = "Extension host with pid "
    var storages: [Int32: String] = [:]
    var current: Int32?
    for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
      if let range = line.range(of: marker) {
        current = Int32(line[range.upperBound...].prefix(while: \.isNumber))
        continue
      }
      guard let pid = current, let range = line.range(of: "/workspaceStorage/") else { continue }
      let id = line[range.upperBound...].prefix(while: { $0.isLetter || $0.isNumber })
      if !id.isEmpty { storages[pid] = String(id) }
      current = nil
    }
    return storages
  }

  /// The folder a `workspace.json` names, as a path. Nil for a multi-root `.code-workspace`,
  /// whose window is not one folder, and for a window with no folder at all.
  static func workspaceFolder(_ json: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let uri = object["folder"] as? String, let url = URL(string: uri), url.isFileURL
    else { return nil }
    return url.standardizedFileURL.path(percentEncoded: false)
  }

  private static func normalizedPath(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
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

  /// Whether the text a message input reports is `prompt`, so Return sends that message and no
  /// other. Runs of whitespace compare equal: a line break in a `contentEditable` input is not
  /// promised to read back as the `\n` the link carried.
  static func inputHolds(_ text: String?, prompt: String) -> Bool {
    guard let text else { return false }
    let words = { (string: String) in string.split(whereSeparator: \.isWhitespace) }
    let expected = words(prompt)
    return !expected.isEmpty && words(text) == expected
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
