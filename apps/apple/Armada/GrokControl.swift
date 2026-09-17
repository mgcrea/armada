import Foundation

/// Asking Grok Build for the account's allowance, the way `UsageProbe` asks Claude Code.
///
/// Grok writes its weekly allowance nowhere on disk; its TUI's `/usage` fetches it. The same
/// request is served by `grok agent stdio`, the Agent Client Protocol mode editors attach to,
/// as the extension method `x.ai/billing` (`crates/codegen/xai-grok-shell/src/extensions/
/// billing.rs`). So this runs the person's own `grok`, signed in through xAI's own flow, and
/// Armada never sees a token or opens `auth.json`.
///
/// **It costs nothing.** No session is created and no prompt is sent. Measured on 2026-09-17
/// against grok 1.0.34: `initialize` answered in 0.25s, `_x.ai/billing` in 0.13s, and no session
/// directory or `active_sessions.json` entry appeared.
///
/// `nonisolated` and never called from the main actor: this blocks on a subprocess.
nonisolated enum GrokControl {
  static let timeout: TimeInterval = 15
  static let killGrace: TimeInterval = 2

  static func limits(home: GrokHome) -> GrokFiles.Limits? {
    guard let executable = executable() else { return nil }

    let process = Process()
    process.executableURL = executable
    process.arguments = ["agent", "stdio"]
    process.environment = environment(for: home)
    // Not inside a repository, for `UsageProbe`'s reason: nothing here is about a project.
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    guard !Task.isCancelled else { return nil }
    do { try process.run() } catch { return nil }
    let watchdog = armWatchdog(for: process)
    defer {
      watchdog.cancel()
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
    }

    // An extension method goes on the wire with a leading underscore, per the protocol.
    let requests = [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"#,
    ]
    guard let lines = (requests.joined(separator: "\n") + "\n").data(using: .utf8),
      (try? input.fileHandleForWriting.write(contentsOf: lines)) != nil
    else { return nil }

    guard let result = readResult(id: 2, from: output.fileHandleForReading) else { return nil }
    return GrokFiles.limits(result, observedAt: .now)
  }

  /// See `ClaudeControl.armWatchdog`: ending the process is what unblocks a silent read.
  private static func armWatchdog(for process: Process) -> DispatchWorkItem {
    let pid = process.processIdentifier
    let watchdog = DispatchWorkItem {
      guard process.isRunning else { return }
      process.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) {
        if process.isRunning { kill(pid, SIGKILL) }
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
    return watchdog
  }

  /// The `result` of the JSON-RPC response with this id. Nil on an error response or EOF.
  private static func readResult(id: Int, from handle: FileHandle) -> [String: Any]? {
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = Data()
    while Date() < deadline {
      let chunk = handle.availableData
      if chunk.isEmpty { return nil }
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          (object["id"] as? NSNumber)?.intValue == id
        else { continue }
        return object["result"] as? [String: Any]
      }
    }
    return nil
  }

  static func environment(for home: GrokHome) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let fallback = GrokHome(
      base: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".grok", directoryHint: .isDirectory))
    if home.path == fallback.path {
      environment.removeValue(forKey: "GROK_HOME")
    } else {
      environment["GROK_HOME"] = home.path
    }
    return environment
  }

  /// The installer puts `grok` in `~/.local/bin`, a link into `~/.grok/bin`. A GUI launch has
  /// no shell `PATH`, so both are checked by name.
  static func executable() -> URL? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    var candidates: [URL] = []
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates += path.split(separator: ":").map {
        URL(filePath: String($0)).appending(path: "grok", directoryHint: .notDirectory)
      }
    }
    candidates += [
      home.appending(path: ".local/bin/grok", directoryHint: .notDirectory),
      home.appending(path: ".grok/bin/grok", directoryHint: .notDirectory),
      URL(filePath: "/opt/homebrew/bin/grok"),
      URL(filePath: "/usr/local/bin/grok"),
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
  }
}
