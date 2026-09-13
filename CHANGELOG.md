# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Nothing has been released. There are no tags and no signed build; the app is built from source
with `make build`. When a release path exists it will be tagged `app-v<version>` the way the
sibling repos are, and GitHub release notes will be taken from this file, which is the curated
summary.

## [Unreleased]

The app went from nothing to a working menu bar app between 2026-09-11 and 2026-09-13. Entries
below are grouped by what they do rather than replayed commit by commit.

### Added

- **Sessions, per account.** Every live Claude Code session with its title, project, age and
  state, read from each config folder's registry and transcripts. Sortable by what needs you
  and groupable by project, with a context total per group.
- **State read rather than inferred.** Claude Code's registry carries `status`
  (`busy` / `waiting` / `idle`) and names what a waiting session wants in `waitingFor`. The
  older write-recency and unanswered-`tool_use` inference survives only as the fallback for a
  folder on a build older than 2.1.269.
- **Context occupancy.** How full a session's window is, where it started, the rate it has
  grown at, a projection, and the last compaction — for both vendors, through one renderer so
  the two panes cannot drift.
- **The prefix breakdown behind `/context`.** `get_context_usage`, asked of a spawned `claude`.
  It describes a comparable session rather than the watched one, and the pane says so.
- **Usage, per account.** The 5-hour and 7-day windows with reset times, asked live through the
  `get_usage` control request and falling back to the cache on disk, with a badge naming which
  answered and how old it is. Day-weighted pace forecasting, a Usage overview pane, and usage
  history recorded to disk.
- **Codex, as a spike.** A second sidebar section with its own sessions, plan limits and
  context, read from `~/.codex` — liveness from the writer locks, limits from `token_count`
  events in session logs, and a card in the global Usage pane beside the Claude accounts.
- **Focus.** A session row brings forward the application hosting it, resolved by walking the
  process tree, and raises that session's own window where Accessibility allows.
- **New sessions.** The detail pane with nothing selected is an account overview — the folders
  that account ran in last, a folder picker, and a tally of what its sessions are doing.
  Starting one opens a terminal running `claude` or `codex` in that folder on that account:
  Armada writes a startup script and hands it to Terminal, never owns the process, and the new
  session arrives through the watchers like any other.
- **Fork a session.** A copy of the session you are looking at, opened from where it stands, on
  the same account and in the same folder — from the detail pane, a row's right-click, or the
  menu bar popover. It is each vendor's own flag doing the work (`--resume … --fork-session` for
  Claude Code, `codex fork` for Codex), which is what makes it safe to offer for a session that
  is still running: forking mints a new id and leaves the original alone, where resuming would
  put two writers on one transcript. Claude Code records nothing linking the copy to its
  original and the pane says so; Codex writes `forked_from_id` into the new session's log.
- **Mouse bindings.** Middle and extra mouse buttons can cycle the session list or send a
  keystroke, through a `CGEventTap` whose mask is two event types wide.
- **Menu bar.** An accessory app with a per-account popover, and a template glyph that fills
  while anything is working and rings when a session wants attention, on a configurable ladder.
- **Settings** on `swift-support-kit`'s shared scaffold, with About and Help panes.

### Changed

- **The scope line "v1 watches; it doesn't launch agents" was reopened**, deliberately, when
  New Session landed. Armada still never owns an agent process and still holds no credentials;
  what changed is that it can ask a terminal to start one.
- **The menu bar halo is three assets** rather than a composed overlay, drawn as two arcs
  offset from each sail.

### Fixed

- **Codex plan limits lagged** behind what was on disk: the newest figures usually live in a
  rollout the session scan has no reason to open. The scan now always tails the newest rollout
  in the tree.
- **A Codex writer lock spans a session, not a turn** — confirmed, which is what makes
  "waiting for input" reachable.
- **A session adopted mid-flight showed the wrong age**, because `lastWrite` was not seeded
  from disk.
- **`CLAUDE_CONFIG_DIR` carried a trailing slash**, which made a stored value silently fail to
  match.

### Internal

- `make audit` asserts the built app reaches no network: every Mach-O swept for URL loading,
  DNS and TLS symbols, the sources for an internet address family, and the project for an
  entitlements file it does not have.
- `make icon` and `make icon-check` are real. The icon bundle, the web SVG and the three menu
  bar imagesets are all generated from `design/armada-mark.svg` and the three authored glyphs,
  and `icon-check` fails on a generated copy that has drifted.
- Licences: MIT at the root, and an Armada Source-Available License over `apps/apple/`.
