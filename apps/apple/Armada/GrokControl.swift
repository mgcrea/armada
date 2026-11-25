import ArmadaProcess
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
/// The process is run by `ChildProcess`, off the main actor, and stopped with the task
/// that asked.
nonisolated enum GrokControl {
  static let timeout: Duration = .seconds(15)
  static let killGrace: Duration = .seconds(2)

  static func limits(home: GrokHome) async -> GrokFiles.Limits? {
    guard let executable = executable() else { return nil }
    // An extension method goes on the wire with a leading underscore, per the protocol.
    let requests = [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"#,
    ]
    let result = await ChildProcess.ask(
      executable, arguments: ["agent", "stdio"], environment: environment(for: home),
      // Not inside a repository, for `UsageProbe`'s reason: nothing here is about a project.
      directory: FileManager.default.homeDirectoryForCurrentUser,
      input: Data((requests.joined(separator: "\n") + "\n").utf8), timeout: timeout,
      stop: .terminate(grace: killGrace), answer: { BillingResult(line: $0, id: 2) })
    guard let result = result?.value else { return nil }
    return GrokFiles.limits(result, observedAt: .now)
  }

  /// The JSON-RPC response with one id, carried out of the line reader: its `result`, or nil
  /// for an error response, which still ends the wait. Lines with any other id are not it.
  private struct BillingResult: @unchecked Sendable {
    let value: [String: Any]?

    init?(line: Data, id: Int) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        (object["id"] as? NSNumber)?.intValue == id
      else { return nil }
      value = object["result"] as? [String: Any]
    }
  }

  static func environment(for home: GrokHome) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if home.isDefault {
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
