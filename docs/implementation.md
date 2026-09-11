# What is built

Status on 2026-09-11: **a working macOS app**, covering the first two of v1's three
features. [design.md](design.md) still describes v1 in full and remains the plan; this doc
says what of it exists, what was deliberately left out, and the things a reader would
otherwise have to rediscover.

The app lives in `apps/apple`. `make run` builds and launches it; `make build` and
`make format-swift-check` are what CI runs.

## What it does

- **Sessions**, per account: every live Claude Code session with its title, project, age and
  inferred state, plus a detail inspector.
- **Usage**, per account: the 5-hour and 7-day windows with reset times and a staleness
  badge.
- **Menu bar**: an accessory app (`LSUIElement`) with a popover summarising every account,
  and a template glyph that fills when anything is working.
- **Settings** on `swift-support-kit`'s shared scaffold, with an About pane and the Help
  menu.

Not built, and all of it deliberate: **messaging** (v1's third feature), hooks, `hubctl`,
the Unix socket, the MCP surface, Codex, and anything that writes to the user's Claude
config. This app only ever reads `~/.claude*`.

## The shape

The **account** — one Claude config folder — is the unit everything hangs off, because it is
the unit the data is organised by. Two folders share nothing: separate sessions, separate
transcripts, separate rate limits.

| Type | Holds |
| --- | --- |
| `ClaudeConfigFolder` | the one seam for a folder's paths; `discoverAll()` finds them |
| `Account` | a folder plus its identity, usage and session watcher |
| `Accounts` | every account; one timer and one FSEvents stream for the config files |
| `SessionWatcher` | one per account — FSEvents on its `sessions/` and `projects/` |
| `SessionRegistry` | decodes `sessions/<pid>.json` |
| `TranscriptLocator` | session → transcript path, with the encoding fallbacks |
| `TranscriptTitle` | tail read for the title, and the unanswered-`tool_use` state check |
| `UsageSnapshot` / `AccountIdentity` | the two halves of `.claude.json` |

Session watching is per account and config watching is shared, which is not an
inconsistency: each folder has its own directory trees worth a dedicated stream, while the
`.claude.json` files are a handful of documents with no per-folder cadence to justify one.

## Things that will bite the next person

Each of these cost time here, and none is visible from the code that depends on it.

- **`INFOPLIST_KEY_LSUIElement = YES`** is what makes this a menu bar app. Without it there
  is a permanent Dock icon and `DockPresence` is meaningless.
- **Three package products**, each needing *both* a product dependency and a Frameworks
  build file: `SupportKit`, `SupportKitUI`, `SupportKitSettings`. Wrong wiring compiles
  clean until the first `import`. Pinned from **1.1.1** — in 1.1.0 the settings sidebar
  draws and highlights but selects nothing.
- **The pbxproj was generated once and committed as a normal file.** There is no generator
  in the repo on purpose: the fleet's `pbxproj_add_product.py` edits it in place, and a
  regenerating script would clobber those edits. No sibling repo has one either.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** means a type is main-actor-isolated unless
  it says otherwise. `TranscriptTitle`, `UsageSnapshot` and `AccountIdentity` are
  `nonisolated` so their file I/O is real background work; dropping that keyword silently
  puts 54MB of transcript reading back on the thread drawing the window.
- **`resets_at` needs `.withFractionalSeconds`** — see
  [limits-accounts-and-terms.md](limits-accounts-and-terms.md#where-plan-limit-data-is).
- **`sessions/` holds `<pid>.<hash>.key` files** beside the registry JSON. Scan `*.json` or
  the session count roughly doubles.
- **`startedAt` is epoch milliseconds**, an `Int`, not a date string.
- **A persisted id must not carry a trailing slash.** `URL.path` on a URL built with
  `directoryHint: .isDirectory` ends in `/`; that leaked into the remembered sidebar
  selection and made a stored value silently fail to match.

## Verifying it against reality

The app's numbers are checkable, and were checked, against the machine it runs on:

```bash
ls ~/.claude/sessions/*.json | wc -l                       # session count per folder
jq '.cachedUsageUtilization.utilization
    | {five_hour, seven_day}' ~/.claude.json               # the two windows
grep -o '"aiTitle":"[^"]*"' <transcript>.jsonl | tail -1   # the title, last match wins
```

Two traps when doing this. `claude agents --json` reports whatever `CLAUDE_CONFIG_DIR` its
shell has, so it will disagree with the app for a good reason. And `kill(pid, 0)` proves a
pid exists, not that it is Claude — `ps -p <pid> -o comm=` is the honest check.

To exercise the degraded paths without touching real data, point the app at a fixture:

```bash
CLAUDE_CONFIG_DIR=/tmp/fake open apps/apple/.build/Build/Products/Debug/Armada.app
```

A truncated registry file is skipped, a `.claude.json` with no `cachedUsageUtilization`
shows an empty usage strip, and neither crashes.

## Known gaps

- **`armada.mgcrea.io` does not resolve**, so the Help menu's Support and Feedback items are
  dead links until the site ships. One line in `Support.swift`.
- **No tests**, and so no `make test`. A target that ran nothing would be worse than none.
- **Folder discovery is not watched**: a config folder created while Armada is running does
  not appear until relaunch.
- **State is inference, not truth.** Write-recency plus the unanswered-`tool_use` rule, which
  `claude-code-sessions.md` still files as unverified and which cannot tell a running tool
  from one waiting for approval. The UI marks it best-effort. Hooks would settle it, and
  hooks are out of scope.
