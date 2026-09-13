import Foundation

/// One control request to a headless `claude`, and the payload it answers with.
///
/// Extracted from `UsageProbe` when a second caller appeared, for the same reason
/// `TranscriptTitle.tail(of:)` was: two probes spawning their own processes would have
/// duplicated the environment rules, the `PATH` search and the deadline handling —
/// each of which is a trap someone already paid for once.
///
/// **A control request is not a prompt.** Measured on 2026-09-12: `total_cost_usd: 0`,
/// no session registry file and no transcript, so a probe does not appear in Armada's
/// own session list. What it costs is a process and about a second.
///
/// **It is deliberately not kept alive between calls.** One process does answer
/// repeated requests — verified — but an idle one measured **128MB RSS, a 206MB
/// physical footprint, and three child MCP server processes**. Holding one per config
/// folder, let alone per project, is the opposite of what an app that watches sixteen
/// sessions can afford, and neither thing it is asked about changes often enough to
/// poll. See `ContextProbe` for how that is cached instead.
///
/// `nonisolated` and never called from the main actor: this blocks on a subprocess.
nonisolated enum ClaudeControl {
  /// Long enough for a cold `claude` start on a busy Mac, short enough that a hung
  /// one does not pin a background task for a minute. Warm responses land in ~1s.
  static let timeout: TimeInterval = 20

  /// Run one control request and return its success payload, or nil.
  ///
  /// Nil on every failure — no binary, a timeout, a non-success response, a malformed
  /// answer. No failure here is worth blanking a pane for; every caller keeps what it
  /// had.
  ///
  /// - Parameters:
  ///   - subtype: the control request's `subtype`.
  ///   - extra: further keys merged into the `request` object, already JSON-encoded
  ///     fragments (`"detail": "summary"`). Kept as a string rather than a dictionary
  ///     because there are two callers and one of them passes nothing.
  ///   - folder: whose `CLAUDE_CONFIG_DIR` to run under.
  ///   - cwd: **the working directory decides what gets loaded.** `claude` resolves
  ///     project settings and `CLAUDE.md` from it, so a probe asking what a session
  ///     loads must run where that session runs, and a probe asking about an account
  ///     must not.
  static func request(
    subtype: String, extra: String = "", folder: ClaudeConfigFolder, cwd: URL
  ) -> [String: Any]? {
    guard let executable = executable() else { return nil }

    let process = Process()
    process.executableURL = executable
    // `--verbose` is required alongside stream-json output, not optional detail.
    process.arguments = [
      "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    ]
    process.environment = environment(for: folder)
    process.currentDirectoryURL = cwd

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

    let body =
      #"{"type":"control_request","request_id":"armada","request":{"subtype":"\#(subtype)"\#(extra)}}"#
    guard let line = (body + "\n").data(using: .utf8),
      (try? input.fileHandleForWriting.write(contentsOf: line)) != nil
    else { return nil }

    return readResponse(from: output.fileHandleForReading)
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
      // parks here until it writes or exits. The terminate in the caller's defer is
      // the real backstop.
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

  /// `CLAUDE_CONFIG_DIR` for a custom folder, and pointedly **removed** for the
  /// default one — see `ClaudeConfigFolder.isDefault` for what setting it there does.
  ///
  /// Removed rather than left alone because Armada inherits whatever environment it
  /// was launched with, and a developer starting it from a terminal that exports
  /// `CLAUDE_CONFIG_DIR` would otherwise have every folder probed as that one.
  ///
  /// **`folder.path`, never `folder.base.path`.** The second ends in a slash, and a
  /// slash here is the difference between a probe that answers and one that reports no
  /// limits at all — see `ClaudeConfigFolder.path` for the measurement. This line is
  /// where that cost every non-default account its live figures.
  private static func environment(for folder: ClaudeConfigFolder) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if folder.isDefault {
      environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
    } else {
      environment["CLAUDE_CONFIG_DIR"] = folder.path
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
