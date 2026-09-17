/**
 * Every fact that changes between releases lives here, and nowhere else.
 * Components and the JSON-LD both read from this file, so the first release is a
 * handful of edits in one place rather than a search through the pages.
 *
 * The repo is the authority on all of it. If something here disagrees with the
 * root README, SECURITY.md or CHANGELOG.md, the tree is right and this file is
 * stale.
 */

export const SITE_DOMAIN = "armada.mgcrea.io";
export const SITE_URL = `https://${SITE_DOMAIN}`;

export const APP_NAME = "Armada";
/** The release configuration's identifier; Debug builds carry a `.debug` suffix. */
export const BUNDLE_ID = "io.mgcrea.armada";

export const REPO_URL = "https://github.com/mgcrea/armada";

/**
 * Whether REPO_URL answers for a visitor.
 *
 * True from 2026-09-14, when mgcrea/armada was made public. Gated separately from
 * SHIPPED because the two need not flip together, but the release zip and appcast
 * live under that repo's releases, so it has to be public by the time SHIPPED is.
 */
export const REPO_PUBLIC = true;

export const DOCS = {
  security: `${REPO_URL}/blob/main/SECURITY.md`,
  audit: `${REPO_URL}/blob/main/scripts/audit-network.sh`,
  /** The app's own licence: source-available, not the repo-root MIT. */
  sourceLicense: `${REPO_URL}/blob/main/apps/apple/LICENSE`,
} as const;

/**
 * The public tracker. The shared `mgcrea/support` repo rather than one of
 * Armada's own, matching `trackerURL` in apps/apple/Armada/Support.swift.
 */
export const ISSUES_URL = "https://github.com/mgcrea/support/issues";

/**
 * This project's slug in the shared feedback contract.
 *
 * Must match `Support.app.slug` in apps/apple/Armada/Support.swift, and must be
 * one of `APP_SLUGS` in `@mgcrea/feedback-contract` for the Worker to accept a
 * submission. It was NOT in that list on 2026-09-14 (neither the published 0.2.0
 * nor the unpublished 0.3.0), so until the contract and the Worker are updated
 * every submission from /feedback/ is answered with a 400.
 */
export const APP_SLUG = "armada";

export const SUPPORT_EMAIL = "support@mgcrea.io";
export const SUPPORT_EMAIL_HREF = `mailto:${SUPPORT_EMAIL}`;

/**
 * The feedback Worker's origin, shared by every mgcrea site.
 *
 * **Adding this to `connect-src` in the Astro config is not optional**: the
 * browser refuses the POST at runtime and the form silently does nothing, with no
 * build error. `pnpm feedback:check` asserts it survives into the emitted policy.
 */
export const FEEDBACK_API = "https://feedback.mgcrea.io";

/** The feedback form on this site. */
export const FEEDBACK_URL = "/feedback/";

/**
 * The account X attributes the card to. `twitter:site` and `twitter:creator` are
 * the same handle because they are the same person.
 */
export const X_HANDLE = "@mgcrea";

/**
 * The Cloudflare Web Analytics site token, or null while there is none.
 *
 * Each sibling has its own token, and one for armada.mgcrea.io has to be created
 * in the Cloudflare dashboard. Until it is, Layout.astro renders no beacon and the
 * privacy page does not describe one: a beacon with a borrowed token would count
 * this site's visits into another site's report.
 */
export const CF_ANALYTICS_TOKEN: string | null = null;

/**
 * Whether there is something to download. True from 1.0.0, 2026-09-14.
 *
 * It gates the JSON-LD `downloadUrl`, `softwareVersion` and `offers`. It used to
 * gate every Download and Buy button and the version pill too, with a "coming
 * soon" version of each; those branches were removed once 1.0.0 was out, so
 * setting this back to false would no longer hide them.
 *
 * It needs a published release under REPO_URL (so /download resolves) and
 * REPO_PUBLIC true. Whether a licence can be bought is SELLING, not this.
 */
export const SHIPPED = true;

/**
 * Whether /buy resolves to a live payment link.
 *
 * The website's mirror of `LicenseLinks.isSelling` in
 * apps/apple/Armada/LicensePane.swift, true on both sides since 2026-09-14. It
 * gates the prose that says whether anything is on sale, on /terms, /support and
 * /privacy. SHIPPED used to, and so those pages said nothing was for sale while
 * /buy was taking payments.
 */
export const SELLING = true;

/**
 * The newest release's version, as a bare marketing version. CI refuses an
 * `app-v` tag this disagrees with. Shown only when SHIPPED: a version printed
 * before there is a release names something nobody can download.
 */
export const APP_VERSION = "1.2.0";

/**
 * The release lives on GitHub, never on this site. The vanity paths are in
 * public/_redirects, and point at `latest/download`, which is why the release
 * asset carries no version in its name.
 */
export const DOWNLOAD = {
  href: "/download",
  checksum: "/checksum",
  releases: "/releases",
  /** The feed the update check reads. Stated on the page, so it is a constant. */
  appcast: `${SITE_DOMAIN}/appcast.xml`,
  /** macOS 26 or later: the icon is an Icon Composer bundle, which nothing older renders. */
  requires: "macOS 26 or later",
} as const;

/**
 * The evaluation window. Started from a button, never armed on its own, and held
 * in memory rather than written to disk. Repeated by hand in public/llms.txt; see
 * PRICING.
 */
export const TRIAL = { minutes: 30 } as const;

/**
 * The price, as it will be charged. Two currencies, both to be set explicitly on
 * the Stripe price via `currency_options`, never one converted from the other,
 * the way bastion and cupertino sell.
 *
 * The USD figure is quoted tax-exclusive and the EUR figure VAT-inclusive, the
 * ordinary convention on each side. The two numbers are not meant to be equal,
 * so `Pricing.astro` shows both rather than picking one.
 *
 * public/llms.txt repeats this and TRIAL by hand, as prose: it is a static file
 * nothing renders from here. A price, a refund window or a trial length changed
 * here is a second edit there.
 */
export const PRICING = {
  /** Display form. `amount` is what the JSON-LD offer carries. */
  price: "$14.99",
  amount: "14.99",
  currency: "USD",
  /** Shown alongside, VAT included, as EU buyers are quoted and charged. */
  eur: { price: "€14.99", amount: "14.99", currency: "EUR" },
  /** The stable vanity URL: a 302 in public/_redirects to the live Stripe payment link. */
  buy: "/buy",
  /** Written as a fragment, so a call site capitalises it where a sentence starts. */
  covers: "every 1.x release, on every Mac you own",
  refundDays: 30,
} as const;

/**
 * The og:image card. `pnpm icons` bakes these lines into `og-image.png`, so
 * editing them here is only half the change: re-run it, or the picture and the
 * page disagree.
 *
 * They do not repeat the page title. X renders og:title beneath the image, so a
 * card that restates it spends its one visual asset on words already on screen.
 *
 * The card composer does not fit text: both lines are a fixed size, centred, with
 * no measuring and no wrap. Keep them short.
 */
export const SOCIAL_CARD = {
  headline: "Every Claude Code and Codex session, on one screen",
  subhead: "Session state · context windows · 5-hour and 7-day limits",
  alt: "The Armada icon, two sails on warm water, above the word Armada, the line “Every Claude Code and Codex session, on one screen”, and “Session state · context windows · 5-hour and 7-day limits”.",
  width: 1200,
  height: 630,
} as const;

/**
 * The sibling apps, cross-linked from the homepage and the footer. One constant
 * feeds both placements, so a name, a URL or an icon cannot drift between them.
 *
 * Neither pitch claims the apps work together. Nothing in any of the three repos
 * documents an integration, and a cross-promo card is the worst place to invent
 * one. What is true is that all three are menu bar apps for people who work with
 * agents, sold the same way.
 *
 * The icons are the siblings' own `public/app-icon.svg`, copied into `public/apps/`
 * rather than hotlinked, because astro.config.mjs sets `img-src 'self' data:` and
 * a cross-origin image is blocked with nothing on screen and nothing in the build
 * log. Nothing keeps these copies fresh: `pnpm icons` only generates Armada's mark.
 */
export const SIBLING_APPS = [
  {
    name: "Bastion",
    tagline: "One MCP server, running once.",
    pitch:
      "A menu bar app that supervises the MCP servers your agents connect to: one process per profile instead of one per editor, credentials in the Keychain, and every tool call recorded.",
    blurb: "One supervised MCP process per profile, credentials in the Keychain.",
    url: "https://bastion.mgcrea.io",
    icon: "/apps/bastion.svg",
  },
  {
    name: "Cupertino",
    tagline: "Your Apple apps, as MCP servers.",
    pitch:
      "Mail, Notes, Calendar, Messages and the rest of the Apple apps already on your Mac, served to any agent that speaks MCP, behind one Full Disk Access grant held by a signed menu bar app.",
    blurb: "Your Apple apps as MCP servers, behind one Full Disk Access grant.",
    url: "https://cupertino.mgcrea.io",
    icon: "/apps/cupertino.svg",
  },
] as const;
