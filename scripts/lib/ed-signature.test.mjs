import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { verifyEdSignature } from "./ed-signature.mjs";

/**
 * The failure this guards against ships green.
 *
 * A signature made by the wrong key is still an 88-character base64 string, the
 * feed it lands in still passes xmllint, and the release still publishes. Only an
 * installed copy notices, by refusing the update, and it cannot say why. So the
 * cases that matter most here are the ones that answer `false` for a signature
 * that looks perfect.
 */

const hex = (value) => Buffer.from(value, "hex");
const base64 = (bytes) => bytes.toString("base64");

/** A fresh keypair: the public half as SUPublicEDKey carries it, and a signer. */
const keypair = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const x = publicKey.export({ format: "jwk" }).x ?? "";
  return {
    publicKey: base64(Buffer.from(x, "base64url")),
    sign: (data) => base64(sign(null, data, privateKey)),
  };
};

describe("verifyEdSignature", () => {
  const archive = Buffer.from("not a real zip, but bytes all the same");
  const ours = keypair();
  const theirs = keypair();

  it("accepts RFC 8032's second Ed25519 test vector", () => {
    // Bytes no code in this process produced, so a wrong SPKI header cannot hide
    // behind Node exporting and re-importing its own key.
    const valid = verifyEdSignature({
      data: hex("72"),
      publicKey: base64(hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")),
      signature: base64(
        hex(
          "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da" +
            "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
        ),
      ),
    });
    assert.equal(valid, true);
  });

  it("accepts a signature made by the matching key", () => {
    const signature = ours.sign(archive);
    assert.equal(verifyEdSignature({ data: archive, signature, publicKey: ours.publicKey }), true);
  });

  it("refuses the right key's signature over different bytes", () => {
    const signature = ours.sign(archive);
    const tampered = Buffer.from(archive);
    tampered[tampered.length - 1] ^= 1;
    assert.equal(
      verifyEdSignature({ data: tampered, signature, publicKey: ours.publicKey }),
      false,
    );
  });

  it("refuses a well-formed signature made by any other key", () => {
    // The case this exists for: CI handed a private key that is not the other
    // half of the SUPublicEDKey compiled into the app.
    const signature = theirs.sign(archive);
    assert.equal(verifyEdSignature({ data: archive, signature, publicKey: ours.publicKey }), false);
  });

  it("throws on a signature or a key that is not one, rather than answering false", () => {
    const signature = ours.sign(archive);
    for (const bad of [
      `${signature}\n${signature}`,
      `${signature}\n`,
      `sparkle:edSignature="${signature}" length="${archive.length}"`,
      signature.slice(0, -2),
      "",
    ]) {
      assert.throws(
        () => verifyEdSignature({ data: archive, signature: bad, publicKey: ours.publicKey }),
        TypeError,
        JSON.stringify(bad),
      );
    }
    for (const bad of [
      ours.publicKey.slice(0, -1),
      `${ours.publicKey}\n`,
      base64(Buffer.alloc(33)),
    ]) {
      assert.throws(
        () => verifyEdSignature({ data: archive, signature, publicKey: bad }),
        TypeError,
        JSON.stringify(bad),
      );
    }
  });
});

describe("verify-ed-signature.mjs", () => {
  const cli = join(dirname(dirname(fileURLToPath(import.meta.url))), "verify-ed-signature.mjs");
  const dir = mkdtempSync(join(tmpdir(), "verify-ed-signature-"));
  const zip = join(dir, "Armada.zip");
  const data = Buffer.from("the stapled zip");
  writeFileSync(zip, data);
  after(() => rmSync(dir, { recursive: true, force: true }));

  const ours = keypair();
  const theirs = keypair();
  const run = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });

  it("exits 0 for the app's own key, 1 for another key, and 2 for anything malformed", () => {
    const signature = ours.sign(data);
    assert.equal(run(zip, signature, ours.publicKey).status, 0);
    assert.equal(run(zip, signature, theirs.publicKey).status, 1);
    assert.equal(run(zip, "not-a-signature", ours.publicKey).status, 2);
    assert.equal(run(join(dir, "missing.zip"), signature, ours.publicKey).status, 2);
    assert.equal(run(zip).status, 2);
  });
});
