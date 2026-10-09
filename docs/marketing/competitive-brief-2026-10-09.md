# Armada competitive brief

- **Research date:** 2026-10-09
- **Scope:** native and cross-platform tools that tell one developer what their coding agents are doing and how much plan is left. Three groups: agent session monitors, usage/limit trackers, and parallel-agent orchestrators that compete for the same "I run many agents" buyer. First-party defaults from Anthropic, OpenAI and xAI are included.
- **Baseline (ours):** Armada **1.10.0**, tagged `app-v1.10.0` on 2026-10-05 and live on armada.mgcrea.io (`APP_VERSION = "1.10.0"` in `apps/website/src/config.ts`). Shipped, Developer ID signed and notarized, sold direct at **$14.99 / €14.99 once** for every 1.x on every Mac, 30-minute in-memory trial, 30-day refund, no account. macOS 26+. Source on GitHub (`apps/apple` source-available; docs/scripts MIT). Covers Claude Code (reference), Codex (labelled a spike) and Grok Build (newest, no waiting state yet). The coordinator's hint said 1.8.0; the repo has shipped 1.9.0 and 1.10.0 since.
- **Method:** desk research only. "They have" means "they say they have". No hands-on testing of competitors.
- **Not available:** no SEO or traffic tools were connected (Ahrefs and Similarweb unauthorized), so this brief contains no traffic, keyword-volume or ranking numbers. The web-search budget ran out before a Product Hunt pass for July to October launches and before review mining for the orchestrators; those gaps are marked where they matter.
- **Evidence grades:** (P) primary: vendor page, store listing, changelog, GitHub release or API. (T) trade press. (S) secondary: aggregator, directory, Reddit/HN comment. *unverified* marks anything we could not confirm.

---

## 1. Executive summary

Armada's category went from "eight free limit meters and five Claude-only monitors" in early September to a crowded field in five weeks: CodexBar (22k stars) now lists live sessions, a paid notch app (Vibe Island, $19.99) covers Claude Code, Codex and Grok with several accounts, and a free newcomer (Coucou, about 4.4k stars in 12 days) shows limits and approves prompts from the notch and the iPhone. Armada still has the deepest per-session reading (context occupancy, compaction, prompt-cache countdown, the registry's own `waitingFor`) and the only feature set built around **moving work between accounts** (Move, Continue on, History), but its distribution is close to zero: Show HN at 1 point, the X launch at 7 views, 0 GitHub stars.

- **Biggest opportunity:** own the multi-account story. Every rival either just displays several accounts or, like Claudexor, asks you to log in through it. Armada is the one that, when an account runs out, carries the live conversation to another account using the vendor's own fork, and it can prove it never holds a credential (`make audit`). That is a concrete, demonstrable claim with a real audience: the 2026-08-29 Anthropic weekly-limit change (a 17% cut, per BleepingComputer) is exactly when people add a second account.
- **Biggest threat:** commoditization from above and below. CodexBar is free, ships every one to three days, covers about 90 providers and added an Agent Sessions view on 2026-07-07; Coucou is free and growing fastest; Vibe Island already sells the same vendor set. If any one of them adds a permission-waiting state for every session on the machine, Armada's headline ("which one is waiting on you") stops being a differentiator.

### What changed since 10 September (docs/landscape.md)

No earlier competitive brief exists; `docs/landscape.md` (checked 2026-09-09/10) is the previous assessment. Corrections:

| landscape.md said | Now (2026-10-09) |
| --- | --- |
| Session monitors are "all Claude Code only" | No longer true. **c9watch** covers Claude Code, Codex, Cursor and Pi and added quota meters in v0.10.0 (2026-10-08) (P). **TokenEater** 6.0.0 (2026-09-25) made Codex first-class (P). **Vibe Island** covers about 30 agents including Grok, with multiple config folders since v1.0.49 (2026-09-15) (P). |
| Limit trackers are "mostly free" | Still mostly free, but two paid tiers now bracket Armada's price: **SessionWatcher** Bundle $14.99, rising to $19.99 on 2026-11-01 (P); **Vibe Island** $19.99 (P). |
| CodexBar is a limit tracker | CodexBar merged **Agent Sessions** (live Codex and Claude Code sessions, focus the terminal, other Macs over Tailscale) on 2026-07-07, off by default since 2026-07-10; its PR names permission-waiting as a non-goal (P). landscape.md missed this. |
| Claudexor: v3.10.2, ~440 stars | v3.24.0 on 2026-10-09, 497 stars, **35 releases since 1 September**; its homepage now leads with "Keep coding when a subscription hits its limit" and live 5h/7d quota per account (P). It moved onto Armada's limits ground. |
| Claw Orchestrator: Codex, Claude Code, Cursor, OpenCode, Antigravity | Now also **Grok Build**; v7.10.0 on 2026-10-09 (P). |
| "detecting sessions blocked on approval, which no product advertised" | Advertised widely now: Claude Control, Claudoscope ("Needs you" lane), c9watch (hook bridge), Vibe Island, Coucou and the notch apps all approve or flag prompts (P). Claude Code's own agent view has a Needs input state, for background sessions only (P). |
| Not listed | New entrants: **Coucou**, **Agent Cat**, **Vibe Island**, **Throttle**, **Agent Sessions** (jazzyalex), **cmux** (28k stars), **Superset**, **Emdash**, plus 30+ free App Store meters. See section 2. |

---

## 2. Competitor profiles

Ordered by threat to Armada. Major profiles first, then a short list.

### 2.1 CodexBar (Peter Steinberger), the free default

- **Overview.** Open-source (MIT) menu bar app by a well-known iOS/AI developer. 22,345 GitHub stars, v0.73.0 on 2026-10-07, ships every one to three days (P, GitHub API). macOS 14+, plus a Linux CLI and Qt app. DMG with Sparkle, Homebrew cask, AUR; not on the App Store (P).
- **Messaging.** Tagline "Every AI coding limit, in your menu bar." (P, codexbar.app). GitHub line: "Show usage stats for OpenAI Codex and Claude Code, without having to login." Themes: breadth (about 90 to 100 providers including Claude, Codex, Cursor, Gemini, Copilot, Grok since v0.33, 2026-06-11), no login, pace ("On pace / Runs out in 4d 21h"). Tone: terse developer utility.
- **Positioning.** Limit tracker first. Agent Sessions (PR #1968, 2026-07-07) lists live Codex and Claude Code sessions as active or idle with project and age, focuses the terminal, and shows other Macs over Tailscale; off by default since PR #2039 (2026-07-10). Permission-waiting is a stated non-goal (P). Multi-account: partial, managed Codex accounts arrived in 0.73 (P). Free.
- **Content.** GitHub README and releases; the author's large X following does the marketing (*unverified* reach). It is the default answer in HN threads (S).
- **Strengths.** Free, trusted author, breadth, release cadence, Homebrew.
- **Weaknesses.** Idle memory growing to about 2.6 GB (issue #3323, P); HN complaints "constantly freezes and crashes" and "Claude usage probe timed out" (S). No per-session context, no waiting reason, thin multi-account for Claude.

### 2.2 Vibe Island, the paid notch rival

- **Overview.** Paid macOS notch app ("Dynamic Island for your AI agents") at vibeisland.app. v1.0.51 on 2026-09-26 (P, changelog). DMG and Homebrew cask.
- **Messaging.** Tagline "Dynamic Island for your AI agents" (P). Themes: glanceable, approve without switching windows, many agents (claims about 30, including Claude Code, Codex, Gemini CLI, Cursor, Grok).
- **Positioning.** Approvals (Allow/Deny, questions, plan review) from the notch; usage limits; **multiple accounts** (v1.0.48, 2026-08-28) and extra Claude, Codex and Grok config folders (v1.0.49, 2026-09-15) (P). A review says only Claude Code, OpenCode and MiMoCode can actually be approved; Codex, Gemini and Cursor are read-only (S, vibecoding.app). **$19.99 one-time for one Mac**, 2- and 3-Mac tiers, one year of updates (P).
- **Content.** SEO pages such as `/alternatives` and `/best-ai-agent-notch-apps` (P). The only rival here running comparison-page SEO in the monitor niche.
- **Strengths.** Same vendor set as Armada including Grok, approvals in place, comparison content already ranking for its niche (*unverified* ranking, no SEO tool).
- **Weaknesses.** Review complaints that the UI "wears thin" and a release whose global shortcuts clobbered shell bindings (S, Aug 2026). Updates for one year only, per-Mac pricing. No context depth or account-to-account moves found.

### 2.3 Coucou, the breakout free entrant

- **Overview.** github.com/Louis-CFM/coucou, MIT. Created 2026-09-27, about 4,453 stars by 2026-10-09 (P); 3,146 reported on 10-04 (T, aicoder.com). Mac 0.2.3 on 2026-10-08 (P). macOS 15+, Windows, Linux, and an iOS 18 TestFlight app with Lock Screen approvals behind Face ID (P).
- **Messaging.** "A tiny friend in your Mac's notch and on your iPhone that keeps an eye on your AI coding agents" (P). Friendly, mascot-led tone.
- **Positioning.** Approvals for Claude Code (Allow/Deny/Always) and Codex, plus Cursor, Gemini CLI, Copilot CLI, Amp; Claude 5h/weekly and Codex limits. No Grok; multi-account not mentioned (P). Free.
- **Strengths.** Growth, phone approvals, cross-platform, charm.
- **Weaknesses.** Days old (0.2.x); no Grok, no stated multi-account, no context or cache depth.

### 2.4 Claudexor, the orchestrator that moved onto limits

- **Overview.** github.com/razzant/claudexor, MIT, signed macOS app plus Linux CLI and daemon. v3.24.0 on 2026-10-09, 497 stars, 35 releases since 2026-09-01 (P).
- **Messaging.** "Keep coding when a subscription hits its limit." Brand line "Coding agents, one control plane." (P, claudexor.ai).
- **Positioning.** Runs Claude Code, Codex, Cursor and OpenCode headless behind one interface (Grok sessions appear in its 3.24 notes). Live 5h/7d quota per account, isolated profiles per Claude/Codex account, rotation to another account after a confirmed limit, cross-model review, best-of-N (P). Free.
- **Strengths.** Directly solves "an account ran out", very fast cadence, honest cost accounting.
- **Weaknesses.** It runs agents in its own runtime and asks users to log in through it (landscape.md), which is the opposite of watching the sessions you already have in VS Code and raises the terms questions in `docs/limits-accounts-and-terms.md`. Heavy, CLI-first; not a glanceable menu bar tool.

### 2.5 Agent Cat (new, 2026-09-28)

- agentcat.app, Show HN 2026-09-28. Free. Mac (DMG; site claims App Store, *unverified*: the iTunes API rate-limited us), Windows, iOS, Android, watches (P, site).
- Covers Claude Code, Codex, Gemini CLI, OpenCode, Grok, Kimi. **Detects every logged-in account** (example: 6 Codex and 4 Claude), shows sessions as working, finished or idle, and suggests switching account when one is blocked (P). Claims 9,766 downloads (P, self-reported).
- The closest free match to Armada's "every vendor, every account" pitch. No waiting-for-permission state found; no context depth.

### 2.6 SessionWatcher, the paid limits tracker at our price

- sessionwatcher.com. Tagline "Never Lose a Coding Session to Rate Limits" (P). Solo $6.99 (Claude), **Bundle $14.99** (Claude, Codex, Cursor), Pro $59 lifetime or $24/year, Teams $40/seat/year; Bundle rises to $19.99 and Pro to $79 on 2026-11-01 (P). macOS 14+, Windows, iPhone/Watch beta. 20 vendors including Grok (Pro only, via "the same billing endpoint the Grok CLI uses") (P). Multi-account in Pro only. v7.5.1, October 2026.
- Content: heavy SEO guides, Product Hunt, X @SorenStarck (P).
- Business signal: listed for sale on TrustMRR at a $49.9K ask, with about $3.3K revenue in 30 days, $120 MRR and about 629 users reported (S, Reddit listing). **This is the best public datapoint on what a paid tool in this niche earns.**

### 2.7 TokenEater and c9watch, the closest open-source architecture

- **TokenEater** (github.com/AThevon/TokenEater): "Native macOS app to monitor AI usage limits and watch your coding sessions live." MIT, macOS 14+ with WidgetKit widgets. 513 stars, v6.0.0 on 2026-09-25 added Codex; that DMG downloaded 1,252 times (P). 5h and weekly windows with "smart pacing" zones and 7-day sparklines; Agent Watchers floating overlay that jumps to the editor. Waiting detection *probably partial*. Closest to Armada's limits-and-pace pane.
- **c9watch** (github.com/minchenlee/c9watch): "Mac app and JSON CLI to monitor every Claude Code, Codex, Cursor Agent and Pi session on your machine." MIT, Tauri. Scans processes so it sees sessions started anywhere (Zed, VS Code, iTerm2, Ghostty, tmux). "Needs Attention" inbox with an opt-in hook bridge for permission prompts; v0.10.0 (2026-10-08) added Claude, Codex and Cursor quota meters (P). 128 stars. Most similar "watch, don't run" design to Armada.

### 2.8 First-party defaults

- **Claude Code** (P, CHANGELOG and docs): status line exposes `rate_limits.five_hour` / `seven_day` and `context_window.used_percentage` since v2.1.80 (2026-03-19); `/usage` breakdown by skill, subagent, plugin and MCP server since v2.1.149 (2026-05-22); auto-continue when a limit resets since v2.1.234 (2026-08-17); spend-limit bar since v2.1.251 (2026-08-28); latest v2.1.295 (2026-10-08). **Agent view** (`claude agents`, research preview from about 2026-05-11, S) lists **background sessions only**, with a Needs input state: "Interactive sessions in other terminals don't appear until you background them" (P, code.claude.com/docs/en/agent-view). The **Desktop Code tab** "doesn't see cloud sessions, or sessions you started from the terminal CLI or the VS Code extension" (P). Remote Control (2026-02-24) is one session per instance (T). None of it spans accounts or vendors.
- **Codex / OpenAI:** usage in `/status` and on the web usage dashboard; "Weekly limits may also apply" and "ChatGPT Work and Codex share usage" (P, learn.chatgpt.com). The Codex app docs now redirect to the ChatGPT desktop app, suggesting Codex was folded into it around July 2026 (P redirect, inference *unverified*). Nothing found listing CLI or IDE threads.
- **Grok Build:** no first-party usage view beyond a percentage of a shared weekly pool in Settings (S).
- **Read:** the vendors are improving the single-session, single-account view steadily, and none has a reason to show a competitor's sessions or a second account. That gap is structural, not temporary.

### 2.9 Orchestrators (they run agents; Armada watches)

Short profiles; review mining was not done (search budget).

| Tool | Tagline / positioning (P) | Price (P) | Latest (P) | Watches outside sessions? | Shows plan limits? |
| --- | --- | --- | --- | --- | --- |
| **Conductor** (Melty Labs) | "Run parallel coding agents on your Mac." Claude Code, Codex, Cursor in isolated worktrees | Free; Pro $50/mo (cloud, mobile, API); Teams $60/user/mo | 0.90.0, 2026-10-02 (iOS app); weekly model additions | No | Not mentioned |
| **Superset** | "Bring Any Agent. Orchestrate Them All." 100+ agents incl. Grok CLI, worktrees, remote hosts, iPhone/iPad app, status view of working/blocked/waiting | Free to start; Pro reportedly $20/mo (S, *unverified*) | desktop-v1.37.0, 2026-10-08; 15,029 stars | No | Not mentioned |
| **cmux** | "The terminal built for multitasking…" Ghostty-based, notification rings when an agent needs attention | Free, OSS; optional Founder's Edition | nightly 2026-10-04; 28,065 stars | No (hosts sessions) | No |
| **Emdash** (YC W26) | "Open-source agentic development environment", 25+ agents | Free, OSS | v1.2.7, 2026-09-27; 5,944 stars | No | No |
| **Nimbalyst** (was Crystal) | "The visual workspace for Codex and Claude Code" | Free for individuals; Teams free in beta | Crystal v0.3.5, 2026-02-26 (archived as Nimbalyst) | Not stated | No ("provider handles plan limits") |
| **Vibe Kanban** | Kanban for coding agents | OSS; company (Bloop) shut down 2026-04-10, hosted features removed | v0.1.44, 2026-04-24; 28,305 stars | No | No |
| **Claude Squad** | "Manage multiple AI terminal agents like Claude Code, Codex, OpenCode, and Amp." TUI | Free, OSS | v1.0.20, 2026-08-20; 8,583 stars | No | No |
| **Claw Orchestrator** | Runs Claude Code, Codex, Antigravity, **Grok Build**, OpenCode behind one runtime | Free, MIT | v7.10.0, 2026-10-09; 589 stars | No | Spend caps |
| **Sculptor** (Imbue) | "Build product with grounded, parallel coding agents." | Free | v0.48.0, 2026-09-21 | No | No |

**Read:** orchestrators are not competing on visibility of the sessions you already run. They are a complement: a Conductor or Superset user still runs Claude Code under one or more accounts, and those sessions write the same files Armada reads (*unverified* per tool; worth testing). Vibe Kanban's shutdown note ("most users were free users… could not identify a business model") is a warning about monetizing this audience (P).

### 2.10 Minor and long tail

- **ccusage** (ccusage.com): "Analyze coding (agent) CLI token usage and costs from local data." Free CLI, 18,932 stars, about 600k npm downloads in the 30 days to 2026-10-07, v20.0.26 (2026-09-27), Grok Build since v20.0.20 (2026-08-15) (P). Reporting, not live state. Not a direct rival; the "CodexBar / ccusage already do this" objection in our Show HN notes still applies.
- **Claude Usage Tracker / claudetracker.com:** "Know your limits. Never hit them." Free, MIT, 3,628 stars, v3.3.0 (2026-08-29) added Codex profiles, per-profile `claude-<profile>` launchers and **auto-switch when one profile hits its limit** (P). Multi-account yes.
- **Claudoscope:** Claude Code and Cowork dashboard, "Needs you" lane, v1.4.0 (2026-10-08) added a menu bar badge that turns amber when a session waits and "Resume in terminal" (P). Free, 242 stars, Claude only.
- **Claude Control:** Electron dashboard, approve/reject from the dashboard, Claude only, 136 stars, v0.19.0 (2026-09-07) (P).
- **Chive** (chivecc.com): "Never lose track of Claude again." Paid lifetime (price not found), 75-minute runtime trial, Claude only, looks inactive since 1.0.0 (*unverified*).
- **Throttle** (lorislab.fr/throttle): "Know when Claude Code will hit its limit, before it stops your work." Free, Pro €29 one-time with a "≈2h to your cap" forecast (P). Claude only.
- **Usage4Claude** v3.5.0 (2026-09-24) added a pace graph and an Accounts tab (P); **Usagebar** $9 lifetime, stale since 2026-05-22 (P); **ClaudeUsageBar** free (P).
- **Agent Sessions** (jazzyalex): session-history browser with a live quota meter, 895 stars, v5.6 (2026-10-08) (P). Overlaps Armada's History.
- **Happy** (slopus/happy): open-source desktop and mobile client for Claude Code, Codex and Grok, about 24k stars (P). Mobile control, not a monitor of editor sessions.
- **Mac App Store:** 30+ free meters launched July to September 2026; the only rated ones are free (Nowdex, 9 ratings, 4.56; Usage for Claude, 5 ratings, 4.2); no paid tracker has more than one rating (Runlow $1.99, CUStats $9.99, Bloom for Claude $4.99, others) (P, iTunes search API). **No paid app in this niche has visible App Store traction.**

---

## 3. Messaging comparison matrix

| | **Armada** | CodexBar | Vibe Island | Coucou | Claudexor | SessionWatcher | Conductor |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Tagline** | "Nineteen agents running. One window that knows." | "Every AI coding limit, in your menu bar." | "Dynamic Island for your AI agents" | "A tiny friend in your Mac's notch… keeps an eye on your AI coding agents" | "Keep coding when a subscription hits its limit." | "Never Lose a Coding Session to Rate Limits" | "Run parallel coding agents on your Mac." |
| **Target buyer** | Heavy user with 10+ sessions across several Claude accounts plus Codex/Grok, in VS Code and terminals | Anyone on any AI plan who wants a meter | Mac developer who wants approvals without switching windows | Developer who wants a friendly glance and phone approvals | Power user with several subscriptions, CLI-first | Rate-limit-anxious Claude/Codex user | Developer parallelizing tasks in worktrees |
| **Key differentiator** | Per-session depth (state from the registry, context, cache) + moving sessions between accounts; reads disk, holds no credential | Breadth (about 90 providers), free, no login | Notch approvals, 30 agents incl. Grok, multi-account | Free, phone Lock Screen approvals | Rotation across subscriptions, cross-model review | Many vendors, Windows + Mac, team tier | Isolated worktrees, review and merge |
| **Tone** | Precise, candid ("a spike", "nothing pretends to") | Terse utility | Playful, product-y | Cute, mascot | Engineering-dense | Anxiety-relief, SEO | Clean, confident |
| **Core value prop** | Know which session needs you, which is about to fill, and where each week lands | See every limit at once | Handle agents from the notch | Keep an eye on agents anywhere | Never stop at a limit | Never get cut off | Run a team of agents |
| **Price** | $14.99 once, 1.x, every Mac | Free | $19.99 per Mac, 1 yr updates | Free | Free | $6.99 to $59; Bundle $14.99 (→$19.99 on 11-01) | Free; Pro $50/mo |
| **Platforms** | macOS 26+ | macOS 14+, Linux | macOS | macOS, Win, Linux, iOS beta | macOS, Linux | macOS, Windows, iOS beta | macOS, iOS |

---

## 4. Value proposition and narrative comparison

| | Promise | Evidence offered | Mechanism | Unique? | Villain / hero / transformation |
| --- | --- | --- | --- | --- | --- |
| **Armada** | One screen for every session, account and limit | Public measurement docs, `make audit`, real screenshots | Reads files agents already write; asks own `claude` for usage | Yes on depth and cross-account moves; no longer on "waiting" or "multi-vendor" alone | Tab archaeology across 16 panes → one window that knows → you go straight to the session that needs you |
| CodexBar | Every limit, always visible | Provider count, stars | Polls each provider | Breadth | Surprise cutoffs → meter → no surprises |
| Vibe Island | Never leave your flow to approve | Demo video, comparisons | Hooks into each agent | Notch UX | Context switches → notch → stay in flow |
| Coucou | A friend watches your agents | GitHub momentum | Hooks + iOS companion | Phone approvals, free | Babysitting the terminal → friend in the notch → walk away |
| Claudexor | Work continues past a limit | Release notes, receipts | Owns the agent runtime, rotates accounts | Rotation + review | The limit wall → control plane → uninterrupted work |
| SessionWatcher | Never lose a session to rate limits | SEO guides | Billing endpoints | Windows + team tier | Rate limits → alerts → planned usage |

Armada's narrative is the only one built on the **cost of not knowing across accounts**, and the only one whose evidence is reproducible (shell one-liners in `docs/implementation.md`). It does not yet tell the "your account ran out, keep going on the other one" story on the homepage, although that is its most distinctive shipped capability (1.6.0 to 1.10.0).

---

## 5. Positioning map

Axes chosen for this market: **who runs the agent** (you, anywhere; vs the tool's own runtime) and **what you can do across accounts** (show one account's numbers; vs act on sessions across several accounts).

```
                    Acts across accounts (move, continue, rotate)
                                    ^
                                    |
        ARMADA (move/continue/      |   Claudexor (rotation)
         history, live sessions)    |   Claude Usage Tracker (auto-switch
                                    |     profile, launches only)
   Watches sessions you  -----------+------------  Runs agents in its
   already run, anywhere            |              own runtime
                                    |
   Vibe Island, Agent Cat (display  |   Conductor, Superset, Emdash,
    several accounts), CodexBar,    |   cmux, Claude Squad, Nimbalyst,
    Coucou, c9watch, TokenEater,    |   Claw Orchestrator
    Claudoscope, SessionWatcher     |
                                    v
                    Shows numbers per account, acts on none
```

**Underserved quadrant: top-left.** Watching the sessions people already run in their editor *and* acting across accounts is occupied by Armada alone in this scan. Bottom-left is crowded and mostly free; the right side is orchestrators that want you to move your work into them. The top-left is the defensible spot, but only if Armada says so: today the hero leads with "which one is waiting", a bottom-left claim that ten rivals now make.

---

## 6. Content gap analysis

### Topics

| Topic | Armada | CodexBar | Vibe Island | Coucou | SessionWatcher | Claudexor | Conductor |
| --- | --- | --- | --- | --- | --- | --- | --- |
| How limits work (5h/7d, pace) | Docs only (`limits-accounts-and-terms.md`), no public article | README | No | No | Yes, SEO guides | Docs | No |
| Running several Claude accounts (`CLAUDE_CONFIG_DIR`, team + personal) | Docs only | No | No | No | Partial | Yes (profiles) | No |
| Anthropic limit changes (e.g. 2026-08-29) | No | No | No | No | Yes | No | No |
| Comparison / alternatives pages | **No** | No | **Yes** | No | Yes | No | No |
| Privacy / what the app reads | Strong (SECURITY.md, `make audit`, site) | Brief | Brief | Brief | Brief | Strong | Brief |
| Prompt cache economics | Shipped feature, one Show HN line | No | No | No | No | Pricing notes | No |
| Moving a session to another account | Changelog only | No | No | No | No | Rotation docs | No |

### Formats

| Format | Armada | CodexBar | Vibe Island | Coucou | SessionWatcher | Conductor |
| --- | --- | --- | --- | --- | --- | --- |
| Landing page | Yes | Yes | Yes | README | Yes | Yes |
| Changelog pages | Yes (`/changelog/<version>`) | GitHub | Yes | GitHub | Yes | Yes |
| Blog / guides | **No** | No | Comparison pages | No | Yes, heavy | Yes |
| Video / GIF demo | `public/video` exists; no social clip found | GIFs | Demo video | GIFs | *unverified* | Yes |
| Homebrew cask | **No** | Yes | Yes | n/a | Yes | n/a |
| Mobile companion | No | No | No | Yes (TestFlight) | Yes (beta) | Yes |
| Show HN / Product Hunt | Show HN 1 point (2026-09-24); no PH | HN regular | *unverified* | Press coverage | PH | *unverified* |
| X presence | @mgcrea, launch post 7 views | Author's large account | *unverified* | *unverified* | @SorenStarck | Yes |

Largest gaps: no comparison page, no Homebrew cask, no guide on running several Claude accounts, and no visible social clip of Move/Continue in action.

---

## 7. Opportunities

1. **Multi-account is a real and growing need, and Armada acts on it.** The 2026-08-29 weekly-limit change (T, BleepingComputer: "a 17% reduction") and a 2.7k-upvote r/ClaudeCode post about constantly checking limits (S) feed the "second account" behaviour. Rivals display several accounts (Vibe Island, Agent Cat) or rotate inside their own runtime (Claudexor). Only Armada moves a live or ended conversation to another account via the vendor's own fork and keeps the original (CHANGELOG 1.6.0 to 1.10.0).
2. **First-party will not fill the cross-surface gap.** Anthropic's agent view excludes interactive sessions in other terminals and the Desktop Code tab cannot see CLI or VS Code sessions (P). This holds Armada's core "sessions started anywhere" claim, and is citable on the site.
3. **Price position is fair, not an outlier.** SessionWatcher's Bundle moves to $19.99 on 2026-11-01 and Vibe Island is $19.99 per Mac with one year of updates; Armada's $14.99 for every 1.x on every Mac is now the cheapest paid option with this vendor coverage.
4. **Verifiable privacy is a differentiator nobody else markets as hard.** Armada reads every transcript; `make audit` proves the network surface against the built bundle. Most rivals poll provider endpoints or install hooks. This matters more as notch apps ask for approval rights over every agent.
5. **Orchestrator users are an adjacent audience, not competitors.** Conductor, Superset and cmux users still run Claude Code under accounts whose files Armada reads; "works beside Conductor/cmux" is an untested but plausible message (*needs a hands-on check before claiming*).
6. **Depth features nobody copied yet:** prompt-cache countdown and warning (1.7.0), per-session context with compaction, `waitingFor` reason, Codex schedules (1.10.0), keep-awake while agents work (1.10.0), transcript archive past the 30-day cleanup (1.8.0).

## 8. Threats

1. **CodexBar adds a waiting state or turns Agent Sessions on by default.** Free, 22k stars, ships every few days; permission-waiting is a non-goal *today* (P, PR #1968). If it changes, the bottom-left absorbs Armada's headline.
2. **Coucou's growth curve.** 4.4k stars in 12 days with phone approvals; it could add multi-account in a release.
3. **Vibe Island sells the same vendor set at a similar price** and already runs alternatives/comparison SEO.
4. **Approvals are now table stakes.** Claude Control, Claudoscope, c9watch, Vibe Island, Coucou and the notch apps let users act on a waiting prompt; Armada shows it and offers Focus. (The ledger's rejection of sending messages from Armada's windows is about free text, not approvals; approving in place has not been decided either way.)
5. **Grok Build waiting state is missing** in Armada (site: "a permission prompt is not read from disk yet"), while Vibe Island claims Grok approvals.
6. **Monetization ceiling.** SessionWatcher's reported $120 MRR and about 629 users (S) and Vibe Kanban's shutdown (P) suggest this audience pays little. macOS 26+ also narrows the addressable base compared with rivals on macOS 14+.
7. **Vendor format churn.** Armada depends on on-disk formats (registry `status`, Codex locks). Claude Code ships almost daily (v2.1.295 on 2026-10-08); Codex moving into the ChatGPT app could change where its files live (*unverified*).

---

## 9. Recommended actions

### Quick wins (this week)

1. **Re-lead the homepage with the cross-account move, not the waiting dot.** Add one hero line or a Tour step: "When one account runs out, continue the same conversation on another. The original stays untouched." Evidence: section 5 (top-left is Armada alone), opportunity 1. Built: Move, Continue on and History shipped in 1.6.0 to 1.10.0. Keep "which one is waiting" as the second line; it is still true, just no longer unique.
2. **Publish a Homebrew cask.** CodexBar, Vibe Island, Claudoscope, TokenEater, c9watch and SessionWatcher are all one `brew install` away; Armada is not (no cask referenced in the repo). Low effort, matches how this audience installs.
3. **Ship a notification when a session starts waiting.** Proposed in the 2026-09-21 market-intel run and neither accepted nor rejected; not built (only `PromptCacheNotifier` and `ScheduleNotifier` post notifications today, plus the glyph ring). New dated evidence: Claudoscope 1.4.0 added an amber waiting badge (2026-10-08), Coucou and Vibe Island push approvals, and a "cursor sprouts a Claude logo when waiting" post scored 225 on r/ClaudeCode (S, 2026-06-15). Record the decision in `docs/market-intel.md` either way.

### Strategic moves

4. **Write one comparison page and one guide, both factual.** `/compare` (Armada vs CodexBar, Vibe Island, Claude's agent view), citing the first-party docs quotes in section 2.8, and a guide "Running a personal and a team Claude account on one Mac" built from `docs/limits-accounts-and-terms.md`. Vibe Island and SessionWatcher already own this format; Armada has the better source material and no page. Do not claim compatibility with Conductor or cmux until tested.
5. **Decide on approve-in-place, with evidence, before the next minor.** Approvals are now table stakes (threat 4). It is not covered by the ledger's "Send a message from Armada's windows" rejection, but it does collide with "watches rather than runs" and with the hook design in `docs/design.md`'s security model. Run it through the ledger's gates and record the outcome; if accepted, Claude Code first (registry already names what a waiting session wants), then Grok Build's waiting state, which is a known gap.

Not recommended: price changes (Armada already undercuts the two paid rivals as of 2026-11-01), a Windows or iOS port (macOS 26 SwiftUI app, no plan in the repo), or marketing messaging between agents, which `README.md` says is designed and not built.

---

## 10. Sources (accessed 2026-10-09)

Repo (read 2026-10-09): `README.md`, `CHANGELOG.md`, `docs/landscape.md`, `docs/market-intel.md`, `docs/design.md`, `docs/README.md`, `docs/posts/2026-09-24-show-hn.md`, `docs/posts/2026-09-24-x-weekly-limits.md`, `apps/website/src/config.ts`, `apps/website/src/components/{Hero,Pricing,Problem,Vendors,Limits}.astro`, `apps/website/src/layouts/Layout.astro`.

Ours: https://news.ycombinator.com/item?id=49832165 (via hn.algolia.com API: 1 point, 0 comments); https://github.com/mgcrea/armada (GitHub API: 0 stars).

Competitors and first-party:
- https://codexbar.app/ · https://github.com/steipete/CodexBar · https://github.com/steipete/CodexBar/pull/1968 · https://github.com/steipete/CodexBar/pull/2039 · https://github.com/steipete/CodexBar/issues/3323 · https://news.ycombinator.com/item?id=48473845
- https://vibeisland.app · https://vibeisland.app/changelog · https://vibecoding.app/blog/vibe-island-review
- https://github.com/Louis-CFM/coucou · https://aicoder.com/news/news-20261004-coucou-notch-coding-agent-companion
- https://claudexor.ai/ · https://github.com/razzant/claudexor (releases API)
- https://agentcat.app/
- https://sessionwatcher.com · https://sessionwatcher.com/grok · https://www.reddit.com/r/TrustMRR_Listings/comments/1vwcmr7/
- https://github.com/AThevon/TokenEater · https://github.com/AThevon/TokenEater/releases/tag/v6.0.0
- https://github.com/minchenlee/c9watch · https://github.com/minchenlee/c9watch/releases/tag/v0.10.0
- https://github.com/cordwainersmith/Claudoscope/releases/tag/v1.4.0 · https://github.com/sverrirsig/claude-control · https://chivecc.com
- https://github.com/ccusage/ccusage · https://api.npmjs.org/downloads/point/last-month/ccusage · https://github.com/hamed-elfayome/Claude-Usage-Tracker · https://claudetracker.com · https://usagebar.com · https://claudeusagebar.com · https://github.com/f-is-h/Usage4Claude · https://github.com/ArrivaRUS/claude-codex-limits · https://lorislab.fr/throttle/ · https://github.com/jazzyalex/agent-sessions · https://www.usagebuddy.com/ · https://github.com/slopus/happy · https://github.com/farouqaldori/vibe-notch
- https://www.conductor.build · https://www.conductor.build/pricing · https://www.conductor.build/changelog · https://superset.sh · https://github.com/superset-sh/superset · https://cmux.com · https://github.com/manaflow-ai/cmux · https://emdash.com · https://nimbalyst.com/ · https://github.com/stravu/crystal · https://vibekanban.com/blog/shutdown · https://github.com/BloopAI/vibe-kanban · https://github.com/smtg-ai/claude-squad · https://github.com/Enderfga/claw-orchestrator · https://github.com/imbue-ai/sculptor
- https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md · https://code.claude.com/docs/en/statusline · https://code.claude.com/docs/en/agent-view · https://code.claude.com/docs/en/desktop · https://support.claude.com/en/articles/15910845-claude-code-may-july-2026-weekly-limits-promotion · https://www.bleepingcomputer.com/news/artificial-intelligence/anthropic-is-cutting-claude-codes-current-weekly-limits-by-17-percent/ · https://www.techradar.com/pro/anthropic-reveals-remote-control-a-mobile-version-of-claude-code-to-keep-you-productive-on-the-move · https://learn.chatgpt.com/docs/pricing · https://chatgpt.com/codex/settings/usage
- https://www.reddit.com/r/ClaudeCode/comments/1uv6ns4/ · https://www.reddit.com/r/ClaudeCode/comments/1u6cc24/ · https://www.reddit.com/r/ClaudeCode/comments/1vrogcj/
- iTunes search API (`https://itunes.apple.com/search?entity=macSoftware`), partly rate-limited (HTTP 403).

### Monitoring (re-check monthly)

- **CodexBar:** whether Agent Sessions becomes default-on or gains a waiting/permission state (watch PRs mentioning "permission" or "waiting").
- **Coucou:** star count, Grok support, multi-account.
- **Vibe Island:** price, changelog, new comparison pages (especially any naming Armada).
- **SessionWatcher:** whether the 2026-11-01 price rise happens; sale of the business.
- **Claudexor:** account-rotation features that watch editor sessions rather than running its own.
- **Claude Code:** agent view leaving research preview or listing interactive sessions; any multi-account support; `rate_limits` format changes.
- **Codex / ChatGPT app:** where session files live after the move into ChatGPT; OpenAI's terms for Codex on a ChatGPT subscription (README: not yet checked).
- **Grok Build:** a first-party usage or session view.
- **Armada's own reach:** Show HN and X metrics in `docs/posts/`, GitHub stars, and, once an SEO tool is connected, rankings for "Claude Code usage menu bar", "multiple Claude accounts" and "Claude Code waiting notification".
