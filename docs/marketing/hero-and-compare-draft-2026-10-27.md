# Hero paragraph and /compare: drafts

Drafted 2026-10-27 from [competitive-brief-2026-10-27.md](competitive-brief-2026-10-27.md).
Nothing here is on the site yet. Every claim about a rival quotes its own README or docs as read
that day. Re-read each source before publishing, since several of these tools ship every few days.

## 1. Hero paragraph (`apps/website/src/components/Hero.astro`)

The headline stays: "Nineteen agents running. / One window that knows."

**Today:**

> Armada is a menu bar app that watches every Claude Code, Codex and Grok Build session on your
> Mac, across accounts and across vendors: which one is waiting on you, how full its context is,
> how much of each plan is left, and where each week will land before it resets.

**Proposed:**

> Armada is a menu bar app that watches every Claude Code, Codex and Grok Build session on your
> Mac, in every account: which one is waiting on you, how full its context is, and how much of each
> plan is left. When an account runs out, take the Claude Code conversation to another one and
> carry on. Armada never reads a token to do it.

Why this shape:

- **The first sentence still says what the app is.** A visitor who reads one line still learns
  "menu bar, every session, every account". "Across vendors" is dropped because the vendor names
  already say it.
- **The move gets a sentence of its own, scoped to Claude Code.** Codex and Grok Build sessions
  don't move between accounts (`CHANGELOG.md` 1.6.0 to 1.10.0 is Claude Code only), so the
  sentence names the one vendor it is true for.
- **"Never reads a token" rather than "holds no credentials".** That is the difference a visitor
  can check against the rivals. Pitboard "keeps the login of each account you are not using";
  Codenotch falls back to "the OAuth token in the login keychain". The Rules section already says
  "Nothing reads, stores or refreshes a token", so the hero only points at it.
- **"Where each week will land" moves out.** The Limits section already carries the forecast with
  its picture. The hero list goes from four items to three; it reads as a plain list, not a pattern,
  because the next sentence breaks the rhythm.
- **Length:** 331 characters against 267 today, about one more line in the 52ch column. The hero has the room; if it looks heavy, drop "in every account" first, since the next sentence says it.

Check before shipping: the old wording appears only in `Hero.astro:48` (checked 2026-10-27), but
re-check the meta description and OG text, and the hero's `figure` caption, which shouldn't
contradict it.

## 2. `/compare`: how each tool moves you to another account

The page asks one question, the one every multi-account tool now answers differently. It shouldn't
claim a winner or use adjectives, only the mechanism in each vendor's own words.

**Intro line:** "Many tools now show several accounts. They differ in what happens when one runs
out: what moves, what they hold to move it, and which sessions they can reach."

| Tool | When an account runs out | What it holds to do it | Which sessions | Source |
| --- | --- | --- | --- | --- |
| **Armada** | Copies the Claude Code conversation to the other account's folder and opens a fork of it there; "the original stays where it was". Works on a running session, an ended one, or several at once | No token. "Nothing reads, stores or refreshes a token"; the other account's own `claude` does the signing in | Any Claude Code session on the Mac, including the VS Code extension and its History. Claude Code only | `CHANGELOG.md` 1.6.0, 1.9.0, 1.10.0; Rules section |
| **Pitboard** | Swaps the login: "A switch puts the chosen account's parked login where the tool reads it." "Open Claude Code sessions follow a switch with no restart"; it can switch by itself at 95% | "It keeps the login of each account you are not using, called a parked login." Its docs add: "Anthropic's terms may cover automatic switching" | Claude Code, Codex CLI ("keeps the old account until it starts again"), Claude Desktop while closed | github.com/datlechin/pitboard README; docs.usepitboard.com/guides/automatic-switching |
| **Claude Usage Tracker** | Switches profile: "auto-switch credentials when changing profiles"; a `claude-<profile>` launcher per account | "Manage unlimited Claude accounts with isolated credentials" | Sessions it launches or plain `claude` afterwards | github.com/hamed-elfayome/Claude-Usage-Tracker README |
| **Tellurion** | "restart a tile's agent on another" account. The README doesn't say whether the conversation comes along | Nothing: "only points the agent at each account's folder and never reads sign-in details" | Agents running inside Tellurion's own terminal | github.com/steventsvik/Tellurion README |
| **Claudexor** | Rotates to another account after a confirmed limit, inside its own runtime | Its own profiles per account; you log in through it | Agents it runs headless | claudexor.ai; github.com/razzant/claudexor |
| **TokenEater, CodexBar, Vibe Island, Agent Cat** | Show several accounts side by side; Agent Cat "suggests another account when one is blocked". Nothing moves | Each account's token, read to ask its provider (TokenEater: "its own Keychain item"; CodexBar: token accounts) | Display only | Each project's README or site |
| **Claude Code itself** | One account per config folder. Nothing in the CHANGELOG to 2.1.311 moves a conversation between folders | n/a | n/a | github.com/anthropics/claude-code CHANGELOG |

**Under the table, two plain notes:**

- "Swapping a login keeps the same conversation running; copying keeps the original. Armada copies.
  Earlier turns stay counted against the account that spent them."
- "Armada's network surface is checked against the built app by `make audit` on every release."
  Link the script.

**Rules for the page itself:**

- Date every row ("as read on …") and link each quote. Re-check before each release; a stale row
  about a rival is worse than no page.
- Don't write about another tool's terms risk. Pitboard's own sentence about Anthropic's terms
  can stand, quoted and linked; Armada adds nothing to it.
- Don't publish this before the `.jsonl.zst` archive work in `PLAN.md` ships. A compare page
  invites someone to check Armada's own Codex numbers, and Agent Sessions already reads those files.
