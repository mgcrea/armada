# Security

Armada reads every transcript on the machine — every conversation you have had with an agent,
across every account — and it can open a terminal running an agent on your behalf. A hole in
it is a hole in your entire working history. Reports are welcome and answered.

## Reporting

Email **security@mgcrea.io**. Do not open a public issue for something exploitable.

Include the commit (`Armada ▸ About` shows the one the build was made from, and
`ARMADA_GIT_COMMIT` carries it into the Info.plist), what you did, and what you expected to be
refused. A proof of concept against your own machine is ideal; one against somebody else's is
not needed and not wanted.

## What Armada claims

Three properties, each of which is checkable rather than asserted:

- **It reaches no network on its own, with two named exceptions.** No telemetry, no licence
  call. The first is the update check, which is off until you turn it on or press Check
  Now; it reads one file, `armada.mgcrea.io/appcast.xml`, and sends no identifier with it —
  not your licence key, not a machine id. Until you opt in, the updater is never even
  constructed. The second is voice's speech models: a Download button in Settings ▸ Voice
  fetches Parakeet v3 or Kokoro from huggingface.co, with the host fixed in code and no identifier
  or token sent, and nothing else ever starts either. `make audit` asserts all of this against the built bundle:
  every Mach-O swept for URL loading, DNS and TLS symbols, with Sparkle allowed exactly the
  three URL-loading classes it was measured to use, `ArmadaSpeech.framework` exactly the
  URL-loading and name-lookup symbols FluidAudio's downloader was measured to use, and nothing
  more; the shipped Info.plist asserted to keep
  checks off and to point at that one feed; the sources swept for an internet address
  family; and one entitlement, the microphone for voice, named in the project and alone in the
  signature.

  The one socket it listens on is the supervisor's MCP endpoint, and only once you turn it on
  in Settings ▸ Supervisor. It is swift-mcp-kit's listener, bound to `127.0.0.1` and not
  configurable to anything else, answering only a 256-bit bearer token kept in the Keychain,
  and six of its seven tools are read-only. The seventh, `armada_start_session`, is listed and
  callable only while Allow writes is on, which it is not by default: it opens Terminal on a
  fresh session in a folder you saved as a project, and that session asks you for every
  permission as usual. `make audit` checks the listener's source for the
  loopback address and refuses a wildcard.

  Voice, once you turn it on in Settings ▸ Voice, opens the microphone only from a press of its
  shortcut to the end of the question. Speech is recognised on this Mac, by Parakeet v3 when the
  model is there and by Apple's dictation until then; the audio is never stored or sent, and replies are spoken on this Mac, by the system synthesizer or by Kokoro once downloaded. The question itself goes to Anthropic
  as text, through a `claude` Armada runs on the account you choose: see "The voice `claude`"
  below. The shortcut is registered with `RegisterEventHotKey`, which delivers that one chord
  and no other keystroke.

- **It never writes to a vendor's configuration.** `~/.claude*` and `~/.codex` are opened
  read-only. Armada installs no hook, writes no `settings.json`, and adds no MCP server entry.
  The only things it writes anywhere are its own preferences; its usage history, saved projects
  and token ledger (`usage-history.json`, `projects.json`, `usage-index.sqlite`) in Application
  Support; and a session startup script in its own temporary directory — beside which a
  supervisor session's MCP configuration, or an agent-started session's opening message, is
  written, readable by you alone. That session is told about Armada on its own command line;
  nothing is added to the account's configuration. Voice keeps one working directory per
  account in Application Support, where its `claude` records the conversation, and writes that
  `claude`'s MCP configuration, 0600, to its own temporary directory.
- **It holds no vendor credentials.** There is no "sign in with Claude", nothing reads or
  stores an OAuth token, and `auth.json` is never opened — a Codex plan name arrives inside
  the rate limits as `plan_type`, so no credential file is touched at all. The reasoning, and
  the three alternatives that were weighed and declined, are in
  [docs/limits-accounts-and-terms.md](docs/limits-accounts-and-terms.md).

## What it reads

Read-only is not the same as narrow, so the whole read surface is listed here rather than left
to "`~/.claude*` and `~/.codex`":

- **Each account's own folders:** `~/.claude`, every `~/.claude-*` beside it, `CLAUDE_CONFIG_DIR`,
  `~/.codex` and `CODEX_HOME`, for session registries, transcripts, session logs and cached
  usage. Finding the `~/.claude-*` folders means listing the top of your home folder. Every
  transcript and session log is read, Codex's `archived_sessions` included, for the tokens each
  project spent; what is kept is counts per day, folder, account and model, never text.
- **`~/.claude.json`**, watched for changes, for the plan usage Claude Code caches there.
- **`~/.vscode/extensions`**, listed to find a `codex` binary bundled with the Codex extension.
- **`.git`, up to four folders above each session's working folder**, checked for existence
  only, to name the window that session belongs to.
- **The process table**, walked from a session's process up through its parents, to find the
  application hosting it.
- **Your project's configuration, through `claude`.** The context breakdown spawns your own
  `claude` inside a session's working folder, so that process reads what any `claude` started
  there reads, including the project's `CLAUDE.md` and its settings.

None of it leaves the Mac through Armada. The only request Armada makes is the opt-in update
check, and the only thing it serves is the opt-in loopback MCP endpoint described above.

## In scope

Anything that breaks one of the three above. Beyond them, the sharp edges are where
attacker-influenced text meets something that acts on it:

- **Transcript content is not trusted input.** A session's title, its `cwd` and its
  `waitingFor` string are written by an agent that may have read a hostile repo, web page or
  email. Anything that lets one of those reach a shell, a file path outside the transcript
  tree, or a rendered link is in scope. `SessionRegistry.waitingFor` in particular is display
  text with a vocabulary that grows per release — code that branches on it is a bug, and code
  that executes anything derived from it is a vulnerability.
- **The session startup script.** Starting a session writes a `.command` file into Armada's
  own temporary directory and hands it to Terminal. Every path that reaches it goes through
  `LaunchScript.quoted` as a single-quoted shell word; anything that escapes that quoting, or
  that gets the script written somewhere another user can replace it before Terminal opens
  it, is in scope. An opening message an agent sends through `armada_start_session` never
  appears in the script: it is written to a 0600 file beside it, read into a variable and
  removed before the agent starts, and passed as one double-quoted word, and a message that
  begins with `-`, `!` or `/` is refused. Anything that gets that message into the script's
  text, or read by the CLI as a flag, a shell escape or a slash command, is in scope.
- **The MCP endpoint.** Switched on, Armada serves six read-only tools on `127.0.0.1` to
  whoever presents the token, and a seventh that starts a session only while Allow writes is
  on. Anything that reaches a tool without the token, gets past the kit's `Host` and `Origin`
  checks from a web page, binds another interface, calls `armada_start_session` with Allow
  writes off, starts a session in a folder that is not a saved project, adds another tool that
  writes, or leaks the token is in scope. That includes the supervisor's MCP configuration, which holds
  the token: it is created 0600 in the launch's own temporary directory and pruned with the
  script, and anything that makes it readable by another user or puts the token on a command
  line is in scope.
- **The spawned `claude`.** `ClaudeControl` runs the user's own `claude` headless to ask one
  control request. Anything that changes _which_ binary is run, or that gets an argument or
  an environment variable in from data rather than from configuration, is in scope.
- **The voice `claude`.** `SupervisorProcess` runs the user's own `claude` headless for as long
  as a voice conversation is active, and closes it after five idle minutes. It is started with
  no built-in tools (`--tools ""`), with Armada's MCP server and no other
  (`--strict-mcp-config`), with the six read tools allowed by name and `armada_start_session`
  denied by name, without the person's user settings or hooks, and with no permission bypass;
  `SupervisorArgumentsTests` pins every one of those. Anything that gives it another tool,
  another server or a way to write, that puts data rather than the spoken question into its
  arguments or stdin, or that signals a process Armada did not start, is in scope.
- **The microphone.** Voice captures audio only between a shortcut press and the end of that
  question, converts it to text on this Mac with Parakeet v3 through FluidAudio, or with
  `DictationTranscriber` until Parakeet is installed, and keeps nothing.
  Anything that leaves the microphone open outside a question, stores or sends audio, or starts
  listening without the shortcut, is in scope.
- **The speech models and their downloads.** `ParakeetRecognizer` loads Parakeet from
  FluidAudio's shared folder, `~/Library/Application Support/FluidAudio/Models`, and
  `KokoroSynthesizer` loads Kokoro from `~/.cache/fluidaudio/Models`, only once every file it would
  otherwise fetch is there. Both load with FluidAudio's offline mode on, so loading never fetches.
  Each download runs only from its Download button: it
  pins the registry to `https://huggingface.co` in code, over FluidAudio's `REGISTRY_URL` and
  `MODEL_REGISTRY_URL` environment overrides, and removes the Hugging Face token variables
  FluidAudio would otherwise forward. Anything that starts a fetch without those buttons, sends an
  identifier, reaches another host, or loads model files from anywhere else, is in scope. A model
  replaced in that shared folder by another program running as you is not: see below.
- **The voice shortcut.** One chord through `RegisterEventHotKey`, and a local key monitor in
  Armada's own Settings window only while a new chord is being recorded. Anything that lets
  Armada see another keystroke is in scope.
- **The mouse event tap.** Mouse bindings install a `CGEventTap` under the Accessibility grant
  Armada already holds for window focusing. Its mask is deliberately two event types wide —
  `otherMouseDown` and `otherMouseUp`, the middle and extra buttons — so left clicks, right
  clicks, movement, scrolling and every keystroke are outside it and never reach the callback.
  Anything that widens that mask, that records or forwards what the tap sees, or that gets a
  binding to synthesise a keystroke into a window other than the one it names, is in scope.
  A tap sees nothing inside a Secure Input context, so a binding is dead while a password
  field has focus; that is stated in Settings rather than left to be discovered.

## Not in scope

- **What the `claude` or `codex` process does.** It talks to its vendor over the user's own
  sign-in — that is the program's job, and running it unmodified is the arrangement
  [docs/limits-accounts-and-terms.md](docs/limits-accounts-and-terms.md) is built around.
  Armada spawns it and reads its answers.
- **What an agent itself decides to do.** Armada watches sessions and answers questions about
  them; it does not direct them. A supervisor session is an ordinary agent reading those
  answers, and transcript text reaching it through `armada_read_transcript` is labelled as data
  written by other agents. Whether a model then follows instructions inside it is that model's
  behaviour, not Armada's. The one thing such an instruction could make a supervisor do
  through Armada is start a session, and that is fenced on Armada's side: Allow writes is off
  by default, the supervisor is not pre-allowed the start tool so Claude Code asks you first
  with the project and message in view, and the new session asks for every permission itself.
- **Other programs running as the same macOS user.** They can already read every transcript
  and rewrite every agent's config directly, so nothing in Armada changes their reach. This
  is stated as an explicit out-of-scope in [docs/design.md](docs/design.md#security-model-drafted)
  rather than left implied.

## Messaging, when it lands

v1's third feature — messages between agents — is designed and not built, and it is the part
that will move the threat model rather than extend it. The measurement that makes it dangerous
is already recorded: **Claude acts on text delivered by a hook**, having refused the same
request delivered through a channel. Whatever delivers messages can steer every agent on the
machine.

The design answers that with a router that decides delivery rather than the sender, an explicit
policy per pair of agents, labelling and an audit log — see
[docs/design.md](docs/design.md#security-model-drafted) and
[docs/reaching-agents.md](docs/reaching-agents.md). None of it exists yet. Until it does,
Armada installs no hook and delivers nothing to any agent. The only MCP tools it serves are the
supervisor's, on loopback, off until you turn them on — and the one of them that starts a session
is off again until you allow writes — and `make audit` is what keeps the network half of that
honest.

## Supported versions

Only the newest release is supported. Fixes ship in the next release rather than being back-ported,
and the update check offers that release to every earlier build. Report against the newest release
or `main`.
