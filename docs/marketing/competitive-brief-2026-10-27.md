# Armada competitive brief: refresh

- **Research date:** 2026-10-27. This is a delta on
  [competitive-brief-2026-10-09.md](competitive-brief-2026-10-09.md). Read that one for the full
  profiles, narrative analysis and the positioning method; this one says what moved in 18 days and
  what that changes.
- **Baseline (ours):** Armada **1.11.0**, tagged `app-v1.11.0` on 2026-10-18 (talk over a spoken
  reply, the supervisor's MCP light in the toolbar and menu bar, Add to Bastion, about 20 fixes).
  `APP_VERSION = "1.11.0"` in `apps/website/src/config.ts`. Price unchanged: $14.99 / €14.99 once.
- **Method:** desk research. GitHub API for every open-source rival (stars, releases since
  2026-10-09, release notes), vendor pages and changelogs, the Claude Code CHANGELOG, HN Algolia,
  Reddit and Product Hunt. "They have" still means "they say they have"; nothing was tested
  hands-on.
- **Not available:** no SEO or traffic tool, so there are no rankings or traffic numbers. Product
  Hunt dates and vote counts could not be confirmed beyond two listing pages.
- **Evidence grades:** (P) primary: repo, release, vendor page, changelog. (S) secondary: Reddit,
  HN, Product Hunt, trade press. *unverified* marks a claim we could not confirm.

---

## 1. Executive summary

The 10-09 brief said the top-left quadrant (watch the sessions you already run *and* act across
accounts) was Armada's alone. **That is no longer true as a headline.** In September and October
at least three tools started saying "switch accounts" out loud. Pitboard's whole tagline is
"Switch AI coding tools between your accounts". TokenEater 6.1 put several Claude accounts side by
side, and Tellurion restarts an agent on another sign-in. Codenotch (2,931 stars in seven weeks,
free) shows limits and "waiting on you" in a notch for Claude, Codex and Grok, across several
profiles per vendor.

What is still Armada's alone is narrower and more precise. It carries **a Claude Code
conversation** to another account through Claude Code's own fork, keeps the original, and works
for sessions started anywhere, including the VS Code extension and ended ones. It does this
**without ever holding a login**. (Codex and Grok Build sessions do not move between accounts;
Codex forks stay inside their own home.) Pitboard
moves logins: it keeps the other accounts' logins parked and swaps them in. Tellurion and Claudexor
only reach agents that run inside their own runtime.

- **Biggest opportunity:** say that precise claim now, while it is still true. The homepage still
  leads with "which one is waiting on you", which Codenotch, Muster, c9watch, Vibe Island and
  Coucou all say too. Meanwhile Reddit's October threads on limit opacity (an A/B-testing claim at
  336 points; "53% of my limit is already wiped" at 186 points and 223 comments) show that people
  with several accounts are angry and looking for something.
- **Biggest threat:** a free tool assembling Armada's full set before Armada says what it is.
  Codenotch already has limits, waiting state and Grok. CodexBar ships every two days and deepened
  multi-account in four of its last ten releases. Neither moves a conversation today.
- **None of the five 10-09 recommendations has shipped.** See section 7.

## 2. What changed since 2026-10-09

### Tracked rivals

| Tool | 10-09 | 2026-10-27 | What moved | Grade |
| --- | --- | --- | --- | --- |
| **CodexBar** | 22,345★, v0.73.0 | 22,845★, v0.82.0 (10-26), 10 releases | 110 providers (v0.81). **Multi-account deepened:** one Overview row per claude-swap, managed Codex and token account (v0.78, 10-19); each token account mapped to its own Claude config dir (v0.77, 10-16); usage read from the Claude desktop app's session; per-session request inspection in Usage & Spend (v0.81); iCloud fleet usage (v0.80). No PR titled for permission, waiting or approval since 10-01. | P |
| **Coucou** | ~4,453★, 0.2.3 | **6,595★**, v0.5.3 (10-22), 19 releases across Mac/Win/Linux/Android | Plan approval from the notch (0.5.2), Android app 0.3.0, WhatsApp in the notch, dictation, call recording. It is drifting into a general notch companion. README still names neither several accounts nor Grok. | P |
| **Vibe Island** | v1.0.51, $19.99 | v1.0.55 (10-23), $19.99 / 1 Mac / 1 yr updates | Usage alerts with sound at 80% / out / reset, iPhone alerts via Bark, Codex reset cards, answer Codex questions, background tasks and their ports (1.0.55). Custom agents beta, Claude Desktop waiting cards (1.0.53). Runs `/alternatives`, `/codexbar-alternative`, `/ccusage-alternative`. Doesn't mention Armada. | P |
| **SessionWatcher** | Bundle $14.99, rise announced | Rise confirmed: **"Prices go up Nov 1"**. Solo $6.99→$8.99, Bundle $14.99→$19.99, Pro $59→$79 lifetime. v7.5.7. | Multi-account is Pro only. Waiting/approval not mentioned. | P |
| **TokenEater** | 513★, v6.0.0 | 519★, v6.1.0 (10-24) | **"Several Claude accounts side by side"**, one usage store per account, and a custom `CLAUDE_CONFIG_DIR` folder that login, History and Agent Watchers follow. On Armada's ground for display, not for moving. | P |
| **c9watch** | 128★, v0.10.0 | 135★, v0.11.1 (10-15) | "While you were away" summary on waiting cards; Codex needs-you; **`c9watch wait`** (blocks until a session needs you, like `armada_wait`); a published status-accuracy matrix; counts Claude Code child sessions Claude hides. | P |
| **Claudexor** | v3.24.0, 497★ | v4.7.0 (10-22), 519★, 15 releases | v4.0 moves the engine to SQLite. Accounts expose balances, spend and resets over API/MCP (3.25.1). Account-aware model routing (4.5). Still a runtime you log in through. | P |
| **Agent Sessions** (jazzyalex) | 895★, v5.6 | 918★, v6.1.2 (10-26) | Quota meter in the notch (6.0). **Reads Codex's compressed `.jsonl.zst` rollouts** since 5.7 (10-15), the gap `PLAN.md` lists as "bites now" for Armada. | P |
| **Claudoscope** | 242★, v1.4.0 | 262★, v1.4.1 (10-26) | Fixes for handoff double-billing and parked terminals counted as live. Claude only. | P |
| **Agent Cat** | 9,766 downloads | Unchanged claim, v26.35.1 | Free; every logged-in account; suggests another account when one is blocked. No waiting state. | P |
| **Conductor** | 0.90.0 | 0.92.0 "Remote control" (10-23) | Titles only on the index; nothing about limits or outside sessions. | P |
| ccusage / cmux / Superset / Happy / Claw | | 19,194★ / 28,540★ / 15,621★ / 24,343★ / 601★ | Steady releases; no change to how they position against Armada. | P |
| Claude Usage Tracker, Claude Squad, Usage4Claude, Claude Control | | No release since 10-09 | Quiet. | P |

### New entrants (not in the 10-09 brief)

| Tool | Positioning (their words) | Waiting state | Accounts | Price | Traction | Grade |
| --- | --- | --- | --- | --- | --- | --- |
| **Codenotch** (vinzdg) | "pins a small black notch to a screen edge, showing how much of each coding assistant's usage limit you have burned — and whether it is still working, done, or waiting on you" | Yes | Several Claude and Codex profiles (`~/.codex-<slug>`; "just as it does for Claude"); reads each Codex profile's `auth.json` | Free, MIT, "macOS 15 or later" (its badge says 26+), signed and notarized | **2,931★**, created 2026-09-05 | P |
| **Pitboard** | "Switch AI coding tools between your accounts." Parks each account's login and swaps it in; "Open Claude Code sessions follow a switch with no restart"; offers another account at 95% | No | **Core feature**, by moving logins | Free, Apache-2.0; macOS, Windows beta | 101★, created 2026-09-21 | P |
| **Tellurion** | "Mission control for AI coding agents", a Ghostty fork | Yes, with Allow/Deny | "use more than one Claude Code or Codex sign-in… and restart a tile's agent on another"; points at each account's folder, reads no sign-in details | Free, AGPL | 134★; r/ClaudeCode 31 pts (10-25) | P (S for Reddit) |
| **Crest** | "Answer Claude Code approvals from your MacBook's notch" (a general notch app) | Yes, via hooks | Not mentioned | **$14.99 once, 2 Macs**; Pro warns before limits | Show HN 6 pts (09-23) | P |
| **Muster** (josefchen) | "Never keep an agent waiting." Menu bar, Claude Code, Codex, Cursor | Yes; answer with one keystroke | "no accounts" | Free, MIT | 71★; two Show HNs on 10-13 (3 and 1 pts) | P |
| **herdr** + herdr-gpui | "the runtime your coding agents live on"; panes working / blocked / idle | Yes | *unverified* | Free | **46,107★** (missed in the 10-09 brief; created 2026-03); herdr-gpui 1,713★ | P |
| BlackFlare | "Mission control for Claude Code & Codex in your menu bar" | Yes (Claude, via hooks) | Not mentioned | *unverified* | Product Hunt 96 upvotes, date *unverified* | S |
| Runnock | Notch status island; covers Grok Build; macOS 26+ | Yes | Not mentioned | Paid once, amount *unverified* | Product Hunt 2 upvotes | S |

Smaller ones: hallmonitor (notch, waiting, context, limits, SSH), Littleguys, barn.app, Shrine,
AILSA SubSwitch, claude-transplant, Limitbreak (switches account mid-session at a limit, 4★),
ClaudeBar (1,557★, older). No Show HN in this niche passed 30 points between 09-01 and 10-27 (S, HN
Algolia).

### First party

- **Claude Code** 2.1.296 to **2.1.311**: nothing in the CHANGELOG makes agent view list
  interactive sessions, spans accounts or changes `rate_limits`. Agent view gained `/effort` and
  `/fast` (P). The 10-09 citation that agent view and the Desktop Code tab can't see editor
  sessions still stands as far as the CHANGELOG shows.
- **Claude Desktop** reportedly got a sessions hub with live status per session on 2026-10-14, and
  the Claude iOS app sign-in to several accounts on 2026-10-04 (S, r/ClaudeCode citing @ClaudeDevs;
  *unverified*). If the hub reaches CLI and VS Code sessions, it hits Armada's core claim:
  **check this first**.
- **Limits:** no official change found in October. The 2026-09-14 permanent +25% (a net 17% cut
  from the promo level) is the last one (T). Sentiment is the news: "SemiAnalysis claims Anthropic
  is A/B Testing Usage Limits" (r/ClaudeCode, 336 pts, 10-22) and a "53% wiped" reset thread
  (186 pts, 223 comments, 10-24). In both, the only tool people named was ccusage. Commenters ask
  how many tokens one percent of the weekly meter buys, and mention running "three 20x max
  accounts" (S).

## 3. Messaging matrix: changes only

Rows from the 10-09 matrix that moved, plus the two new tools that matter most.

| | **Armada** | Codenotch | Pitboard | TokenEater | Vibe Island | SessionWatcher |
| --- | --- | --- | --- | --- | --- | --- |
| Tagline | "Nineteen agents running. One window that knows." | "…how much of each coding assistant's usage limit you have burned — and whether it is still working, done, or waiting on you" | "Switch AI coding tools between your accounts." | "monitor AI usage limits and watch your coding sessions live" | "Dynamic Island for your AI agents" | "Never Lose a Coding Session to Rate Limits" |
| Accounts | Several, side by side; **moves a Claude Code conversation** via its own fork; holds no login | Several profiles per vendor | Swaps the **login** under the session | Several, side by side (6.1) | Several (since 1.0.48) | Several, Pro only |
| Waiting state | Yes (registry `waitingFor`) | Yes | No | Partial | Yes, with approvals | No |
| Price after 11-01 | $14.99 once, every Mac, every 1.x | Free | Free | Free | $19.99 / Mac / 1 yr updates | Bundle $19.99, Pro $79 |

Read: on price, Armada becomes the cheapest paid tool with this vendor coverage on 11-01, tied
only with Crest, which covers fewer agents. On message, "across accounts" no longer separates it
from anyone. The difference is in the verbs. Others *display* accounts or *swap logins*; Armada
*continues the conversation* elsewhere and never touches a credential.

## 4. Positioning map, revisited

The 10-09 axes still hold: who runs the agent, against what you can do across accounts. The
top-left is no longer empty. It has split in two:

```text
                     Acts across accounts
                              ^
   ARMADA: moves the          |   Tellurion: restarts a tile on
   conversation, no logins    |     another sign-in (its own terminal)
   Pitboard: swaps the login  |   Claudexor: rotates inside its runtime
     under any session        |
  Watches what you  ----------+----------  Runs agents in its
  already run                 |            own runtime
   Codenotch, TokenEater 6.1, |   herdr, cmux, Conductor, Superset,
   CodexBar, Vibe Island,     |     Emdash, Claw Orchestrator
   Agent Cat, Coucou, c9watch,|
   Muster, SessionWatcher     |
                              v
                     Shows numbers per account
```

Pitboard is the one to watch. It is the only other tool acting across accounts on sessions you
already run, and it is free. But it works by holding every account's login on the Mac and
swapping it in place. That is the exact design `docs/limits-accounts-and-terms.md` chose not to
build, and Armada's `make audit` can prove it never does. **Category strategy: reframe.** Don't
fight on "multi-account", which everyone now says. Make the buyer ask *how* a tool moves you
between accounts, where Armada's answer (the vendor's own fork, no credentials, the original kept)
is the safest one.

## 5. Content gaps: changes only

- **Comparison pages:** Vibe Island now has three (`/alternatives`, `/codexbar-alternative`,
  `/ccusage-alternative`). Armada still has none.
- **Limit-opacity content:** the October threads have no tool answering them except ccusage. Before
  writing about this, check whether Armada's own ledger can actually say "what one percent of your
  weekly limit bought" (see opportunity 3). No rival publishes that.
- **Status accuracy:** c9watch publishes an accuracy matrix of agent × situation. Armada's docs
  have deeper measurements (`docs/claude-code-sessions.md`, `docs/implementation.md`) but no
  one-page summary a buyer would read.
- **Homebrew cask:** still missing, still the norm in this niche.

## 6. Opportunities and threats

### Opportunities

1. **Make "how" the battleground.** Three new tools say they switch accounts. Only Armada can say
   it moves the conversation *without your logins*, and prove it. Pitboard's own README describes
   keeping parked logins. The claim is concrete, demonstrable in a 20-second clip, and on a topic
   people are angry about this month.
2. **Price lands on 11-01 without lifting a finger.** SessionWatcher's Bundle goes to $19.99 and
   Vibe Island stays at $19.99 per Mac with one year of updates. "Every Mac, every 1.x, $14.99"
   becomes a clean line to put next to them on a compare page.
3. **Limit opacity is a content and possibly a product opening.** People want to know how many
   tokens one percent of the weekly meter buys. Armada reads the weekly percentage from `claude`
   and counts tokens from transcripts, so the ingredients may already be there. This is a
   *candidate* feature only. Run it through `docs/market-intel.md`'s gates before building or
   claiming anything.
4. **Coucou is drifting away.** WhatsApp, dictation and call recording widen it into a general
   notch buddy. The fastest-growing rival is leaving the "serious fleet monitor" spot rather than
   taking it.

### Threats

1. **Codenotch.** It is free, MIT, macOS 15+, and signed. It asks the installed `claude` for
   `/usage`, the same mechanism Armada uses, and has waiting state, Grok and several
   accounts. It is the nearest free copy of Armada's surface. It doesn't move conversations or show
   context occupancy (*per its README*).
2. **Codex compressed logs.** Agent Sessions has read `.jsonl.zst` since 10-15. Armada undercounts
   Codex history on a new install (`PLAN.md`). A comparison page or a reviewer would expose that
   first.
3. **Claude Desktop's sessions hub (S, unverified).** If it shows CLI and VS Code sessions with
   status, the "nothing shows you all of them" premise weakens for single-account Claude users.
4. **CodexBar's account work.** Four of its last ten releases improved several-account display. A
   free default with 22.8k stars is a release away from "continue on another account". There's no
   sign of it, but its cadence is two days.
5. **Waiting state is now the entry ticket.** Muster's whole tagline is "Never keep an agent
   waiting"; c9watch added "while you were away"; Vibe Island adds sound alerts. Armada still posts
   no notification when a session starts waiting.

## 7. The 10-09 recommendations: scorecard

| 10-09 recommendation | Status 10-27 | Still right? |
| --- | --- | --- |
| Re-lead the homepage with the cross-account move | **Not done.** `Hero.astro` still leads with "which one is waiting on you" | Yes, and more urgent. Reword it around *how* (section 4) |
| Publish a Homebrew cask | **Not done** | Yes |
| Decide on a notification when a session starts waiting | **Not decided**; no entry in `docs/market-intel.md` | Yes; the dated evidence has grown (Muster, c9watch 0.11, Vibe Island 1.0.55) |
| A `/compare` page and a multiple-accounts guide | **Not done** | Yes; Vibe Island now has three such pages |
| Decide on approve-in-place | **Not decided** | Yes, lower than the four above |

## 8. Recommended actions

### Quick wins (this week)

1. **Change the hero's paragraph, not the headline.** Keep "Nineteen agents running" and add the
   move, scoped to Claude Code, which is the only vendor it covers. Every word of it is shipped
   (1.6.0 to 1.10.0) and provable (`make audit`). Drafts are in
   [hero-and-compare-draft-2026-10-27.md](hero-and-compare-draft-2026-10-27.md).
2. **Ship the `.jsonl.zst` archive half from `PLAN.md` (size S)** before any comparison page goes
   up. A rival already handles it, and the ledger half (M) can follow.
3. **Record the waiting-notification decision** in `docs/market-intel.md`, accepted or rejected,
   with the 10-27 evidence above. It has now been open since 2026-09-21.
4. **Verify the Claude Desktop sessions hub** hands-on: does it list a VS Code extension session
   and a second `CLAUDE_CONFIG_DIR`? The answer decides whether the site's "nothing shows you all
   of them" stays.

### Strategic moves

5. **`/compare` with a "how it moves you between accounts" table.** Armada, Pitboard, TokenEater,
   CodexBar, Vibe Island and Claude's own views, one row per mechanism (copies the conversation /
   swaps the login / displays only / runs its own agents), each cell cited to the vendor's own
   words. Factual, no adjectives. Do it after action 2.
6. **Homebrew cask**, carried over.
7. **Limit-opacity experiment.** Find out whether Armada's ledger can report what a weekly percent
   bought, per account, from data it already has. If it can, it is the one thing nobody in the
   October threads could point to. Gate it in the market-intel ledger first.

Not recommended: a price change (Armada is the cheapest paid option from 11-01), or chasing
approvals, phone apps or a notch to match Coucou, Vibe Island and Codenotch. That is the crowded
bottom-left.

---

## 9. Sources (accessed 2026-10-27)

Repo: `README.md`, `CHANGELOG.md`, `PLAN.md`, `docs/landscape.md`, `docs/market-intel.md`,
`docs/marketing/competitive-brief-2026-10-09.md`, `apps/website/src/components/Hero.astro`,
`apps/website/src/config.ts`, `git log --since=2026-10-09`.

- GitHub API (stars, releases, release bodies, READMEs): steipete/CodexBar, Louis-CFM/coucou,
  razzant/claudexor, AThevon/TokenEater, minchenlee/c9watch, cordwainersmith/Claudoscope,
  jazzyalex/agent-sessions, sverrirsig/claude-control, hamed-elfayome/Claude-Usage-Tracker,
  ccusage/ccusage, slopus/happy, superset-sh/superset, manaflow-ai/cmux, generalaction/emdash,
  smtg-ai/claude-squad, Enderfga/claw-orchestrator, f-is-h/Usage4Claude, mgcrea/armada,
  vinzdg/codenotch, datlechin/pitboard, steventsvik/Tellurion, josefchen/muster, herdrdev/herdr,
  penso/herdr-gpui
- https://vibeisland.app · https://vibeisland.app/changelog
- https://sessionwatcher.com
- https://agentcat.app/
- https://www.conductor.build/changelog
- https://crestnotch.app/claude-code-notch · https://usepitboard.com · https://agentmuster.app
- https://www.producthunt.com/products/blackflare · https://www.producthunt.com/products/runnock
- https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md (2.1.296 to 2.1.311)
- https://www.bleepingcomputer.com/news/artificial-intelligence/anthropic-is-cutting-claude-codes-current-weekly-limits-by-17-percent/
- r/ClaudeCode: "SemiAnalysis claims Anthropic is A/B Testing Usage Limits" (10-22); "Max plan
  reset… 53% of my limit is already wiped" (10-24); Tellurion post (10-25); Claude Desktop sessions
  hub post (10-14). r/ClaudeAI: "Claude Desktop's new UI…" (10-17)
- HN Algolia: Show HN since 2026-09-01; "Tmux and Claude Code: Sessions, Send-Keys, and the
  Ceiling" (10-19, 172 pts)

### Monitoring (next check about 2026-11-10)

- **Pitboard:** whether it adds a session list or waiting state. That would put it squarely
  top-left.
- **Codenotch:** watch for context occupancy or any move or
  continue feature.
- **CodexBar:** anything titled continue, fork, resume or move across accounts; Agent Sessions
  default-on.
- **Claude Desktop sessions hub:** which sessions it lists.
- **SessionWatcher:** that the 11-01 prices took effect.
- **Vibe Island:** any compare page naming Armada.
- **Armada's reach:** GitHub stars (0), Show HN (1 pt). Nothing moved in 18 days.
