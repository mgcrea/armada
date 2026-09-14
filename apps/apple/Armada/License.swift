import CryptoKit
import Foundation

/// What a licence key says about itself, once it has proved it.
nonisolated struct License {
  let id: String
  let email: String
  let major: Int
  let issuedAt: String
}

/// The answer, with the reason attached.
///
/// A bare `Bool` would be cheaper and would throw away the only part anyone
/// needs: *why*. The locked card renders it, the licence pane renders it, and a
/// support reply is mostly this sentence — so it is produced once, here, rather
/// than reconstructed at each place that shows it.
nonisolated enum LicenseCheck {
  case valid(License)
  case refused(String)

  var license: License? {
    if case .valid(let license) = self { return license }
    return nil
  }
}

/// Offline verification of a licence key.
///
/// Nothing here reaches the network and nothing here may start to. That is not a
/// preference: `scripts/audit-network.sh` asserts Armada opens no connection
/// beyond the opt-in update check in `Updates.swift`, and an activation call
/// would be a second one — made for every user, on every launch, about their
/// identity.
///
/// Nor is any of this a tamper defence. The gate it feeds is a few readable lines
/// in `EntitlementGate.swift` and the source is public, so removing it is minutes
/// of work for exactly the audience this sells to, and no amount of hardening
/// changes that. This buys a key that cannot be forged. It does not buy — and
/// must not pretend to buy — a binary that cannot be modified.
///
/// Bastion's verifier, copied: the three direct-distribution apps share no
/// package. The format is theirs but for the prefix and the key.
nonisolated enum LicenseKey {
  /// Namespaces the format. A v2 key would carry a different one and be refused
  /// by name here rather than failing somewhere less legible.
  static let prefix = "arm1"

  /// The public half of the signing key: raw 32 bytes, base64url.
  ///
  /// Minted once, on 2026-09-14, and not to be regenerated: changing it refuses
  /// every key ever issued, all at once, in whatever build carries the new one.
  /// The private half signs in `scripts/mint-license.mjs` and the Worker in
  /// `apps/api`, and lives in `.env` and the Worker's secrets, never here and
  /// never in git.
  ///
  /// Empty is the SAFE direction, and stays available: every key is then refused
  /// with "this build has no signing key compiled in", which is a sentence, rather
  /// than every key being accepted. `scripts/lib/license.mjs` carries the same
  /// constant and its tests read this line to assert the two agree.
  static let publicKey = "OTc_jH9ZwYjtYaU0_MP74gsiupje0ZafXTmTiRafI0E"

  static func check(
    _ key: String?,
    major: Int = AppInfo.major,
    revoked: Set<String> = Revocations.ids
  ) -> LicenseCheck {
    guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .refused("no licence key")
    }

    let parts = key.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3 else { return .refused("expected three dot-separated parts") }
    guard parts[0] == prefix else { return .refused("unknown key format '\(parts[0])'") }
    guard !parts[1].isEmpty, !parts[2].isEmpty else {
      return .refused("empty payload or signature")
    }

    guard let payload = base64Url(parts[1]), let signature = base64Url(parts[2]) else {
      return .refused("payload or signature is not base64url")
    }
    guard let claims = try? JSONDecoder().decode(Claims.self, from: payload) else {
      return .refused("payload is not a licence")
    }

    guard let verifier = signer else {
      return .refused("this build has no signing key compiled in")
    }
    // Over the ENCODED payload, not the decoded claims: JSON key order and
    // whitespace then never have to agree across two languages, since the issuer
    // is JavaScript in a Worker and this is Swift.
    guard verifier.isValidSignature(signature, for: Data(parts[1].utf8)) else {
      return .refused("signature does not match")
    }

    // After the signature, never before. A forged id must not be waved through
    // by the simple expedient of not appearing on the list.
    guard !revoked.contains(claims.id) else {
      return .refused("licence \(claims.id) was revoked")
    }
    guard claims.major == major else {
      return .refused("key covers \(claims.major).x, this build is \(major).x")
    }

    return .valid(
      License(id: claims.id, email: claims.email, major: claims.major, issuedAt: claims.issuedAt))
  }

  // MARK: - Internals

  private struct Claims: Decodable {
    let id: String
    let email: String
    let major: Int
    let issuedAt: String
  }

  private static var signer: Curve25519.Signing.PublicKey? {
    guard let raw = base64Url(publicKey), !raw.isEmpty else { return nil }
    return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
  }

  /// base64url, which is what a key pasted out of an email survives. Standard
  /// base64's `+` and `/` do not survive a URL, and its `=` padding does not
  /// survive a careless copy.
  private static func base64Url(_ text: String) -> Data? {
    var padded = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded.append("=") }
    return Data(base64Encoded: padded)
  }
}
