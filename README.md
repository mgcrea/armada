# Armada

**Every coding agent you have running, on one screen.**

A macOS menu bar app for someone running many Claude Code and Codex sessions at once: what each one
is doing, how full its context window is, and how much of each plan is left — read from what the
agents already write to disk, plus one question asked of the user's own `claude`.

> **Not shipped.** No release, no site, no licence key — build it from source and run it. Status on
> 2026-09-13: the app is built and runs, covering two of v1's three features. The third, messaging,
> is designed and not started. [Status](#status) lists exactly what runs today,
> [CHANGELOG.md](CHANGELOG.md) what has changed, and
> [docs/implementation.md](docs/implementation.md) what it cost to get there.

## The problem

The reference case is sixteen or more concurrent Claude Code sessions in the VS Code extension,
beside Codex threads in another window and a second Claude account in another config folder. Nothing
shows you all of them. The editor shows the session you are looking at; a limit tracker shows a
percentage with no sessions behind it; the vendors' own tools stop at one account each.

The three questions you actually have are **which session is waiting on me**, **which one is about
to run out of context**, and **how much of the plan is left** — and each answer lives somewhere
different, per account, per vendor.

Armada watches rather than runs. It holds no vendor credentials and writes nothing to a
vendor's config: it reads `~/.claude*` and `~/.codex`, and asks the installed `claude` one
question that costs no tokens. See
[docs/limits-accounts-and-terms.md](docs/limits-accounts-and-terms.md) for why that shape was
chosen and what Anthropic's terms actually say.

It will also *start* a session for you, which is the one line of the original scope that has
been deliberately reopened — "v1 watches; it doesn't launch agents". It still owns no agent
process: it writes a startup script, hands it to Terminal, and the new session arrives through
the same watchers as every other.

## What it shows

The **account** is the unit everything hangs off — one Claude config folder, or one Codex home —
because it is the unit the data is organised by. Two folders share nothing: separate sessions,
separate transcripts, separate rate limits.

| Pane         | What it holds                                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| **Sessions** | every live session with its title, project, age and state, sorted by what needs you and groupable by project                             |
| **Detail**   | how full that session's context window is, where it started, what it has grown at, and where it was last compacted                       |
| **Usage**    | the 5-hour and 7-day windows per account, with reset times, a pace line and a forecast — Claude accounts and Codex homes side by side    |
| **Overview** | the detail pane with nothing selected: the folders that account ran in last, a folder picker, and a tally of what its sessions are doing |
| **Menu bar** | an accessory app (`LSUIElement`): a popover summarising every account, and a template glyph that fills when anything is working          |

Middle and extra mouse buttons can be bound to cycle the session list or send a keystroke,
through an event tap whose mask is two event types wide and which is dead inside a Secure Input
context — both stated in Settings rather than left to be found.

A session row offers one action, **Focus**, which brings forward the application the session is
running inside — VS Code, Terminal, whatever the process tree says. The label names the app rather
than promising the window, because a process walk reaches an application and never a tab:
[docs/focusing-sessions.md](docs/focusing-sessions.md) has the chains, the 0.57 ms cold cost, and the
uncomfortable case where nineteen sessions in one VS Code all resolve to the same target.

## Where the numbers come from

Each row of this table is a measurement written up in its own doc, not a guess about a file format.

| Figure                | Source                                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **Session state**     | the registry's own `status` — `busy` / `waiting` / `idle` — with `waitingFor` naming what a waiting session wants |
| **Title**             | the last `aiTitle` in the transcript; a head read when a tail read misses it                                      |
| **Context occupancy** | the newest `assistant` entry's three token figures, **summed**                                                    |
| **Prefix breakdown**  | `get_context_usage`, asked of a spawned `claude` — describes a comparable session, not the watched one            |
| **Plan limits**       | `get_usage`, asked of the account's own headless `claude`, falling back to the cache in `.claude.json`            |
| **Codex liveness**    | a zero-byte flock in `~/.codex/thread-writer-locks/` — Codex has no session registry                              |
| **Codex limits**      | `token_count` events inside session logs, tailed from the newest rollout in the tree                              |

Two of those carry a sentence the UI repeats out loud, because reading them the obvious way is
wrong:

- **State is read, not inferred**, since Claude Code 2.1.269 began writing it. Write-recency and the
  unanswered-`tool_use` rule survive only as the fallback for an older build. The field is right
  where the inference was most wrong: a session ninety seconds into a tool call still reads `busy`
  rather than flipping to idle.
- **Occupancy and spend are different numbers, and only one vendor reports both.** Occupancy is the
  size of the current prompt — it falls on compaction and re-counts the cached prefix every turn —
  and it is what both panes show. Cumulative spend is Codex-only; Claude Code records no equivalent
  anywhere on disk. They are deliberately not in one column.

The evidence for all of it is in [docs/claude-code-sessions.md](docs/claude-code-sessions.md) and
[docs/codex-sessions.md](docs/codex-sessions.md), and every figure on screen is checkable against
the machine with the shell one-liners in
[docs/implementation.md](docs/implementation.md#verifying-it-against-reality).

## The Codex half is a spike

It is real code and shipped behaviour — a second sidebar section, its own sessions, its own plan
limits, a card in the Usage pane, and the same context panel, sharing one renderer with the Claude
side so the two cannot drift. It was also written in one pass to find out what Codex makes possible,
and it is the part most likely to want revisiting.

What is thin is listed rather than hidden: a locked session with no rollout file is invisible, there
is no Focus button (a Codex session has no pid anywhere on disk), the 12-hour recency window that
decides what the pane even is comes from "a working morning" and nothing else, and nothing reads
Codex logs for a rate-limit refusal. [docs/implementation.md](docs/implementation.md#where-the-codex-spike-is-thin)
has the full list with what each fix would cost.

The Codex pane also leads with how old its figures are, on purpose. Codex has no usage cache, so
"recent" is the honest word for that list where the Claude one can say "live".

## Messaging is designed, not built

v1's third feature is direct messages between agents, across vendors and across accounts — the gap
[docs/landscape.md](docs/landscape.md) found that nothing else targets. Claude Code's built-in
`SendMessage` already covers Claude-to-Claude inside one account; everything else is unserved, and
every cross-vendor orchestrator on the market runs agents in its own runtime instead of watching the
ones you started in your editor.

The delivery mechanisms are measured already — an `asyncRewake` hook wakes an idle Claude session in
about a second and Claude acts on the text; a long-poll works on both vendors and hard-fails at
exactly 300 s on Codex; MCP notifications never reach either model. The table is in
[docs/reaching-agents.md](docs/reaching-agents.md).

That measurement is also the security problem. **Claude acts on text delivered by a hook**, having
refused the same request through a channel, so whatever delivers messages can steer every agent on
the machine. The router decides delivery and never the sender, every pair is an explicit policy, and
every delivered message is labelled and logged — see
[docs/design.md](docs/design.md#security-model-drafted). None of it is written yet, and the app today
opens no socket and installs no hook.

## Working on it

Requires **macOS 26** and **Xcode 26**. The whole build is `xcodebuild`, named by the Makefile rather
than wrapped by it; the root Makefile forwards every target to `apps/apple` so the commands are the
same from either directory.

```bash
make build          # build Armada.app (Debug)
make run            # build, quit any running copy, and launch it
make quit           # quit it and wait for the process to go
make build-release  # build in Release
make clean          # remove .build

make format-swift        # format the Swift with the toolchain's swift-format
make format-swift-check  # fail on unformatted Swift — this is what CI gates on
make blame-setup         # teach git blame to skip the formatting-only commits

make audit          # assert the built app reaches no network
make icon           # rebuild the icon bundle and the web SVG from design/armada-mark.svg
make icon-check     # fail if anything generated has drifted from its source
```

`make` on its own lists every target, root and app.

CI runs `make format-swift-check` then `make build` with signing off. The format gate goes first
because it compiles nothing, which makes it the fastest real signal in the repo.

Two things worth knowing before touching the build:

- **`swift-format` comes from the selected Xcode**, so a toolchain bump can reformat the whole tree
  with no change to `.swift-format`. The Makefile asserts the version (6.3.x) so that day arrives as
  a sentence rather than a mystery diff.
- **The pbxproj was generated once and committed as a normal file.** There is no generator in the
  repo on purpose: the fleet's `pbxproj_add_product.py` edits it in place, and a regenerating script
  would clobber those edits.

To exercise the degraded paths without touching real data, point a build at a fixture:

```bash
CLAUDE_CONFIG_DIR=/tmp/fake open apps/apple/.build/Build/Products/Debug/Armada.app
```

A truncated registry file is skipped, a `.claude.json` with no `cachedUsageUtilization` shows an
empty usage strip, and neither crashes.

## Status

Built and running:

|                       |                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------- |
| **Sessions**          | live Claude Code sessions per config folder, with state read from the registry                    |
| **Context**           | occupancy, the opening load, a growth series, a projection, and the last compaction               |
| **Usage**             | 5-hour and 7-day windows per account, live through `get_usage`, with a badge saying what answered |
| **Forecast**          | day-weighted pace against each window, declining any reading too old to be sound                  |
| **Focus**             | a session row back to the application hosting it, and its own window where Accessibility allows   |
| **Menu bar**          | accessory app, per-account popover, and a glyph that rings when a session wants attention         |
| **New sessions**      | start `claude` or `codex` in a chosen folder on a chosen account, via a terminal                  |
| **Mouse bindings**    | middle and extra buttons cycle the session list or send a keystroke, via an event tap             |
| **Codex**             | sessions, plan limits and context per Codex home, as a spike                                      |
| **Settings**          | `swift-support-kit`'s shared scaffold, an About pane and a Help menu                              |
| **Multiple accounts** | `~/.claude`, every `~/.claude-*` sibling and `CLAUDE_CONFIG_DIR`; `~/.codex` and `CODEX_HOME`     |

Deliberately not built: messaging, hooks, `hubctl`, the Unix socket, the MCP surface, and anything
that writes to a vendor's config. **`~/.claude*` and `~/.codex` are opened read-only** — the only
things Armada writes are its own: its preferences, its usage history, and the startup script it
hands to a terminal.

### Known gaps

- **`armada.mgcrea.io` does not resolve**, so the Help menu's Support and Feedback items are dead
  links until the site ships. One line in `Support.swift`.
- **No tests, and so no `make test`.** A target that ran nothing would be worse than none.
- **Folder discovery is not watched**: a config folder created while Armada is running does not
  appear until relaunch.
- **The prefix breakdown describes a comparable session, not the watched one.** The totals are exact
  and per-session; the split into system prompt, tools, memory files and skills comes from a spawned
  `claude` in a fresh conversation, so those rows are "what a session started here now would load"
  and their `Messages` part is always zero.
- **Codex homes are not discovered by convention** — `~/.codex` plus `CODEX_HOME`, because Codex
  documents no `~/.codex-<name>` pattern and scanning for one would be inventing a convention rather
  than following one.
- **OpenAI's terms for Codex on a ChatGPT subscription have not been checked**, and became
  load-bearing the day the Codex pane shipped.

## Security

Armada reads every transcript on the machine, so the claim worth checking is that none of it
leaves. It makes **no network connection of any kind** — no update check, no telemetry, no
licence call — and `make audit` asserts that against the built bundle rather than against the
sources: every Mach-O swept for URL loading, DNS and TLS symbols, the sources swept for an
internet address family, and the project asserted to name no entitlements file.

```bash
make audit
```

There is no allowance table in [`scripts/audit-network.sh`](scripts/audit-network.sh), and that
is the difference from the siblings' versions of the same script. Cupertino's has to pardon
Sparkle and an embedded node; bastion cannot make the claim at all, because it binds a loopback
socket on purpose. Armada has no updater, no runtime and no listener, so any hit is a failure.
If it ever grows one, the script grows a table and [SECURITY.md](SECURITY.md) gets reworded in
the same commit.

What that does **not** cover is the `claude` Armada spawns, which talks to Anthropic over your
own sign-in — that is the program's job. [SECURITY.md](SECURITY.md) has the full scope: what is
claimed, where attacker-influenced transcript text meets something that acts on it, and how the
threat model moves when messaging lands.

## Licence

|                                     |                                                                                                          |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------- |
| [`apps/apple/`](apps/apple/LICENSE) | Source-available. Read it, modify it, compile it, run your own build. Binary redistribution is reserved. |
| `docs/`, `design/`, `scripts/`      | [MIT](LICENSE). The measurements in particular are more useful copied than reserved.                     |

The same split both siblings use, for the same reason turned around: Armada is pointed at every
agent transcript you have. Nobody should grant that to software they cannot read, so the source
stays readable, auditable and buildable by anyone. No signed build is distributed today — the
reservation is a position held open, not a product being described.

## Docs

`docs/` is the long half of this repo, and most of it is measurement rather than plan.

| Doc                                                               | What it holds                                                                                                |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| [implementation.md](docs/implementation.md)                       | what exists, the traps in it, how to verify it. **Read first if you are touching the code.**                 |
| [design.md](docs/design.md)                                       | decisions, architecture, message flow, open questions. **Read first if you are extending the plan.**         |
| [reaching-agents.md](docs/reaching-agents.md)                     | every measured way to get a message to a waiting agent, and how to tell who sent one                         |
| [claude-code-sessions.md](docs/claude-code-sessions.md)           | reading Claude Code sessions, titles and state from disk                                                     |
| [focusing-sessions.md](docs/focusing-sessions.md)                 | how a session's pid resolves to the app hosting it, and what that cannot reach                               |
| [codex-sessions.md](docs/codex-sessions.md)                       | Codex's equivalents — session logs, liveness, titles, limits, hooks                                          |
| [limits-accounts-and-terms.md](docs/limits-accounts-and-terms.md) | plan-limit data, multiple accounts, and what the vendors' terms allow                                        |
| [landscape.md](docs/landscape.md)                                 | competitors and standards (A2A), and the gap Armada targets                                                  |
| [spike/](docs/spike/README.md)                                    | the throwaway code the measurements came from                                                                |
| [design/README.md](design/README.md)                              | the icon and the three menu bar glyphs: what is authored, what is generated, and the numbers behind the halo |

## Related repos

- `~/Projects/apps/bastion` — Swift 6 menu bar app by the same author. Source for the app shell, the
  config-file merge, and the embedded-Node pattern.
- `~/Developer/github/swift-mcp-kit` — the author's Swift MCP library. Armada uses its protocol core
  (`MCPKit`).
- `~/Projects/mgcrea/mgcrea-ai/mcp-a2a` — unreleased TypeScript A2A bridge. Its A2A peer is kept,
  off by default; its relay and tools are superseded for v1 messaging.
