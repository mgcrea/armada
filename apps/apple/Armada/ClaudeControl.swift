import ArmadaProcess
import Foundation

/// One control request to a headless `claude`, and the payload it answers with.
///
/// Extracted from `UsageProbe` when a second caller appeared, for the same reason
/// `TranscriptTitle.tail(of:)` was: two probes spawning their own processes would have
/// duplicated the environment rules, the `PATH` search and the deadline handling —
/// each of which is a trap someone already paid for once.
///
/// **A control request is not a prompt.** Measured on 2026-09-12: `total_cost_usd: 0`
/// and no transcript. What it costs is a process and about a second.
///
/// **It does write a session registry file**, which the 2026-09-12 measurement said it
/// did not: on 2.1.269 a probe registers as `"entrypoint": "sdk-cli"` for as long as it
/// runs (re-measured 2026-09-14). `SessionRegistry.isArmadaProbe` is what keeps it out
/// of Armada's own session list.
///
/// **It is deliberately not kept alive between calls.** One process does answer
/// repeated requests — verified — but an idle one measured **128MB RSS, a 206MB
/// physical footprint, and three child MCP server processes**. Holding one per config
/// folder, let alone per project, is the opposite of what an app that watches sixteen
/// sessions can afford, and neither thing it is asked about changes often enough to
/// poll. See `ContextProbe` for how that is cached instead.
///
/// The process is run by `ChildProcess`, off the main actor, and stopped with the task
/// that asked.
nonisolated enum ClaudeControl {
  /// Long enough for a cold `claude` start on a busy Mac, short enough that a hung
  /// one does not hold a probe for a minute. Warm responses land in ~1s.
  ///
  /// The deadline is enforced on the process, not on the read: a `claude` that goes
  /// silent without exiting would park any read for good, so at the deadline it gets
  /// `SIGTERM`, so it can take its MCP servers down with it, then `SIGKILL` after
  /// `killGrace` for one wedged past answering that.
  static let timeout: Duration = .seconds(20)

  /// How long a process that ignored `SIGTERM` has before it is killed outright.
  static let killGrace: Duration = .seconds(2)

  /// What `isolated` adds: no settings files, so none of the person's hooks or plugins,
  /// and no MCP servers.
  ///
  /// **A probe is a whole session start and end to everything the person installed.**
  /// Measured 2026-09-28 on 2.1.283, a `get_usage` from the home directory under the
  /// default folder started 11 child processes — the MCP servers — and ran every user
  /// hook. The remember plugin's `SessionEnd` took each probe for a finished session and
  /// forced a save of it: 417 a day, every one failing, because Armada's `PATH` has no
  /// `claude` for the save to call. With these flags the answer was the same, no hook
  /// ran, and nothing was started beside the probe.
  ///
  /// **Both halves are needed.** `--setting-sources ''` alone stopped the hooks and kept
  /// all 11 servers: they are configured in `~/.claude.json`, not in a settings file.
  /// The empty string is an argument of its own, and is passed as one.
  static let isolation = [
    "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
  ]

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
  ///   - isolated: start `claude` without the person's settings or MCP servers — see
  ///     `isolation`. For a question about the account, which neither changes. A probe
  ///     asking what a session loads must leave it off, because both are part of the
  ///     answer.
  static func request(
    subtype: String, extra: String = "", folder: ClaudeConfigFolder, cwd: URL,
    isolated: Bool = false
  ) async -> [String: Any]? {
    guard let executable = executable() else { return nil }
    let body =
      #"{"type":"control_request","request_id":"armada","request":{"subtype":"\#(subtype)"\#(extra)}}"#

    // Cancelling the caller's task stops `claude`, not only one not started yet:
    // `Accounts.stop()` cancels the probe that led here when the entitlement is refused,
    // and a probe left running would go on talking to the network behind a locked panel.
    let payload = await ChildProcess.ask(
      executable,
      // `--verbose` is required alongside stream-json output, not optional detail.
      arguments: ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        + (isolated ? isolation : []),
      environment: environment(for: folder), directory: cwd, input: Data((body + "\n").utf8),
      timeout: timeout, stop: .terminate(grace: killGrace), answer: { Payload(line: $0) })
    return payload?.value
  }

  /// A control response's payload, carried out of the line reader. `[String: Any]` is
  /// not `Sendable`, and JSON objects are never shared, so the box says so.
  private struct Payload: @unchecked Sendable {
    let value: [String: Any]

    /// The payload of a successful control response, or nil for any other line.
    ///
    /// The CLI emits an `init` system message and may emit more before answering, so
    /// the first line is not the answer. This matches on the one key it needs and
    /// leaves everything else unparsed.
    init?(line: Data) {
      // Cheap reject before a JSON parse, as the transcript readers do.
      guard line.range(of: Data("control_response".utf8)) != nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let response = object["response"] as? [String: Any],
        response["subtype"] as? String == "success",
        let payload = response["response"] as? [String: Any]
      else { return nil }
      value = payload
    }
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
  static func environment(for folder: ClaudeConfigFolder) -> [String: String] {
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
