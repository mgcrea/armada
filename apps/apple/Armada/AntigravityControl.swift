import Darwin
import Foundation

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
/// **`posix_spawn` with `POSIX_SPAWN_SETSID` on a fresh PTY.** `Foundation.Process` places its
/// child in a new process group without making the PTY slave its controlling terminal, so a TUI
/// calling `tcsetattr` is stopped by `SIGTTOU`. Opening the slave device inside the child after
/// `POSIX_SPAWN_SETSID` gives `agy` its own session, process group and controlling terminal with
/// no `fork()` in a multithreaded app, and lets teardown signal the whole process group (`-pid`).
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

  /// Spawns `executable` inside a PTY with a session-only `statusLine` capture script and waits
  /// for the quota JSON. Always stops and reaps the child and removes its temp directory before
  /// returning.
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

    let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
    guard masterFD >= 0 else { return nil }
    defer { Darwin.close(masterFD) }

    guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0,
      let slaveCPath = ptsname(masterFD)
    else { return nil }
    let slavePath = String(cString: slaveCPath)

    // Keep the PTY master out of child processes and non-blocking so draining never stalls.
    let closeFlags = fcntl(masterFD, F_GETFD)
    if closeFlags >= 0 { _ = fcntl(masterFD, F_SETFD, closeFlags | FD_CLOEXEC) }
    let ioFlags = fcntl(masterFD, F_GETFL)
    if ioFlags >= 0 { _ = fcntl(masterFD, F_SETFL, ioFlags | O_NONBLOCK) }

    var env = ProcessInfo.processInfo.environment
    if env["TERM"] == nil { env["TERM"] = "xterm-256color" }

    guard
      let pid = spawn(
        executable: executable.path(percentEncoded: false),
        arguments: ["--settings", settingsJSON],
        directory: probeDir.path(percentEncoded: false),
        slavePTY: slavePath,
        environment: env)
    else { return nil }

    var reaped = false
    defer {
      if !reaped { stop(pid: pid) }
    }

    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var best: AntigravityFiles.Limits?
    var tierDeadline: ContinuousClock.Instant?
    var drainBuffer = [UInt8](repeating: 0, count: 4096)

    while !Task.isCancelled && clock.now < deadline {
      while Darwin.read(masterFD, &drainBuffer, drainBuffer.count) > 0 {}

      if let data = try? Data(contentsOf: payloadURL),
        let parsed = AntigravityFiles.limits(data, observedAt: .now)
      {
        best = parsed
        if parsed.tier != nil { return parsed }
        if tierDeadline == nil { tierDeadline = clock.now + tierGrace }
      }

      if let tierDeadline, clock.now >= tierDeadline {
        return best
      }

      var status: Int32 = 0
      if waitpid(pid, &status, WNOHANG) == pid {
        reaped = true
        if let data = try? Data(contentsOf: payloadURL),
          let parsed = AntigravityFiles.limits(data, observedAt: .now)
        {
          return parsed
        }
        return best
      }

      try? await Task.sleep(for: .milliseconds(80))
    }

    return best
  }

  /// Spawns `executable` in its own session and process group with `slavePTY` as stdin, stdout,
  /// stderr and controlling terminal.
  private static func spawn(
    executable: String, arguments: [String], directory: String, slavePTY: String,
    environment: [String: String]
  ) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }

    // Opening the slave PTY without O_NOCTTY after POSIX_SPAWN_SETSID attaches it as the
    // child's controlling terminal, so TUI raw-mode ioctls succeed without SIGTTOU.
    guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePTY, O_RDWR, 0) == 0,
      posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0,
      posix_spawn_file_actions_addchdir(&actions, directory) == 0
    else { return nil }

    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attr) }

    guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) == 0 else { return nil }

    let argvStrings = [executable] + arguments
    let envStrings = environment.map { "\($0.key)=\($0.value)" }
    var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
    defer {
      for ptr in argv { free(ptr) }
      for ptr in envp { free(ptr) }
    }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
    return result == 0 && pid > 0 ? pid : nil
  }

  /// Stops the child's entire process group (`SIGTERM`, then `SIGKILL` after `killGrace`) and
  /// reaps `pid` so no probe process or zombie can outlive the call.
  private static func stop(pid: pid_t) {
    _ = Darwin.kill(-pid, SIGTERM)
    _ = Darwin.kill(-pid, SIGCONT)

    let deadline = ContinuousClock.now + killGrace
    var status: Int32 = 0
    while ContinuousClock.now < deadline {
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid || (waited < 0 && errno == ECHILD) { return }
      usleep(20_000)
    }

    _ = Darwin.kill(-pid, SIGKILL)
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
  }
}
