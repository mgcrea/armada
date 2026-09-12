# Focusing a session: getting from a row back to the window

Measured on 2026-09-11 on one Mac running Claude Code 2.1.267–2.1.268, VS Code with the
Claude Code extension, and Terminal.app.

Armada's session rows offer one action: **Focus**, which brings forward the application a
session is running inside. This is what that can reach, what it cannot, and why.

## What the registry gives us

`~/.claude/sessions/<pid>.json` carries a `pid`, a `cwd`, an `entrypoint` and a name. It
carries **no tty, no window id and no terminal application**. The pid is the only handle,
so everything below is derived from the process tree.

## The mechanism

Walk the ppid chain from the agent pid and stop at the first ancestor that is a real
application — `NSRunningApplication` with `activationPolicy == .regular`. Then
`NSApp.yieldActivation(to:)` followed by `activate(from:options:)`.

No entitlement, no TCC grant, no prompt. `KERN_PROC_PID` is readable for any process
regardless of owner, which it has to be — `login` runs as uid 0 in the middle of every
Terminal chain.

Two chains, both verified:

| Host | Chain |
| --- | --- |
| VS Code extension | `claude (64548)` → `Code Helper (Plugin) (60364)` → `Visual Studio Code (3280)` |
| Terminal.app | `zsh (2116)` → `login (2115, uid 0)` → `Terminal (2114)` |

Cost, measured with `ContinuousClock`: **0.57ms cold, 0.05ms warm.** Fine per selection
change or per menu build; not fine per row per redraw, which is why `SessionHostLookup`
caches and why nothing calls it from a row body.

## What this reaches, and what it does not

**It names the application, never the window or the tab.** That is the honest ceiling of a
process walk, and it is why the button reads "Focus in Visual Studio Code" rather than "Go
to session" — the label promises exactly what it delivers.

The uncomfortable consequence: **on a Mac running many sessions in one VS Code, every
session resolves to the same application**, so Focus is the same action for all of them. It
is still worth having (it is right for terminal users, and right when Armada is not the
frontmost app), but it does not disambiguate.

Sessions with no host at all, where the button is replaced by an explanation:

- **tmux and screen.** Verified against a real pane: the shell's only ancestor is the tmux
  server, which is itself a child of launchd (`sleep (79605)` → `tmux (79604)` → `launchd`).
  The server is a binary in no bundle and the shell beneath it has no relationship to any
  application, so the walk correctly finds nothing. Genuinely hostless — the UI says so
  rather than guessing at whichever terminal is frontmost.
- **ssh, daemons, `claude -p` in CI.** Same shape. Verified against a daemon-launched
  process (ppid 1): an empty chain, no host.

**iTerm2 is a special case that is handled.** With session restoration on (the default) it
runs shells under a daemonized `iTermServer-3.5.x` that calls `setsid` and reparents to
launchd, so the ppid walk reaches pid 1 without passing through iTerm. But that server
lives *inside* the bundle, so the executable path names the application the process tree
does not. Untested — neither iTerm2 nor Ghostty is installed on the Mac this was measured
on.

## Two traps worth writing down

**`NSRunningApplication` has no no-argument `activate()`.** That one is `NSApplication`'s.
Since macOS 14 activation is cooperative and the system declines requests from an
application that is not itself frontmost; `NSRunningApplication.h` says the requester
"should call `-yieldActivationToApplication:` or equivalent prior to this request being
sent". A bare `activateWithOptions([])` from an `LSUIElement` app silently no-ops some of
the time.

**Pid reuse is real and has to be guarded.** Pids wrap on this machine — a pid of 344 with
a parent of 98106 was observed. A crashed session leaves its `sessions/<pid>.json` behind,
so a stale file can name a pid that now belongs to a stranger, and focusing that would
raise an unrelated application. The guard is free: the registry's `startedAt` and the
kernel's `p_starttime` agree to the second (pid 90861: `1789160285921` vs
`Fri Sep 11 22:58:04 2026`), so a few seconds of tolerance settles it. Verified by pointing
a real session's `startedAt` at pid 1 — the lookup correctly returns no host.

**`localizedName` is the wrong name for the commonest host.** VS Code reports
`localizedName`, `CFBundleName` and `CFBundleDisplayName` all as "Code"; its bundle is
`Visual Studio Code.app`, and that is what the Dock shows. The bundle filename wins.

## The menu bar popover has two traps of its own

Both found by shipping it and having a click do nothing visible.

**The panel does not close itself, and SwiftUI will not close it for you.**
`MenuBarExtra` takes `isInserted` — whether the item is in the menu bar at all — and has
no `isPresented` on any overload; checked against the macOS 26.5 SwiftUI interface. The
panel is dismissed by the app resigning active, so when the session's host is *already*
frontmost, focusing it changes nothing, nothing resigns, and the panel stays up. The click
is then completely invisible and reads as a dead button.

It has to be closed as the window it is. The predicate is `DockPresence`'s, inverted: a
real window can become main and this panel cannot. Verified against a stand-in
`nonactivatingPanel` — it closes the panel, keeps the window, and does nothing when only a
real window is up, which is the failure that would actually hurt.

**`pointerStyle(.link)` does not show over a row in that panel.** The cursor stays an
arrow, so the only feedback a row gave was the `.plain` press flash *after* the click. A
hover fill is the affordance instead: unlike a pointer style it is visible before
committing, and it is what a menu row is expected to have anyway. Note the two existing
header buttons in `StatusMenu` lean on `pointerStyle` alone and may well have the same
problem.

Related: `Spacer` does not hit-test, so a row needs `contentShape(.rect)` or most of its
width is dead to both the click and the hover.

## Codex cannot do this at all

`CodexSession` has no pid anywhere — liveness is a flock on
`~/.codex/thread-writer-locks/<id>.lock`, and `lsof` shows the file held with no pid
readable out of it (see `CodexLocks.swift`). There is nothing to walk. `CodexPane` shows no
Focus affordance rather than a disabled one, because a greyed-out button with no
explanation reads as a bug in Armada rather than a limitation of Codex.

## Deferred: the exact window or tab

Not built. Both tiers below cost a TCC grant, and neither reaches the thing people actually
mean, so they wait for evidence that app-level focus is not enough.

**Terminal.app and iTerm2, by controlling tty.** Both expose a `tty` property on the
scripting object that owns a pane, so `ProcessAncestry.controllingTTY` (already written,
and verified returning `/dev/ttys000`) is an *exact* key for a tab rather than a heuristic.
Needs `INFOPLIST_KEY_NSAppleEventsUsageDescription` and an Automation grant — but **no
entitlements file**: `com.apple.security.automation.apple-events` is a sandbox entitlement
and `ENABLE_APP_SANDBOX = NO`. Probe with `AEDeterminePermissionToAutomateTarget(…,
askUserIfNeeded: false)` first so a denial degrades silently. Ghostty ships no scripting
dictionary and would always fall back.

Note that **the tty is nil for every VS Code-hosted session** — measured, all 20 `claude`
processes on this Mac show `??` under `ps -o tty`, because the extension speaks to the CLI
over pipes and allocates no pty. So this tier buys nothing for the common case here.

**VS Code, by `AXRaise`.** Needs an Accessibility grant (no plist key, no entitlement),
gated on `AXIsProcessTrustedWithOptions`. The grant is keyed to the code signature, so
rebuilding revokes it — painful during development. And the ceiling is low: VS Code titles
are `<file> — <folder>`, two windows on the same folder are indistinguishable, and even a
perfect match raises the *window*, never the Claude panel inside it.

`SessionHost.containerPID` — the extension-host pid, one per window — is the only exact
handle that separates two sessions in the same application, and it is captured already. It
can *group* sessions ("these three are in the same window") without ever resolving which
window that is; there is no supported way to map it to an AX window.

## On "v1 watches; it doesn't launch agents"

`design.md` still holds. Focus activates an application that is already running, and
nothing here starts a session. The one edge: when the host has quit, the fallback goes
through LaunchServices, which will relaunch it. The terminal is not the agent.
