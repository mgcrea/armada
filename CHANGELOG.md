# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged `app-v<version>` the way the sibling repos are,
with `app-v1.0.0` being the newest. Both the GitHub release notes and the Sparkle update dialog are
rendered from this file, which is the curated summary. `### Internal` sections are left out of both.

## [Unreleased]

### Added

- **Projects.** A new pane under Usage lists the folders you work in, and starts a Claude Code
  or Codex session in one with a click, on the account the project remembers or on any other,
  even in a folder that has never had a session. Select a project to see the live sessions
  inside it, subfolders and worktrees included. Add several folders at once from the picker or
  by dropping them from Finder, and "Add to Projects" is on every session row and recent folder.
- **Tokens spent, per project.** A project's pane shows the tokens used in it over 7 days, 30
  days and all time, split by model, account and subfolder. They are read in the background
  from every Claude Code transcript and Codex rollout on the Mac, each response counted once
  even when a resumed or forked session copies it, and kept after Claude Code clears old
  transcripts.
- **`armada_get_projects`.** The MCP server's sixth read-only tool: each saved project's
  default agent and account, its live sessions, and its tokens over 7 days, 30 days and all
  time, with a split by model and account for one project. It says when older transcripts are
  still being read, so an agent does not quote a low total as final.
- **Agents can start sessions, when you allow it.** Settings ▸ Supervisor has an Allow writes
  switch, off by default. Turned on, the MCP server adds `armada_start_session`, which opens
  your terminal on a fresh Claude Code or Codex session in one of your saved projects, on its
  own account or one the agent names, optionally with an opening message. The session asks you
  for every permission as usual, the supervisor is not pre-allowed to call it, and a message
  that would be read as a flag, a shell command or a slash command is refused.
- **Connect a client with one click.** Settings ▸ Supervisor lists the MCP clients on your Mac,
  Claude Code once per account plus ChatGPT & Codex, Cursor and Visual Studio Code, and adds
  Armada to any of them with Configure or takes it back out with Remove. Nothing else in the
  client's config changes, the previous file is kept beside it as a backup, and a server of
  someone else's that already uses the name is never replaced without asking. Regenerating the
  token or changing the port updates every client configured this way. The copy-paste setup is
  still there for any other client.

- **Talk to Armada.** Settings ▸ Voice gives Armada a global shortcut: press it, or hold it,
  anywhere on the Mac, ask about your sessions out loud, and a card at the top of the screen
  shows the question and then the answer while it is spoken. Your speech is recognised on the
  Mac by Parakeet v3, which works out which of 25 languages you are speaking, or by Apple's
  dictation until you download Parakeet, and the audio is never kept. The question goes to Anthropic as text through your own
  `claude`, on the account you pick, and a follow-up continues the same conversation. Off by
  default; it reads the fleet through the MCP server in Settings ▸ Supervisor.

### Changed

- **Sessions in a saved project skip Claude Code's trust dialog.** Starting a Claude Code
  session in a project you saved marks its folder trusted on that account, the flag "Yes, I
  trust this folder" sets, so the session opens on its prompt. It is the one thing Armada writes
  to Claude Code's configuration: one field in `.claude.json`, written under Claude Code's own
  lock and edited in place, with the rest of the file left exactly as it was.
- **Armada runs a `claude` of its own while you talk to it.** Voice starts your installed
  `claude` headless with no built-in tools and only Armada's six read tools, keeps it for
  follow-up questions, and closes it after five idle minutes. It is the one agent process
  Armada owns rather than watches.
- **One entitlement: the microphone.** The app is signed with
  `com.apple.security.device.audio-input`, used only while voice listens. `make audit` and
  `make sign` allow exactly that key and fail on any other.
- **A second thing Armada can download: voice's speech model.** When Parakeet v3 is not already
  in FluidAudio's shared models folder, Settings ▸ Voice offers it, about 480 MB from
  huggingface.co, and fetches it only when you press Download. `make audit` allows FluidAudio's
  download code in its own framework, `ArmadaSpeech`, and nowhere else.

### Internal

- `ArmadaSupervisor`, a second local package: the voice `claude`'s stream-json decoding and
  argument lockdown, sentence chunking, the silence rule and the shortcut's reducer, under
  `make -C apps/apple test`.
- `ArmadaSpeech`, a dynamic framework holding FluidAudio, pinned to a revision as Cadence pins
  it, so its downloader's symbols live in one binary the audit names.
- Client configs are written by `MCPKitWiring`, a new product in `swift-mcp-kit` 1.1.0 that
  holds the merge, the Codex TOML splice and the backup rules Bastion and Cupertino each carried
  a copy of.

## [1.0.0] - 2026-09-14

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
  Star one plan limit, in Usage or above an account's sessions, and its percentage sits beside
  the glyph in small type.
- **Settings** on `swift-support-kit`'s shared scaffold, with About and Help panes.
- **What's New**, a Settings pane generated from this file, with a dot in the menu bar popover
  while a release is unread.
- **Updates, off until you say otherwise.** Sparkle reads one file, `armada.mgcrea.io/appcast.xml`,
  only once automatic checks are on or Check Now is pressed, and sends no identifier with it. A
  one-time card in the main window asks.
- **A licence, and a 30-minute trial.** One key covers every 1.x release on every Mac you own and
  is verified offline, on the Mac. Without one Armada watches nothing and says so where the
  sessions would be; the trial runs everything, and is started by hand.
- **A supervisor for the fleet, off until you turn it on.** Settings ▸ Supervisor runs a read-only
  MCP server on 127.0.0.1 and starts a Claude Code session with it attached, so you can ask one
  session which of the others need you, what any of them is doing or last said, and how much plan
  is left. Five tools, none of which can change a session, start one or write anywhere. The session
  runs on your own plan, and its connection details never touch your Claude configuration.
- **A network claim you can check.** Armada reaches no network on its own apart from the opt-in
  update check, and listens on one socket, the supervisor's MCP endpoint, on 127.0.0.1 only.
  `SECURITY.md` says so, and `make audit` asserts it against the built app.

### Internal

- `make audit` asserts the built app reaches no network: every Mach-O swept for URL loading,
  DNS and TLS symbols, the sources for an internet address family, and the project for an
  entitlements file it does not have.
- `make icon` and `make icon-check` are real. The icon bundle, the web SVG and the three menu
  bar imagesets are all generated from `design/armada-mark.svg` and the three authored glyphs,
  and `icon-check` fails on a generated copy that has drifted.
- Licences: MIT at the root, and an Armada Source-Available License over `apps/apple/`.
- `make test` runs the `ArmadaMCP` package's suite against a fake fleet, the repo's first Swift
  tests, and CI runs it after the build.
- The release path: `make build-release` signs inside out, notarizes and staples, `make appcast`
  signs a one-item feed over the stapled zip, and a `release-app` CI job runs both from an
  `app-v*` tag.
- `armada.mgcrea.io` on Workers static assets, and the licence Worker at `api.armada.mgcrea.io`,
  which mints and emails a key when Stripe reports a sale and refuses any sale that is not
  Armada's.
