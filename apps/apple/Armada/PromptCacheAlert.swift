import Foundation

/// Which sessions get a notification when their prompt cache is about to lapse.
///
/// **Off by default.** A notification is the one thing Armada does that reaches past its
/// own icon and windows, so it is asked for rather than assumed.
///
/// The two rungs split on the registry's own two words for a stopped session. `waiting` is
/// a session stopped at a prompt or a dialog; `idle` is one that finished its turn and is
/// waiting for your next message — which is where most sessions sit most of the time, and
/// so the wider rung is the one most people will want.
nonisolated enum PromptCacheAlertScope: String, CaseIterable, Sendable {
  case off
  case waiting
  case stopped

  static let defaultsKey = "armada.promptCacheAlerts"

  var label: String {
    switch self {
    case .off: "Never"
    case .waiting: "For sessions waiting on a prompt"
    case .stopped: "For any session between turns"
    }
  }
}

/// The smallest prompt worth a notification. A cold 20k prompt costs less to re-cache
/// than the interruption does.
nonisolated enum PromptCacheAlertSize {
  static let defaultsKey = "armada.promptCacheAlerts.minimumTokens"
  static let fallback = 100_000
  static let options = [0, 50_000, 100_000, 200_000]
}

nonisolated enum PromptCacheAlert {
  /// Whether this session's cache warrants a notification right now.
  ///
  /// The window is `PromptCache.isExpiringSoon`, the same one the row's timer marks, so
  /// a notification never names a session its row does not also flag.
  ///
  /// `isWaiting` rather than a `SessionState`, to keep this compilable beside the unit
  /// checks without SwiftUI. A busy session never gets here: `Session.promptCache` is nil
  /// for one, because each request it makes resets the clock.
  static func shouldAlert(
    _ cache: PromptCache, isWaiting: Bool, scope: PromptCacheAlertScope, minimumTokens: Int,
    now: Date
  ) -> Bool {
    switch scope {
    case .off: return false
    case .waiting: guard isWaiting else { return false }
    case .stopped: break
    }
    return cache.tokens >= minimumTokens && cache.isExpiringSoon(at: now)
  }

  /// "about 12 min", rounded up: a banner saying "0 min" while the cache is still warm
  /// reads as already too late.
  static func remaining(_ cache: PromptCache, now: Date) -> String {
    let minutes = max(1, Int((cache.expiresAt.timeIntervalSince(now) / 60).rounded(.up)))
    return "about \(minutes) min"
  }
}
