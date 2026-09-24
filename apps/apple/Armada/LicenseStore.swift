import Foundation

/// Where this Mac's licence key lives, and whether it is any good.
///
/// `UserDefaults`, not the Keychain. A licence key is not a secret: it is issued
/// to the user, shown in the licence pane, emailed to them in plain text and
/// re-sendable on demand. Encrypting at rest something the UI displays would be
/// ceremony.
///
/// Nothing is cached. Ed25519 verification is microseconds, and re-checking on
/// every read means entering a key takes effect immediately with no invalidation
/// to get wrong.
///
/// DIVERGES from bastion and cupertino, which carry a `demoLicensed` branch for
/// their screenshot captures — fenced `#if DEBUG`, because unfenced it would let a
/// shipped binary answer the licence question from a flag rather than from a
/// signature. Armada has a capture pipeline but no branch here at all: a capture
/// hands `EntitlementMonitor` a licence directly, from `DemoSeed`, which is `#if
/// DEBUG` in its entirety and never starts a watcher on the strength of it. The
/// only way to a licensed state in a shipped build is a key that verifies.
nonisolated enum LicenseStore {
  private static let defaultsKey = "license"

  /// The stored key as typed, or nil. Kept separate from `check` so the entry
  /// field can show what is there even when it is being refused.
  static var raw: String? {
    UserDefaults.standard.string(forKey: defaultsKey)
  }

  static var check: LicenseCheck { LicenseKey.check(raw) }
  static var current: License? { check.license }
  static var isLicensed: Bool { current != nil }

  /// Store a key only if it verifies, and say why if it does not.
  ///
  /// Refusing to persist a bad key is what keeps `raw` and `check` from
  /// disagreeing in a way the user cannot see — a key that is saved but refused
  /// looks like the app losing it.
  @discardableResult
  static func store(_ key: String) -> LicenseCheck {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = LicenseKey.check(trimmed)
    if case .valid = result {
      UserDefaults.standard.set(trimmed, forKey: defaultsKey)
    }
    return result
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }
}
