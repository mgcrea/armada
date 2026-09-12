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
  /// Ask one config folder's account for its current windows, or nil.
  ///
  /// Nil on every failure — no binary, a timeout, a malformed answer, or an account
  /// that reports `rate_limits_available: false` — and the caller keeps the cached
  /// snapshot. There is no failure here worth blanking a pane for.
  ///
  /// **Runs from the home directory, deliberately.** `ClaudeControl` takes a `cwd`
  /// because what `claude` loads depends on it, and a cwd inside a repo would have it
  /// resolving that project's settings and `CLAUDE.md` for a question that has nothing
  /// to do with any project. `ContextProbe` is the caller that wants the opposite.
  static func run(folder: ClaudeConfigFolder) -> UsageSnapshot? {
    guard
      let payload = ClaudeControl.request(
        subtype: "get_usage", folder: folder,
        cwd: FileManager.default.homeDirectoryForCurrentUser)
    else { return nil }
    return snapshot(from: payload)
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
}
