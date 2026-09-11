import Foundation

/// Who a config folder is signed in as.
///
/// Read from `oauthAccount` in the folder's `.claude.json`. Undocumented like
/// everything else Armada reads, so every field is optional and a folder whose
/// identity will not decode still lists its sessions — it just shows up under its
/// folder name.
///
/// The surprise worth recording: **two config folders on this Mac are the same
/// Anthropic account.** Same `accountUuid`, same `emailAddress`, same person —
/// what differs is the *organization*: a personal Max org and a Team org, with
/// separate session lists and separate rate limits. So the thing to put in front
/// of a person is the organization, never the email, which is identical on both
/// rows and would make them look like duplicates.
nonisolated struct AccountIdentity: Sendable, Hashable {
  let organizationName: String?
  let organizationType: String?
  let organizationRateLimitTier: String?
  let userRateLimitTier: String?
  let emailAddress: String?

  init?(root: [String: Any]) {
    guard let oauth = root["oauthAccount"] as? [String: Any] else { return nil }
    organizationName = oauth["organizationName"] as? String
    organizationType = oauth["organizationType"] as? String
    organizationRateLimitTier = oauth["organizationRateLimitTier"] as? String
    userRateLimitTier = oauth["userRateLimitTier"] as? String
    emailAddress = oauth["emailAddress"] as? String
  }

  /// What to call this organization in a list.
  ///
  /// Claude names a personal organization `"<email>'s Organization"`, which is
  /// both long and — beside a real team name — noise. It is rewritten to
  /// "Personal", and only when it matches that exact generated shape, so an
  /// organization somebody deliberately named after their address keeps its name.
  var displayName: String? {
    guard let organizationName else { return nil }
    if let emailAddress, organizationName == "\(emailAddress)'s Organization" {
      return "Personal"
    }
    return organizationName
  }

  /// The plan, as a person would say it: "Max 20x", "Team".
  ///
  /// Built from the rate-limit tier rather than `organizationType`, because the
  /// tier is what actually differs between the two orgs here — both would read
  /// simply "Max" otherwise. The tiers are internal strings
  /// (`default_claude_max_20x`, `default_raven`), so anything unrecognised falls
  /// back to the type and then to nothing rather than showing a code name.
  var planLabel: String? {
    let tier = organizationRateLimitTier ?? userRateLimitTier
    if let tier {
      if tier.contains("max_20x") { return "Max 20x" }
      if tier.contains("max_5x") { return "Max 5x" }
      if tier.contains("pro") { return "Pro" }
    }
    switch organizationType {
    case "claude_max": return "Max"
    case "claude_team": return "Team"
    case "claude_pro": return "Pro"
    case "claude_enterprise": return "Enterprise"
    default: return nil
    }
  }
}

/// One parse of a `.claude.json`, shared by the two things that read it.
///
/// The file is 153KB and both the usage cache and the account identity live in
/// it, so parsing it once and handing the dictionary to each is worth the small
/// indirection — `UsageTracker` re-reads on a 30s cadence and would otherwise pay
/// for the same parse twice every time.
nonisolated enum ClaudeConfigDocument {
  static func read(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return root
  }
}
