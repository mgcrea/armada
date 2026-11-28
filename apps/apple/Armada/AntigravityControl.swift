import ArmadaProcess
import Foundation
import Synchronization

/// Asking the Antigravity CLI for the account's quotas, the way `UsageProbe` asks Claude Code
/// and `GrokControl` asks Grok Build.
///
/// `agy` writes its plan quotas nowhere on disk, and `agy acp` does not expose a quota method
/// yet. Its documented `statusLine` hook does carry them, as structured JSON (`quota` buckets
/// plus `plan_tier`), and `--settings` passes a session-only settings object that is never saved
/// to `~/.gemini/antigravity-cli/settings.json`.
///
/// **Naturally isolated in an empty, untrusted directory.** Running `agy` inside a fresh `0700`
/// temp directory that is not in `trustedWorkspaces` holds the TUI at its trust prompt
/// (`agent_state: "initializing"`): `agy` authenticates and fetches live quotas and `plan_tier`
/// in ~1.2–2.0s, while starting no MCP servers, loading no workspace hooks, creating no
/// `conversation_summaries.db` row and holding no `presence/*.lock` file. Armada never opens
/// `~/.gemini/antigravity-cli`'s encrypted files or credentials, and leaves its folder read-only.
///
/// **Run by `ChildProcess.runInPTY` on `swift-subprocess`.** `agy` gets its own session and
/// controlling terminal (`POSIX_SPAWN_SETSID`), bounded by `timeout`, cancelled with the calling
/// task, and torn down by process group once the payload lands.
///
/// **It costs nothing.** No prompt is sent and no conversation is opened.
nonisolated enum AntigravityControl {
  static let timeout: Duration = .seconds(15)
  /// `plan_tier` arrives ~0.5–1s after the first payload carrying `quota`. Waiting briefly after
  /// `quota` appears picks up the plan label without hanging on accounts that report none.
  static let tierGrace: Duration = .seconds(1.5)
  static let killGrace: Duration = .seconds(2)

  @concurrent
  static func limits() async -> AntigravityFiles.Limits? {
    guard !Task.isCancelled, let executable = AntigravityHome.executable() else { return nil }
    return await probe(executable: executable)
  }

  private static func probe(executable: URL) async -> AntigravityFiles.Limits? {
    let fileManager = FileManager.default
    let probeDir = fileManager.temporaryDirectory.appending(
      path: "armada-agy-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(
        at: probeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      return nil
    }
    defer { try? fileManager.removeItem(at: probeDir) }

    let payloadURL = probeDir.appending(path: "payload.json", directoryHint: .notDirectory)
    let tempURL = probeDir.appending(path: "payload.tmp", directoryHint: .notDirectory)
    let scriptURL = probeDir.appending(path: "capture.sh", directoryHint: .notDirectory)

    let script = """
      #!/bin/sh
      cat > \(LaunchScript.quoted(tempURL.path(percentEncoded: false))) \
      && /bin/mv -f \(LaunchScript.quoted(tempURL.path(percentEncoded: false))) \
      \(LaunchScript.quoted(payloadURL.path(percentEncoded: false)))
      """
    do {
      try Data(script.utf8).write(to: scriptURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path(percentEncoded: false))
    } catch {
      return nil
    }

    let settingsObject: [String: Any] = [
      "statusLine": [
        "type": "command",
        "command": scriptURL.path(percentEncoded: false),
      ]
    ]
    guard let settingsData = try? JSONSerialization.data(withJSONObject: settingsObject),
      let settingsJSON = String(data: settingsData, encoding: .utf8)
    else { return nil }

    var env = ProcessInfo.processInfo.environment
    if env["TERM"] == nil { env["TERM"] = "xterm-256color" }

    let state = Mutex<(best: AntigravityFiles.Limits?, tierDeadline: ContinuousClock.Instant?)>(
      (nil, nil))
    let started = ContinuousClock.now
    // The process bound sits past `timeout` so the poll below can return the best payload
    // when the deadline arrives. `runInPTY`'s own timeout answers nil, which would throw
    // away quotas that landed in the last moment, before `plan_tier` did.
    let bounded = timeout + .seconds(1)

    return await ChildProcess.runInPTY(
      executable, arguments: ["--settings", settingsJSON], environment: env, directory: probeDir,
      timeout: bounded, stop: .terminate(grace: killGrace)
    ) { exited in
      let parsed = (try? Data(contentsOf: payloadURL))
        .flatMap { AntigravityFiles.limits($0, observedAt: .now) }
      return state.withLock { current in
        if let parsed {
          current.best = parsed
          if parsed.tier != nil { return .finish(parsed) }
          if current.tierDeadline == nil {
            current.tierDeadline = ContinuousClock.now + tierGrace
          }
        }
        if let deadline = current.tierDeadline, ContinuousClock.now >= deadline {
          return .finish(current.best)
        }
        // `exited` is the PTY closing: the child has gone, or the deadline has, and either
        // way the best payload already written is the answer.
        if exited || ContinuousClock.now >= started + timeout {
          return .finish(current.best)
        }
        return .keepWaiting
      }
    }
  }
}
