# Battlecard: Codenotch, Pitboard, and the free defaults

- **Updated:** 2026-10-27, from [competitive-brief-2026-10-27.md](competitive-brief-2026-10-27.md).
- **Win rate:** not tracked. Armada has no sales team; the "deals" here are HN, Reddit and X
  threads, support mail and the refund window. The usual "they're cheaper" objection is always
  true, because both rivals on this card are free.
- **Use:** before replying in a thread where one of these tools comes up. Write the reply itself
  in your own voice (`reply-as-olivier`); this card is for the facts.

## Armada in one breath

A menu bar app for someone running many Claude Code, Codex and Grok Build sessions across several
accounts. It reads what the agents write to disk, asks each account's own CLI for its limits, and
can carry a Claude Code conversation to another account through Claude Code's own fork. It never
reads, stores or refreshes a token, and `make audit` checks the network surface against the built
app. $14.99 once, every Mac, every 1.x.

---

## Codenotch

- **What it is:** a free, MIT notch app ("macOS 15 or later"; its badge says 26+) that shows "how much of each coding assistant's
  usage limit you have burned — and whether it is still working, done, or waiting on you".
  2,931★ seven weeks after its first commit (2026-09-05). Windows port, phone companion over LAN.
- **Their pitch:** breadth (Claude Code, Codex, Cursor, Grok, Antigravity, Amp, DeepSeek, local
  Ollama and LM Studio, and more), at a glance, free.

**Strengths (be honest)**

- Free, open source, signed and notarized, and growing faster than anything else in the niche.
- A waiting state, so "which one is waiting on you" is not Armada's to claim against it.
- Its Claude source is the same one Armada uses first: it asks the installed `claude` for `/usage`.
- Local models (Ollama, LM Studio, oMLX), which Armada doesn't watch at all.

**Weaknesses**

- **Tokens.** Its README says Claude falls back to "the OAuth token in the login keychain", and
  Grok is read from `~/.grok/auth.json`, "renewed in memory from the file's own refresh token".
  Armada never opens either.
- No per-session depth in its README: no context occupancy, compaction or prompt-cache countdown.
- No move or continue between accounts. It does show several profiles per vendor (`~/.claude-<slug>`,
  `~/.codex-<slug>`), so "every account" is not Armada's to claim against it either.

**Where Armada differs**

| Difference | Why it matters to the person | Proof |
| --- | --- | --- |
| Moves a Claude Code conversation to another account | An account at its limit doesn't stop the work | `CHANGELOG.md` 1.6.0, 1.9.0, 1.10.0 |
| Context per session, with compaction and cache expiry | Which session is about to fill, not just which plan | Detail pane; `docs/claude-code-sessions.md` |
| Never reads a token, for any vendor | Nothing to leak, nothing a vendor's terms forbid | Rules section; `make audit` |

## Pitboard

- **What it is:** a free, Apache-2.0 account switcher. "Switch AI coding tools between your
  accounts." macOS app, Windows beta, CLI everywhere. 101★, first commit 2026-09-21. Homebrew tap.
- **Their pitch:** "It keeps the login of each account you are not using, called a parked login.
  A switch puts the chosen account's parked login where the tool reads it." "Open Claude Code
  sessions follow a switch with no restart." It can switch by itself at 95%.

**Strengths (be honest)**

- **For one running session, it's smoother than Armada.** The same conversation keeps going on
  the new account within about 33 seconds, with no new row and no copy.
- It switches automatically, and it covers Claude Desktop too.
- Its security page lists every request it makes.

**Weaknesses**

- It holds every other account's login on the Mac. Its own docs say "Anthropic's terms may cover
  automatic switching" and link a section on it.
- One login at a time per tool: every session follows the switch, so two accounts can't run side by
  side the way two config folders can.
- No session list, waiting state or context: it's a switcher, not a monitor.
- Codex "keeps the old account until it starts again".

**Where Armada differs**

| Difference | Why it matters to the person | Proof |
| --- | --- | --- |
| Copies the conversation; the original stays where it was | You can go back; earlier turns stay counted on the account that spent them | 1.9.0 "Continue an ended session"; 1.10.0 "can come back" |
| Accounts run side by side, one config folder each | A team account and a personal one at once, both live | `docs/limits-accounts-and-terms.md`, "Multiple accounts on one Mac" |
| Never holds a login | Nothing to park, nothing to swap | Rules section; `make audit` |
| Works on ended sessions and History | Pick up yesterday's conversation on the account with room | 1.9.0 History |

---

## Objection handling

| If someone says… | Answer with… |
| --- | --- |
| "Codenotch / CodexBar does this for free." | They do limits and, for Codenotch, a waiting state, and do them well. Armada is for the person whose problem is several accounts: it moves a Claude Code conversation to the one with room left, and shows how full each session's context is. If one account is all you have, the free ones are the right call. |
| "Pitboard already switches accounts." | It swaps the login under your sessions, which keeps one conversation going smoothly. Armada copies the conversation instead and holds no logins, so the original stays and both accounts can run at once. Different trade; pick the one that fits. |
| "Why pay $14.99?" | Once, for every Mac and every 1.x. From 1 November that's below SessionWatcher's Bundle ($19.99) and Vibe Island ($19.99 per Mac, one year of updates). Thirty-minute trial, 30-day refund. |
| "macOS 26 only?" | Yes. Runnock needs 26 too; Codenotch runs on 15. If you're on 14 or 15, Codenotch, TokenEater or CodexBar will serve you better today. |
| "Does it handle Codex and Grok accounts too?" | It watches them, with limits and state. Moving a conversation between accounts is Claude Code only. Codex forks stay inside their own home. |
| "Can I approve prompts from it?" | No. Focus takes you to the session's own terminal. Approve-in-place is undecided (brief, section 7). Don't promise it. |

## Landmines to set (questions that show where Armada fits)

- "How many Claude accounts do you run, and what happens to a conversation when one hits its limit?"
- "Do you know which of your sessions is closest to compacting?"
- "Does the tool you use read your OAuth token, or ask the CLI?"

## Landmines to defuse

| They might ask Armada… | Prepared answer |
| --- | --- |
| "Why does your Codex history look short?" | Known: Codex compresses week-old logs to `.jsonl.zst` and Armada doesn't read them yet (`PLAN.md`). Say so plainly until it ships. |
| "Zero GitHub stars, is this maintained?" | Twelve releases in five weeks (1.0.0 on 2026-09-14 to 1.11.0 on 2026-10-18); the CHANGELOG and the `/changelog` pages are the evidence. |
| "Grok Build waiting state?" | Not read from disk yet; the site says so. |

## Win and loss themes (expected, not measured)

- **Likely wins:** two or more Claude accounts, VS Code extension users, people who care what an
  app reads (privacy, a work account).
- **Likely losses:** one account (free meters suffice), anyone wanting phone or notch approvals,
  macOS 14 and 15, local-model users.
- **Start tracking:** ask on the refund form and in support replies which tool they came from or
  went to. It's the only win/loss signal available without a sales team.
