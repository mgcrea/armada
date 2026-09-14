// A Sparkle EdDSA signature, checked against the public key a build trusts.
//
// `sign_update` signs with whatever private key it is handed: the keychain item on
// a developer's Mac, SPARKLE_ED_PRIVATE_KEY in CI. A well-formed signature says
// nothing about whether that key is the other half of SUPublicEDKey compiled into
// the app, and a feed signed by any other key is refused by every installed copy.
// The refusal is silent, and permanent in practice: the fix would have to arrive
// as the very update being refused. So `make appcast` checks the signature over
// the zip against the key read out of the built Info.plist before writing a feed.
//
// Node's own crypto rather than `sign_update --verify`, which verifies against the
// signer's key (the keychain's, or the one in a key file) and so cannot catch the
// mismatch this exists for. No dependency: this runs on the one target that signs
// a release.
//
// Sparkle signs the archive's bytes directly, not a digest of them, and stores the
// raw 32-byte Ed25519 public key in base64. Node takes a key as SPKI DER, which for
// Ed25519 is a fixed 12-byte header (RFC 8410) in front of those same 32 bytes.

import { createPublicKey, verify } from "node:crypto";

const SPKI_HEADER = Buffer.from("302a300506032b6570032100", "hex");

/** 32 bytes in base64: 43 characters and one `=`. The shape of SUPublicEDKey. */
export const PUBLIC_KEY_PATTERN = /^[A-Za-z0-9+/]{43}=$/;

/** 64 bytes in base64: 86 characters and `==`. The shape of an `edSignature`. */
export const SIGNATURE_PATTERN = /^[A-Za-z0-9+/]{86}==$/;

/**
 * Whether `signature` is a valid Ed25519 signature over `data` by `publicKey`.
 *
 * Throws, rather than answering false, on a key or a signature that is not one:
 * a signature with a second line after it, or with `sign_update`'s attributes
 * still around it, is a bug in whatever extracted it, and "does not verify" would
 * send someone looking for the wrong key. The patterns are anchored on the whole
 * string, and without the `m` flag, so trailing lines fail them.
 *
 * @param {{ data: Buffer, signature: string, publicKey: string }} input
 * @returns {boolean}
 */
export const verifyEdSignature = ({ data, signature, publicKey }) => {
  if (!PUBLIC_KEY_PATTERN.test(publicKey)) {
    throw new TypeError(`not a base64 Ed25519 public key: ${JSON.stringify(publicKey)}`);
  }
  if (!SIGNATURE_PATTERN.test(signature)) {
    throw new TypeError(`not one base64 Ed25519 signature: ${JSON.stringify(signature)}`);
  }
  const key = createPublicKey({
    key: Buffer.concat([SPKI_HEADER, Buffer.from(publicKey, "base64")]),
    format: "der",
    type: "spki",
  });
  return verify(null, data, key, Buffer.from(signature, "base64"));
};
