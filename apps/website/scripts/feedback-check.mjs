#!/usr/bin/env node
/**
 * Assert the built /feedback page is actually wired up. Cupertino's script, with
 * one assertion added for Armada.
 *
 * Most of what is checked here fails at runtime, in the browser, with nothing in
 * the build to warn you:
 *
 * 1. **The CSP origin.** Omit the Worker's origin from `connect-src` and the page
 *    renders perfectly, the user types a report, presses Send, and the browser
 *    refuses the fetch.
 * 2. **The field names.** They are a contract with a Worker in another repo,
 *    deployed on its own schedule. A rename lands the row with one column empty.
 * 3. **No hidden diagnostics.** The privacy page promises the four facts are
 *    visible, editable and deletable. A `type="hidden"` or `readonly` on one of
 *    them turns that promise into marketing, so it fails here instead.
 * 4. **Something must link to the page.** Cupertino's form once went live orphaned.
 * 5. **No button may inherit its colour from the prose layer.** A descendant
 *    anchor rule outranks every Tailwind colour utility on a button anchor.
 * 6. **The slug is one the contract names.** Added for Armada, whose slug was not
 *    in `APP_SLUGS` when this site was built. This one warns rather than fails:
 *    the installed contract is whatever npm had, and the Worker validates against
 *    its own workspace copy, so the installed list is evidence, not the authority.
 *
 * Run after `astro build`. Reads `dist/` only and never starts a server.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { APP_SLUGS, PARAM } from "@mgcrea/feedback-contract";

import { APP_SLUG, FEEDBACK_API } from "../src/config.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const page = join(root, "dist", "feedback", "index.html");

let html;
try {
  html = readFileSync(page, "utf8");
} catch {
  console.error(`feedback:check: ${page} is missing. Run \`pnpm build\` first.`);
  process.exit(1);
}

const failures = [];
const warnings = [];

// 1. Conditional on purpose: where there is no CSP the browser imposes nothing.
const csp = html.match(/connect-src [^;"]*/)?.[0];
if (csp && !csp.includes(FEEDBACK_API)) {
  failures.push(
    `CSP does not allow the feedback Worker.\n` +
      `    expected to contain: ${FEEDBACK_API}\n` +
      `    emitted:             ${csp}\n` +
      `    fix: add it to security.csp.directives in astro.config.mjs`,
  );
}

// 2. The form posts these names; the Worker's zod schema reads them.
const bodyFields = [
  "kind",
  "subject",
  "body",
  "email",
  "appVersion",
  "osVersion",
  "hardware",
  "language",
];
for (const name of bodyFields) {
  if (!html.includes(`name="${name}"`)) failures.push(`form is missing the "${name}" field`);
}
if (!html.includes('name="website"')) failures.push('the "website" honeypot is missing');

for (const [key, param] of Object.entries(PARAM)) {
  if (!param) failures.push(`contract PARAM.${key} is empty`);
}

// 3. The promise, enforced.
for (const name of ["appVersion", "osVersion", "hardware", "language"]) {
  const tag = html.match(new RegExp(`<input[^>]*name="${name}"[^>]*>`))?.[0] ?? "";
  const locked = tag.match(/type="hidden"|readonly|disabled/)?.[0];
  if (locked) {
    failures.push(
      `"${name}" is not editable by the user (${locked}).\n` +
        `    The privacy page promises these four are visible, editable and deletable.`,
    );
  }
}

// 4. Reachability. Scan every built page for a link to the form.
const pages = [];
const walk = (dir) => {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walk(full);
    else if (entry.endsWith(".html")) pages.push(full);
  }
};
walk(join(root, "dist"));

const linkers = pages.filter((f) => {
  if (f === page) return false; // the form linking to itself proves nothing
  return /href="\/feedback\/?"/.test(readFileSync(f, "utf8"));
});
if (linkers.length === 0) {
  failures.push(
    `nothing links to /feedback/; the page is reachable only by typing the URL.\n` +
      `    Checked ${pages.length} built pages.\n` +
      `    fix: add it to the footer, and to the support page`,
  );
}

// 5. No prose layout may style bare `a` at a specificity Tailwind cannot beat.
const unscopedAnchorRule = /\.[a-z-]+\[data-astro-cid-[^\]]+\]\s*a\s*\{[^}]*color:/;
const unscopedVariant = /\[&_a\]:(text|decoration|underline)/;
for (const file of pages) {
  const source = readFileSync(file, "utf8");
  const variant = source.match(unscopedVariant);
  if (variant) {
    failures.push(
      `${file.replace(root + "/", "")}: prose styles anchors with \`${variant[0]}\`.\n` +
        `    fix: write it as \`[&_a:not([class])]:…\``,
    );
  }
  const hit = source.match(unscopedAnchorRule);
  if (hit) {
    failures.push(
      `${file.replace(root + "/", "")}: a scoped layout styles bare \`a\` with a colour.\n` +
        `    ${hit[0].slice(0, 80)}…\n` +
        `    fix: scope the rule to \`a:not([class])\``,
    );
  }
}

// 6. The slug.
if (!APP_SLUGS.includes(APP_SLUG)) {
  warnings.push(
    `APP_SLUG "${APP_SLUG}" is not in the installed contract's APP_SLUGS (${APP_SLUGS.join(", ")}).\n` +
      `    The Worker answers an unknown slug with a 400, so the form cannot submit until\n` +
      `    mgcrea-feedback registers it and redeploys.`,
  );
}

for (const w of warnings) console.warn(`feedback:check WARNING: ${w}`);

if (failures.length) {
  console.error(`feedback:check FAILED (${failures.length}):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(
  `feedback:check ok: ${bodyFields.length} fields, honeypot, editable diagnostics, ` +
    `${csp ? `${FEEDBACK_API} in connect-src` : "no CSP on this site"}, ` +
    `linked from ${linkers.length} page(s)`,
);
