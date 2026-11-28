import Foundation

/// Why a Claude Code account reports no plan limits at all, as opposed to not having been
/// asked yet.
///
/// **The two looked the same, and the difference is what the person needs to act on.** An
/// account signed in with a long-lived token (`claude setup-token`) answers `get_usage` with
/// `rate_limits_available: false` and a null `subscription_type`, every time: the token runs
/// sessions but carries no access to the subscription's limits. Armada used to drop that
/// answer as a failure and keep showing "No usage data yet", which reads as a slow probe
/// rather than as a sign-in that will never report. Measured 2026-11-28 on Claude Code
/// 2.1.332, on an account whose Keychain login a token had replaced the day before.
///
/// **The probe's answer alone does not say why.** A wrongly set `CLAUDE_CONFIG_DIR` gives the
/// same false (see `ClaudeConfigFolder.path`), and so would an account billed through the
/// Console. `claude auth status` tells them apart, locally and in about 0.2s, from its
/// `authMethod` — which is why `UsageProbe` asks it, and only once an account has said it has
/// no limits.
nonisolated enum UsageUnavailable: String, Sendable, Equatable {
  /// Signed in with a long-lived token: `authMethod` `oauth_token`.
  case token
  /// Billed by API usage, which has no plan windows: an API key, a key helper, or a third-party
  /// provider.
  case apiKey
  /// `loggedIn: false`.
  case signedOut
  /// Signed in through claude.ai, or in a way this does not recognise, and still no limits.
  case unknown

  /// What `claude auth status` printed, read for the two keys this needs.
  ///
  /// Nil when the output is not the JSON object it prints by default — a `claude` too old to
  /// have the subcommand, or one that failed before printing. The caller says `.unknown`
  /// rather than nothing then, because the probe has already said there are no limits.
  init?(authStatus data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let loggedIn = object["loggedIn"] as? Bool
    else { return nil }
    // The values are the CLI's own mapping, read out of 2.1.332: `claude.ai`, `oauth_token`
    // (any token not from a claude.ai login), `api_key`, `api_key_helper`, `third_party`
    // (Bedrock, Vertex, a gateway) and `none`.
    switch (loggedIn, object["authMethod"] as? String) {
    case (false, _), (_, "none"?): self = .signedOut
    case (_, "oauth_token"?): self = .token
    case (_, "api_key"?), (_, "api_key_helper"?), (_, "third_party"?): self = .apiKey
    default: self = .unknown
    }
  }

  /// The sentence the Usage card shows in place of the meters.
  var explanation: String {
    switch self {
    case .token:
      "Signed in with a long-lived token, which can’t report plan limits. Sign in with your Claude account to see them here."
    case .apiKey:
      "Billed by API usage, so this account has no plan limits to show."
    case .signedOut:
      "Not signed in. Sign in with your Claude account to see its plan limits."
    case .unknown:
      "Claude Code didn’t report plan limits for this account."
    }
  }

  /// A few words for a row too narrow for the sentence: the sidebar and the menu bar panel.
  var shortLabel: String {
    switch self {
    case .token: "No limits · token"
    case .apiKey: "No limits · API billing"
    case .signedOut: "Not signed in"
    case .unknown: "No limits reported"
    }
  }

  /// Whether signing in with a Claude account is the way out. Not for API billing, which may
  /// well be what the person chose, nor for a cause nobody knows.
  var offersSignIn: Bool {
    switch self {
    case .token, .signedOut: true
    case .apiKey, .unknown: false
    }
  }
}

/// What a `get_usage` control request said, narrowed to what Armada draws.
nonisolated enum UsageProbeAnswer: Sendable {
  /// The account's windows.
  case limits(UsageSnapshot)
  /// The account answered, and has no limits to give: `rate_limits_available: false`.
  case noLimits

  /// Decode narrowly, exactly as the cache is decoded.
  ///
  /// The payload also carries a `behaviors` block — request and session counts, and which
  /// skills, agents and MCP servers the person uses — plus `spend` and `extra_usage`. None of
  /// it is read. That is the same rule `UsageSnapshot` states for the cache, and it matters
  /// more here: this is the user's own analytics, and Armada has no business holding it to
  /// draw two meters.
  ///
  /// Nil for anything that is neither answer — a payload without the flag, or limits that
  /// decode to no window — which the caller treats as a failed probe and ignores.
  init?(payload: [String: Any], fetchedAt: Date) {
    switch payload["rate_limits_available"] as? Bool {
    case false?:
      self = .noLimits
    case true?:
      guard let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }
      let snapshot = UsageSnapshot.decode(windows: rateLimits, fetchedAt: fetchedAt, source: .live)
      guard !snapshot.isEmpty else { return nil }
      self = .limits(snapshot)
    case nil:
      return nil
    }
  }
}
