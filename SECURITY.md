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

- **It reaches no network on its own, with one named exception.** No telemetry, no licence
  call. The exception is the update check, which is off until you turn it on or press Check
  Now; it reads one file, `armada.mgcrea.io/appcast.xml`, and sends no identifier with it —
  not your licence key, not a machine id. Until you opt in, the updater is never even
  constructed. `make audit` asserts all of this against the built bundle: every Mach-O swept
  for URL loading, DNS and TLS symbols, with Sparkle allowed exactly the three URL-loading
  classes it was measured to use and nothing more; the shipped Info.plist asserted to keep
  checks off and to point at that one feed; the sources swept for an internet address
  family; and no entitlements, in the project or in the signature.
- **It never writes to a vendor's configuration.** `~/.claude*` and `~/.codex` are opened
  read-only. Armada installs no hook, writes no `settings.json`, and adds no MCP server entry.
  The only things it writes anywhere are its own preferences, its usage history in Application
  Support, and a session startup script in its own temporary directory.
- **It holds no vendor credentials.** There is no "sign in with Claude", nothing reads or
  stores an OAuth token, and `auth.json` is never opened — a Codex plan name arrives inside
  the rate limits as `plan_type`, so no credential file is touched at all. The reasoning, and
  the three alternatives that were weighed and declined, are in
  [docs/limits-accounts-and-terms.md](docs/limits-accounts-and-terms.md).

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
  `NewSession.quoted` as a single-quoted shell word; anything that escapes that quoting, or
  that gets the script written somewhere another user can replace it before Terminal opens
  it, is in scope.
- **The spawned `claude`.** `ClaudeControl` runs the user's own `claude` headless to ask one
  control request. Anything that changes _which_ binary is run, or that gets an argument or
  an environment variable in from data rather than from configuration, is in scope.
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
  Armada spawns it and reads one answer.
- **What an agent itself decides to do.** Armada watches sessions; it does not supervise them
  and has never claimed to.
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
Armada opens no socket beyond the opt-in update check, installs no hook and serves no MCP
tools, and `make audit` is what keeps that honest.

## Supported versions

There is no released build. Report against `main`; there is nothing older to back-port to.
