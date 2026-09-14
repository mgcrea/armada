#!/usr/bin/env node
// Refuse to ship a Sparkle signature the app would refuse to install.
//
// `make appcast` runs this over the stapled zip, with the signature `sign_update`
// just printed and SUPublicEDKey read from the built app. Why the key has to be
// checked at all, and why not with `sign_update --verify`, is in
// `lib/ed-signature.mjs`.
//
//   node scripts/verify-ed-signature.mjs <file> <edSignature> <SUPublicEDKey>
//
// Exits 0 when the signature is valid over the file for that key, 1 when it is
// not, and 2 on a usage error or an argument that is not what it claims to be.
import { readFileSync } from "node:fs";

import { verifyEdSignature } from "./lib/ed-signature.mjs";

const [file, signature, publicKey] = process.argv.slice(2);
if (!file || signature === undefined || publicKey === undefined) {
  console.error("usage: verify-ed-signature.mjs <file> <edSignature> <SUPublicEDKey>");
  process.exit(2);
}

let valid;
try {
  valid = verifyEdSignature({ data: readFileSync(file), signature, publicKey });
} catch (error) {
  console.error(`verify-ed-signature: ${error instanceof Error ? error.message : error}`);
  process.exit(2);
}

if (!valid) {
  console.error(`verify-ed-signature: the signature over ${file} was not made by ${publicKey}.`);
  console.error("Sparkle in every installed copy would refuse this update.");
  process.exit(1);
}
console.log(`  edSignature over ${file} verifies against ${publicKey}`);
