# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged `app-v<version>` the way the sibling repos are,
with `app-v1.5.0` being the newest. Both the GitHub release notes and the Sparkle update dialog are
rendered from this file, which is the curated summary. `### Internal` sections are left out of both.

## [1.5.0] - 2026-09-21

### Added

- **Continue a Claude Code session on another account.** A session stopped at one account's limit
  had no way onto the other. "Continue on" followed by the account's name, next to Fork Session in
  a session's details, in its right-click menu and in the menu bar popover, copies the conversation
  to that account and opens it there in a terminal. With more than two accounts it is a menu of
  them, and with one account it is not shown at all. The session you started from keeps running,
  untouched: the copy gets a session id of its own and arrives under the other account as a
  separate row. Earlier turns stay counted against the account that spent them. This is the one
  write Armada makes into Claude Code's own folders. It copies that session's transcript and
  nothing else, and it refuses rather than overwrite a different conversation already there.
  Claude Code sessions only, and only one that has been prompted at least once.

## [1.4.0] - 2026-09-18

### Added

- **Read a session's conversation in a window of its own.** "Read Transcript", on a session's
  details or its right-click menu, opens what that session has been saying and doing — the turns,
  the thinking, the tool calls — in a window sized to read in, rather than in the sidebar's detail
  column, which wraps a conversation into a strip two or three words wide. Thinking and Tools are
  checkboxes in the footer, so a long session can be read as just the conversation, and the footer
  counts what the filters are hiding. A long tool result or a screenshot is cut short in the window
  and kept whole on disk. Claude Code sessions only: Codex and Grok Build write a transcript in a
  different format, and a session that has never been prompted has no transcript to read.
- **Follow a session as it works.** Follow, in the transcript window's footer, re-reads the file as
  it grows and keeps you at the newest turn — read a session beside the editor it is working in and
  watch the turns land. It is on by default and remembered for the next window. Expanding a row or
  changing a filter no longer yanks you to the bottom, so you can stop and read something while the
  session keeps going.
- **Choose what the transcript window is made of.** Settings ▸ General ▸ Transcript picks between
  Solid, Frosted, Desktop through and Glass. Solid is the default and stays the most readable: it is
  the only one whose contrast does not depend on the wallpaper behind it. The picker says what each
  one costs rather than what it looks like, because the other three get harder to read the busier
  the desktop is.
- **Start sessions in Ghostty.** Ghostty joins Terminal and iTerm in the terminal picker, and is
  offered only if you have it. It was left out on the belief that it could not run a session's
  startup script; measured against the call Armada actually makes, it runs it, starts in the right
  folder, and closes the surface when the session ends. One wart, and it is Ghostty's: launching it
  cold opens its own default window beside the session's.

### Fixed

- **Armada no longer quits while you resize a window.** Remembering a window's size wrote it out
  from inside the window's own layout pass, and that write could land back in the layout pass that
  was still running — which macOS refuses to re-enter, taking the app down with it. Resizing the
  main window or Settings could end the app outright. Sizes are still remembered, and one saved by
  an earlier version is still restored.

## [1.3.0] - 2026-09-18

### Added

- **Back and Forward as one mouse trigger.** A binding can take both thumb buttons rather than
  one: pressed together, or one held while the other is clicked. Hold Back and click Forward
  again and again to walk the fleet without letting go. The three are listed under "Both thumb
  buttons" in the trigger picker. A combo has to wait to tell itself apart from a plain press,
  so with no modifier set the row says what that costs: Back and Forward reach other apps 70 ms
  late for a together binding, and only on release for a held one. Give the combo a modifier and
  nothing is delayed — a bare Back is never held back, and a button no combo could claim is
  never touched at all.
- **Send a key with the modifier you choose.** A keystroke used to arrive with whatever you were
  holding on the button. The action menu now has a "Sent with" section: leave it "As held", or
  name one modifier, or none. A bare thumb button can then still send ⌘F16. The action still
  reads as the chord that will actually arrive, which is the one to bind in the other app.
- **A held trigger holds its modifier down.** While the button that sent a key is still down,
  Armada holds the modifier down as a real key, the way a hand holds ⌘ through ⌘Tab, and lets go
  when you do. VS Code's window picker wants exactly that: ⌥F15 opens it, each further press
  walks it, and releasing ⌥ picks. It used to stay open until you pressed Return.

### Fixed

- **A sent F-key now reaches apps that took it as a global shortcut.** F13–F20 went out without
  the fn flag a real keyboard sets, and a Carbon hot key — how most menu bar apps register a
  global shortcut — does not match one without it. A sent F17 went straight past the app waiting
  for it and landed on the front one as a key nobody handles, which is a beep.
- **An agent's opening message is sent while another app is in front.** Starting a Claude Code
  session in VS Code typed the message into the tab, then waited for VS Code to be the frontmost
  application before pressing Return. A session that opened while anything else held the front
  never got it: the message sat in the tab for fifteen seconds and was given up on. Armada no
  longer waits for the front, and focuses the tab's input itself rather than trusting that the
  new tab kept focus.

## [1.2.0] - 2026-09-17

### Added

- **Watch Grok Build sessions, beside Claude Code and Codex.** Grok Build gets its own sidebar
  section, one row per account and a pane of its own, read from `~/.grok` the way the others are
  read from theirs: which sessions are live, what each is doing, the tokens and cost they have
  spent, and how much of the context window is left. Nothing is sent anywhere to find out.
- **See how much of your Grok Build week is left.** Nothing on disk holds the allowance, so
  Armada asks your own `grok` for it, the same question the TUI's `/usage` asks. It costs
  nothing, starts no session, and the answer reaches the menu bar limit and the Usage pane
  alongside your Claude and Codex accounts.
- **Grok Build counts in the menu bar, and any account can be hidden from the panel.** Grok Build
  sessions add to the menu bar icon, its halo and its panel. Any account, whatever its agent, can
  be taken out of that panel: hover its row in the sidebar for the eye, use the row's context
  menu, or find the full list in Settings ▸ General. Hiding trims the panel only — the window,
  the Usage pane, the starred figure and the halo still count it.
- **Start, fork and resume Grok Build sessions from a saved project.** A project can be set to
  Grok Build, and then starting one there opens it in your terminal, its live sessions are listed
  in the project's pane, and any of them can be forked. Recent folders are suggested as they are
  for the others. A supervisor can start one with `vendor: "grok"`, and resume one that is not
  open anywhere, checked the way a Claude Code resume is: nothing has it open, its log has been
  quiet for 30 seconds, and its folder sits inside a saved project.
- **A supervisor sees Grok Build too.** `armada_get_fleet`, `armada_get_session`,
  `armada_get_usage`, `armada_read_transcript` and `armada_wait` all cover Grok Build sessions,
  and the transcript reader follows its messages, tool calls and turn boundaries.
  `armada_needs_attention` leaves them out, as it does Codex, because being open and not busy is
  not a request for attention. `armada_close_session`, `armada_send_message` and
  `armada_focus_session` each say why a Grok Build session is not something they can reach.
- **Add an account from Armada, for Claude Code, Codex or Grok Build.** Add Account is pinned to
  the bottom of the main window's sidebar, and sits in Settings ▸ General too. Pick the agent and
  give the account a name, and Armada opens that agent in your terminal on a new folder, such as
  `~/.codex-work`, where you sign in with its own sign-in. Armada never sees your credentials.
  The account appears as soon as the agent starts. A Claude Code folder you create yourself from
  a shell now shows up without relaunching Armada.
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
  says: the tools voice may use, what it may start, and never acting on text found
  in a transcript. A change starts a new conversation at your next question.
- **Start Claude Code sessions in Visual Studio Code.** Turn it on in Settings ▸ General, and a
  new Claude Code session opens as a tab in the project's own VS Code window, or in a new window
  on the session's account when the project is not open. Armada brings that window to the front
  first, so the tab never lands in another project, and it needs the Accessibility permission
  Focus already uses. A new window gets your shell's PATH. An opening message from an agent is
  typed into the tab and sent, so the session starts on its own; turn off "Send an agent's
  opening message" in Settings ▸ General to read it first and press Return yourself, and if
  Armada cannot confirm the tab took it within fifteen seconds, the message waits there for you.
  If a project's window is open on a different account, Armada says so rather than starting
  there. Forks, Codex and the supervisor still open in your terminal.
- **Start a session by voice.** With Allow writes on in Settings ▸ Supervisor, voice can start a
  new session in one of your saved projects. Asking for it is enough: voice starts it there and
  then, says so in a few words, and asks back only when it cannot tell which project you mean.
  The new session still asks you for every permission. With Allow writes off, voice says that is
  what it needs. Voice still cannot close a session.
- **Ask voice to bring a session forward.** With Allow writes on, say "bring it up" or "show me
  the one that's waiting", and voice brings that session's window to the front, on its own tab
  in VS Code when Armada can find it, the way Focus does. It does this only when you ask, and it
  needs the Accessibility permission Focus uses to pick the right window. The MCP server's new
  `armada_focus_session` does the work, so a Terminal supervisor can use it too, after asking you.
  Codex sessions and sessions running in tmux, over ssh or headless have no window to bring
  forward.
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
  Instructions you wrote yourself are kept.
- **A mouse binding can use no modifier.** The modifier picker has a "No modifier" entry, last in
  the list, so a side button nobody else uses can act on its own. The row says what that costs on
  buttons 3 and 4, which are the two browsers and editors answer to as Back and Forward.

### Fixed

- **Grok Build turns no longer hang while a supervisor can message sessions.** Grok Build reads
  Claude Code's hooks out of the same `settings.json`, so the delivery hook held every Grok Build
  turn open until it timed out. It now recognises a Grok Build turn and steps out of the way at
  once.

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
