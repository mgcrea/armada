# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged `app-v<version>` the way the sibling repos are,
with `app-v1.1.0` being the newest. Both the GitHub release notes and the Sparkle update dialog are
rendered from this file, which is the curated summary. `### Internal` sections are left out of both.

## [Unreleased]

### Added

- **Set how loud replies are spoken.** Settings ▸ Voice has a Volume slider under Voice, for both
  the system voices and Kokoro. Letting go of it plays a sample at the new level.
- **Stop voice with Esc.** While voice is listening, thinking or speaking, Esc stops it and closes
  the card, and the card shows an esc key to say so. Armada takes Esc only for those seconds, so
  an Esc meant for the app you are in stops voice instead. Pressing the shortcut still stops a reply.
- **Choose how hard voice thinks.** Settings ▸ Voice has an Effort picker: Account default, as
  before, or Low, Medium or High. A change applies from your next question and keeps the
  conversation.
- **Answer voice without pressing the shortcut again.** When a spoken reply ends with a
  question, such as "Should I go ahead?", the card switches to Listening for your answer and you
  can just reply. Say nothing and the card closes. Settings ▸ Voice ▸ Keep listening sets it to
  Never, After a question (the default) or After every reply. It applies when you press to ask,
  not when you hold.
- **Choose the language voice answers in.** Settings ▸ Voice has an Answer in picker: the
  language you ask in, as before, or one language whatever you speak, such as English when you
  ask in French. Changing it starts a new conversation at your next question. The Voice picker
  lists that language's system voices, and it is the language a system voice falls back to while
  Kokoro is loading.
- **Tell voice how to answer.** Settings ▸ Voice has an Instructions box, filled in with how voice
  answers today: one to three short spoken sentences, sessions called by name. Rewrite it to
  change how replies sound, or go back with Reset to Default. Armada's own rules apply whatever it
  says: the tools voice may use, asking before it starts a session, and never acting on text found
  in a transcript. A change starts a new conversation at your next question.
- **Start Claude Code sessions in Visual Studio Code.** Turn it on in Settings ▸ General, and a
  new Claude Code session opens as a tab in the project's own VS Code window, or in a new window
  on the session's account when the project is not open. Armada brings that window to the front
  first, so the tab never lands in another project, and it needs the Accessibility permission
  Focus already uses. A new window gets your shell's PATH. An opening message from an agent is
  typed into the tab for you to send. If a project's window is open on a different account,
  Armada says so rather than starting there. Forks, Codex and the supervisor still open in your
  terminal.
- **Start a session by voice.** With Allow writes on in Settings ▸ Supervisor, voice can start a
  new session in one of your saved projects. It says which project, account and opening message
  it will use and waits for you to confirm before starting it, and the new session still asks
  you for every permission. With Allow writes off, voice says that is what it needs. Voice
  still cannot close a session.
- **A supervisor can close a Claude Code session.** With Allow writes on, the MCP server adds
  `armada_close_session`, which ends a session's process the way quitting it would: the
  transcript is kept and the session can be resumed. A session that is working or running a tool
  is closed only when the agent passes `force`, which the tool tells it to ask you about first.
  The supervisor is not pre-allowed to call it, voice cannot, Codex sessions cannot be closed,
  and an agent can close one session every five seconds.
- **A supervisor can watch, and resume what it closed.** `armada_wait` holds a call open until
  a session newly needs you or changes state, for up to four minutes, so a supervisor watches
  without polling; it only reads, and the supervisor is allowed it. `armada_start_session` now
  returns the new session's id when it opens in a terminal, and with Allow writes on it can
  resume a Claude Code session in a saved project that nothing has open, such as one it just
  closed, in the folder and on the account it ran on.
- **A supervisor can message a Claude Code session.** Turn on Settings ▸ Supervisor ▸ Deliver
  messages to sessions, and `armada_send_message` puts a message in front of a running session:
  an idle one starts a turn on it within a couple of seconds, and a busy one reads it when its
  turn ends. It works by adding one hook to each Claude Code account's `settings.json`, and
  turning the switch off removes exactly that hook. The session sees the message labelled as
  coming from an agent, not from you. It needs Allow writes, the supervisor asks you before each
  message, voice cannot send one, Codex sessions cannot be reached, and a message nothing picks up
  within an hour is dropped.

### Changed

- **Voice answers in a sentence, two at most.** It leads with the answer and leaves out the rest:
  no restating the question, no "it should show up in a few seconds", no list of every session.
  Before starting a session it asks one short question. Instructions you wrote yourself are kept.

## [1.1.0] - 2026-09-16

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
  dictation until you download Parakeet, and the audio is never kept. The question goes to
  Anthropic as text through your own `claude`, on the account you pick, and a follow-up
  continues the same conversation. Off by default; it reads the fleet through the MCP server in
  Settings ▸ Supervisor.
- **A more natural voice for replies, on this Mac.** Settings ▸ Voice can download Kokoro, about
  95 MB from huggingface.co, and read answers with it instead of a system voice. It runs on the
  Mac, reads English, and never makes an answer wait: a sentence goes to the system voice while
  Kokoro is still loading or when Kokoro cannot read it. Not offered on macOS 26.4 and 26.5, where
  an Apple bug crashes it.
- **Working hours for the weekly pace.** Settings ▸ Usage takes the hours you usually work and
  how much the rest of the day counts, so an evening's work is no longer measured against a week
  of round-the-clock days. The pace tick on a usage bar gains a caret above it, and hovering the
  bar says how many points ahead of or behind pace you are.
- **Focus from the row.** Session rows in the menu bar popover and in an account's session list
  carry a Focus button that brings forward the app hosting the session. It is drawn bright when
  it will reach the session itself, and dimmer when it will stop at the window or the app.
- **Focus reaches a session's own tab in VS Code.** For a session in the Claude Code extension,
  Focus raises the right window and then asks the extension to show that session's tab, which
  Accessibility cannot do. It asks only once the window in front is shown to hold the session,
  so a session is never opened a second time in another window. VS Code asks once whether
  Claude Code may open the link.

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
- **A second thing Armada can download: voice's speech models.** When Parakeet v3 or Kokoro is not
  already in FluidAudio's shared models folders, Settings ▸ Voice offers it, about 480 MB and
  95 MB from huggingface.co, and fetches each only when you press its Download button. `make audit`
  allows FluidAudio's download code in its own framework, `ArmadaSpeech`, and nowhere else.

### Fixed

- **A renamed session keeps its name.** Claude Code goes on writing AI titles after a rename, and
  Armada showed whichever title was newest, so a rename reverted as soon as the next AI title
  landed. The newest title you set now wins, and an AI title is shown only when there is none.

### Internal

- `ArmadaSupervisor`, a second local package: the voice `claude`'s stream-json decoding and
  argument lockdown, sentence chunking, the silence rule and the shortcut's reducer, under
  `make -C apps/apple test`.
- `ArmadaSpeech`, a dynamic framework holding FluidAudio, pinned to a revision as Cadence pins
  it, so its downloader's symbols live in one binary the audit names. It holds
  `ParakeetRecognizer` and `KokoroSynthesizer`.
- `PhonemeSplit` and `VoiceChoice` in `ArmadaSupervisor`: Kokoro takes at most 510 phonemes a call
  and FluidAudio no longer splits for it, and the stored voice identifier names a system voice or
  Kokoro.
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
