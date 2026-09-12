import Foundation

/// Asking Claude Code what the limits are, instead of reading what it left behind.
///
/// **This is how the VS Code extension is accurate and a file reader is not.** The
/// extension never reads `cachedUsageUtilization`; it is attached to a running
/// `claude` over the SDK's stream-json control protocol, where usage arrives two
/// ways — pushed as a `rate_limit_event` carrying `rate_limit_info.unifiedWindows`
/// whenever an API response updates them, and pulled with a `get_usage` control
/// request when the panel asks. Read out of `extension.js` 2.1.268 on 2026-09-12;
/// the CLI binary implements both.
///
/// Armada cannot take the push — that needs to be the process's parent — but the
/// pull works standalone, and it is what this runs. The cache stays as the fallback.
///
/// **Why this is the allowed route, where the Keychain is not.** It spawns the
/// user's own unmodified `claude`, signed in through Anthropic's own flow, run
/// headless — which `docs/limits-accounts-and-terms.md` records as the normal,
/// permitted path. Armada never sees a token. The rejected alternative was reading
/// `Claude Code-credentials` out of the Keychain and calling the endpoint directly,
/// which is the one thing the Consumer Terms name outright.
///
/// **It costs nothing.** A control request is not a prompt: measured on 2026-09-12
/// against both folders, `total_cost_usd: 0`, `total_api_duration_ms: 0`, and no
/// session registry file or transcript is written — so the spawned process does not
/// appear in Armada's own session list. What it costs is a process and about a
/// second, which is why it runs on a slow timer and on the popover opening rather
/// than on the 30-second file poll.
///
/// `nonisolated` and never called from the main actor: this blocks on a subprocess.
nonisolated enum UsageProbe {
  /// Long enough for a cold `claude` start on a busy Mac, short enough that a hung
  /// one does not pin a background task for a minute. Warm responses land in ~1.2s.
  static let timeout: TimeInterval = 20

  /// The control request, verbatim. `request_id` is fixed because exactly one is
  /// ever in flight per process.
  private static let request =
    #"{"type":"control_request","request_id":"armada-usage","request":{"subtype":"get_usage"}}"#

  /// Ask one config folder's account for its current windows, or nil.
  ///
  /// Nil on every failure — no binary, a timeout, a malformed answer, or an account
  /// that reports `rate_limits_available: false` — and the caller keeps the cached
  /// snapshot. There is no failure here worth blanking a pane for.
  static func run(folder: ClaudeConfigFolder) -> UsageSnapshot? {
    guard let executable = executable() else { return nil }

    let process = Process()
    process.executableURL = executable
    // `--verbose` is required alongside stream-json output, not optional detail.
    process.arguments = [
      "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    ]
    process.environment = environment(for: folder)
    // Somewhere that exists and holds no project. A cwd inside a repo would have
    // `claude` resolving that project's settings and CLAUDE.md for a question that
    // has nothing to do with any project.
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    // Swallowed rather than inherited: an unreadable warning on Armada's stderr is
    // noise, and an unread pipe is a process that blocks once it fills one.
    process.standardError = FileHandle.nullDevice

    do { try process.run() } catch { return nil }
    defer {
      // The CLI exits when stdin closes, but not instantly; the kill is what bounds
      // this. Both are needed — closing alone leaves a process behind on a timeout,
      // and killing alone can race a clean exit into a spurious error.
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
    }

    guard let line = (request + "\n").data(using: .utf8),
      (try? input.fileHandleForWriting.write(contentsOf: line)) != nil
    else { return nil }

    guard let response = readResponse(from: output.fileHandleForReading) else { return nil }
    return snapshot(from: response)
  }

  /// Read stream-json until the control response arrives or the deadline passes.
  ///
  /// The CLI emits an `init` system message and may emit more before answering, so
  /// this cannot take the first line. It matches on the one key it needs and leaves
  /// everything else unparsed.
  private static func readResponse(from handle: FileHandle) -> [String: Any]? {
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = Data()

    while Date() < deadline {
      // `availableData` blocks until there is something, which is why the deadline
      // is checked around it rather than trusted to bound it: a silent process
      // parks here until it writes or exits. The terminate in `run`'s defer is the
      // real backstop.
      let chunk = handle.availableData
      if chunk.isEmpty { return nil }  // EOF: the process gave up first.
      buffer.append(chunk)

      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        // Cheap reject before a JSON parse, as the transcript readers do.
        guard line.range(of: Data("control_response".utf8)) != nil,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let response = object["response"] as? [String: Any],
          response["subtype"] as? String == "success",
          let payload = response["response"] as? [String: Any]
        else { continue }
        return payload
      }
    }
    return nil
  }

  /// Decode narrowly, exactly as the cache is decoded.
  ///
  /// The payload also carries a `behaviors` block — request and session counts, and
  /// which skills, agents and MCP servers the person uses — plus `spend` and
  /// `extra_usage`. None of it is read. That is the same rule `UsageSnapshot` states
  /// for the cache, and it matters more here: this is the user's own analytics, and
  /// Armada has no business holding it to draw two meters.
  private static func snapshot(from payload: [String: Any]) -> UsageSnapshot? {
    // False for a folder whose account did not resolve — which is what a wrongly set
    // `CLAUDE_CONFIG_DIR` looks like, rather than an error. See `isDefault`.
    guard payload["rate_limits_available"] as? Bool == true,
      let rateLimits = payload["rate_limits"] as? [String: Any]
    else { return nil }

    // `.now` rather than a field: the answer was computed for this request, so its
    // age is the round trip. Nothing in the payload dates it.
    let snapshot = UsageSnapshot.decode(windows: rateLimits, fetchedAt: .now, source: .live)
    return snapshot.isEmpty ? nil : snapshot
  }

  /// `CLAUDE_CONFIG_DIR` for a custom folder, and pointedly **removed** for the
  /// default one — see `ClaudeConfigFolder.isDefault` for what setting it there does.
  ///
  /// Removed rather than left alone because Armada inherits whatever environment it
  /// was launched with, and a developer starting it from a terminal that exports
  /// `CLAUDE_CONFIG_DIR` would otherwise have every folder probed as that one.
  private static func environment(for folder: ClaudeConfigFolder) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if folder.isDefault {
      environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
    } else {
      environment["CLAUDE_CONFIG_DIR"] = folder.base.path(percentEncoded: false)
    }
    return environment
  }

  /// Where `claude` is, without a shell to ask.
  ///
  /// **A GUI process inherits no login `PATH`**, so `/usr/bin/env claude` finds
  /// nothing when Armada is launched from Finder and everything when it is launched
  /// from a terminal — which is the kind of difference that gets diagnosed as a
  /// flaky feature. `PATH` is still consulted first, for anyone running a build from
  /// a shell, then the three places the installers use.
  static func executable() -> URL? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser

    var candidates: [URL] = []
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates += path.split(separator: ":").map {
        URL(filePath: String($0)).appending(path: "claude", directoryHint: .notDirectory)
      }
    }
    candidates += [
      home.appending(path: ".local/bin/claude", directoryHint: .notDirectory),
      home.appending(path: ".claude/local/claude", directoryHint: .notDirectory),
      URL(filePath: "/opt/homebrew/bin/claude"),
      URL(filePath: "/usr/local/bin/claude"),
    ]

    return candidates.first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
  }
}
