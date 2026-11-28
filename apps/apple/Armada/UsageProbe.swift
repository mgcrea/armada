import ArmadaProcess
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
/// transcript is written. It does register as a session while it runs — see
/// `SessionRegistry.isArmadaProbe` for why that no longer reaches the list. What it
/// costs is a process and about a second, which is why it runs on a slow timer and on
/// the popover opening rather than on the 30-second file poll.
///
/// `@concurrent`: the probe and its decoding run off the main actor.
nonisolated enum UsageProbe {
  /// Ask one config folder's account for its current windows, or whether it has none.
  ///
  /// Nil on every failure — no binary, a timeout, a malformed answer — and the caller keeps
  /// what it had. There is no failure here worth blanking a pane for. An account that answers
  /// `rate_limits_available: false` is not a failure: that is `.noLimits`, and the caller asks
  /// `authStatus` why. See `UsageUnavailable`.
  ///
  /// **Runs from the home directory, deliberately.** `ClaudeControl` takes a `cwd`
  /// because what `claude` loads depends on it, and a cwd inside a repo would have it
  /// resolving that project's settings and `CLAUDE.md` for a question that has nothing
  /// to do with any project. `ContextProbe` is the caller that wants the opposite.
  ///
  /// **Isolated for the same reason.** The person's hooks and MCP servers have no say in
  /// an account's limits, and on a 3-minute timer they were eleven processes and a
  /// plugin's failed save every time — see `ClaudeControl.isolation`.
  @concurrent
  static func run(folder: ClaudeConfigFolder) async -> UsageProbeAnswer? {
    guard
      let payload = await ClaudeControl.request(
        subtype: "get_usage", folder: folder,
        cwd: FileManager.default.homeDirectoryForCurrentUser, isolated: true)
    else { return nil }
    // `.now` rather than a field: the answer was computed for this request, so its
    // age is the round trip. Nothing in the payload dates it.
    return UsageProbeAnswer(payload: payload, fetchedAt: .now)
  }

  /// How the folder's account is signed in, for an account that reported no limits.
  ///
  /// `claude auth status` with the probe's environment variables, though not its isolation:
  /// the subcommand reads the settings files, so an `apiKeyHelper` or a provider set there is
  /// part of its answer — which is the honest one, since sessions see them too. Local — it
  /// reads the sign-in, it does not call the API — and about 0.2s. It reads no secret into
  /// Armada: what comes back is the method's name, never the token.
  ///
  /// Nil when the command could not run or printed something else, so the caller can keep a
  /// reason it already had; `.unknown` when it answered with a method this does not know.
  @concurrent
  static func authStatus(folder: ClaudeConfigFolder) async -> UsageUnavailable? {
    guard let executable = ClaudeControl.executable(),
      let finished = await ChildProcess.collect(
        executable, arguments: ["auth", "status", "--json"],
        environment: ClaudeControl.environment(for: folder),
        directory: FileManager.default.homeDirectoryForCurrentUser,
        timeout: ClaudeControl.timeout, stop: .terminate(grace: ClaudeControl.killGrace))
    else { return nil }
    // Not `succeeded`: a signed-out account exits 1 and still says so.
    return UsageUnavailable(authStatus: finished.standardOutput)
  }
}
