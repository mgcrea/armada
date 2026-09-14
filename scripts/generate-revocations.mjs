#!/usr/bin/env node
// Bake the revoked licence IDs into the app.
//
// Revocation lands at BUILD time, not run time, and that is the whole shape of
// it. The app asks nobody anything — scripts/audit-network.sh fails the build
// over any connection beyond the opt-in update check — so there is no list it
// can consult while running. A refunded key therefore keeps working until the
// next release and then stops. That is said to the buyer rather than left to be
// discovered, on the site's /terms page.
//
// Generated-and-committed rather than fetched by CI. Reading D1 from the release
// job would put a network dependency in the path of shipping, so an outage at
// Cloudflare would become an outage in releases — and it would buy nothing,
// since a revocation cannot take effect before the next build either way. CI
// runs `--check` in the App job to confirm the committed file is current,
// and skips even that when it has no credentials, so forks and pull requests are
// unaffected.
//
//   node scripts/generate-revocations.mjs            # rewrite the Swift file
//   node scripts/generate-revocations.mjs --check    # fail if it is stale
//   node scripts/generate-revocations.mjs --local    # against the local D1

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// `fileURLToPath`, not `.pathname`: the latter leaves a checkout under a path
// with a space percent-encoded, and every path built from it then misses.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TARGET = join(ROOT, "apps/apple/Armada/Revocations.swift");
const API = join(ROOT, "apps/api");

const args = process.argv.slice(2);
const check = args.includes("--check");
const local = args.includes("--local");

// The skip is for --check only, and only for CI. A pull request from a fork has
// no secrets and neither does a clean clone; failing there would turn "we cannot
// confirm this" into "the build is broken", which it is not — the committed file
// is what the build uses.
//
// Writing is the opposite case and must never skip. A developer authenticates
// wrangler with `wrangler login`, not a token in the environment, so guarding the
// write path on CLOUDFLARE_API_TOKEN made `make revocations` print "skipped" and
// change nothing — after a refund, silently leaving the refunded key working
// while looking like it had been handled. Let wrangler's own auth decide, and
// let it fail loudly when there is none.
if (check && !local && !process.env.CLOUDFLARE_API_TOKEN) {
  console.log("skipped: no CLOUDFLARE_API_TOKEN, cannot confirm against D1");
  process.exit(0);
}

/**
 * The result rows out of `wrangler d1 execute --json`.
 *
 * The whole of stdout first, since that is what `--json` promises. Some wrangler
 * paths print a banner or a warning around the document, so failing that, try
 * each `[` in turn up to the last `]`. Slicing at the FIRST `[` broke on a
 * banner that contained one, such as a `[wrangler]` prefix. Whatever parses is
 * then checked for the shape read below, so a stray bracketed fragment that
 * happens to be valid JSON is refused rather than read as zero revocations.
 */
const resultsOf = (raw) => {
  const candidates = [raw];
  const end = raw.lastIndexOf("]");
  for (let at = raw.indexOf("["); at !== -1 && at < end; at = raw.indexOf("[", at + 1)) {
    candidates.push(raw.slice(at, end + 1));
  }
  for (const candidate of candidates) {
    let document;
    try {
      document = JSON.parse(candidate);
    } catch {
      continue;
    }
    if (Array.isArray(document) && Array.isArray(document[0]?.results)) {
      return document[0].results;
    }
  }
  throw new Error("no D1 result document in wrangler's output");
};

const query = "SELECT id FROM licenses WHERE revoked_at IS NOT NULL ORDER BY id";
let rows;
try {
  const raw = execFileSync(
    "pnpm",
    [
      "exec",
      "wrangler",
      "d1",
      "execute",
      "armada-licenses",
      local ? "--local" : "--remote",
      "--json",
      "--command",
      query,
    ],
    { cwd: API, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  rows = resultsOf(raw);
} catch (error) {
  console.error(`FATAL: could not read D1: ${String(error?.message ?? error)}`);
  process.exit(2);
}

const ids = rows
  .map((row) => row.id)
  .filter(Boolean)
  .toSorted();

const header = readFileSync(TARGET, "utf8").split("\nenum Revocations")[0];
// `JSON.stringify`, not string interpolation — the same escaper
// `generate-changelog.mjs` uses for every value it writes into Swift. These ids
// come from a DATABASE, which makes this the one string in the release path
// nobody in this repo chose, and a quote or a backslash in one would emit Swift
// that does not compile.
const swiftString = (value) => JSON.stringify(value);
const list =
  ids.length === 0 ? "[]" : `[\n${ids.map((id) => `    ${swiftString(id)},`).join("\n")}\n  ]`;
const next = `${header}\nenum Revocations {\n  static let ids: Set<String> = ${list}\n}\n`;

if (check) {
  if (readFileSync(TARGET, "utf8") === next) {
    console.log(`ok: ${ids.length} revoked licence(s), Revocations.swift is current`);
    process.exit(0);
  }
  console.error("FATAL: Revocations.swift is stale. Run `make revocations` and commit the result.");
  process.exit(1);
}

writeFileSync(TARGET, next);
console.log(`wrote ${ids.length} revoked licence(s) to apps/apple/Armada/Revocations.swift`);
