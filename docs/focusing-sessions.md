# Focusing a session: getting from a row back to the window

Measured on 2026-09-11 on one Mac running Claude Code 2.1.267–2.1.268, VS Code with the
Claude Code extension, and Terminal.app. The window half was measured on 2026-09-12 on
the same Mac.

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

**The walk names the application, never the window or the tab.** That is the honest
ceiling of a process walk, and it is why the button reads "Focus in Visual Studio Code"
rather than "Go to session" — the label promises exactly what it delivers.

The uncomfortable consequence: **on a Mac running many sessions in one VS Code, every
session resolves to the same application**, so activating it is the same action for all of
them and macOS picks the window — whichever was frontmost last, which is almost never the
session's own. That is what [the window, by title](#the-window-by-title) below fixes, and it
needs a permission the walk does not. Without that permission this is still what happens,
and it is still worth having: it is right for terminal users, and right when Armada is not
the frontmost app.

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

## The window, by title

Measured 2026-09-12. The process walk shipped first and the complaint came back straight
away — six VS Code windows, and Focus landed on the wrong one every time the right one was
not already in front. So the VS Code tier that the last section of this document deferred
was built, with the Accessibility grant it always needed.

`HostWindow.raise` reads the host application's window titles through the Accessibility API
and raises the one whose title names the session's folder. Here is what those titles
actually are, read live from the six windows of pid 3280:

```
Menubar icon halo border — armada — Skitrust
X metrics support — almanac — Skitrust
Sentry MCP latest error — lisphoto-shopify-apps — TypeScript
Sandro lookbook commits … — smcp-lookbook-platform — Swift
Direct sales apps settin… — apps — Skitrust
Progress bar and pro-mod… — cadence — TypeScript
```

Three things in that, and not one of them was safe to assume:

- **It is not `<file> — <folder> — Visual Studio Code`**, which is what VS Code's default
  `window.title` template reads as. The first segment is the *active tab*, and in all six
  the active tab is the Claude Code panel — so it is the panel's own session title. The last
  segment is the VS Code **profile**, not the application name.
- **The first segment is truncated with an ellipsis. The folder segment never is.**
- The folder segment is the one dependable thing in the line, and it is exactly what the
  registry's `cwd` already names.

So the match is on segments, split on the dashes, and a segment that *equals* the folder
wins. A bounded substring search — word boundaries, so `armada` matches neither
`armada-old` nor `armada.ts` — is a second pass, for an application whose titles are shaped
some other way. Exact segments are tried across every candidate before any loose match, and
**no bundle identifier appears anywhere**, which is why Cursor, VSCodium and Windsurf get
this for free and why a terminal window whose title carries the folder does too.

**Repository roots go before deeper folders.** A session in a subfolder walks up — a window
on `~/Projects/apps` holding a session in `~/Projects/apps/armada` is found by `apps` once
`armada` has found nothing. Deepest-first alone gets `~/Projects/apps/armada/apps/apple`
wrong, though: its `apps` is nearer than `armada`, so it wins, and it matches the *other*
window, the one holding `~/Projects/apps`. Two unrelated directories sharing a name is
precisely what matching on names cannot see. Preferring a candidate that is a repository
root costs four `stat` calls and settles it; a `.git` that is a file counts, because that is
what a worktree has.

Nine cases were run against those six live titles — every window by its own `cwd`, the
subfolder collision above, a project with no window open, and `~` itself. All nine pick what
they should, and the two that should find nothing do.

**What it still cannot do**, and the button's label stays honest about all of it:

- The window, never the tab, and never the Claude panel inside the window.
- Two windows on the same folder are indistinguishable. The frontmost of the matches wins,
  which is at worst what would have happened anyway.
- A `window.title` customised to drop `${rootName}`, or a folder whose name appears in no
  title, matches nothing and falls back to activating the application.
- Terminal.app tabs: only the active tab's title is the window's title, so a session in a
  background tab falls back. That is the tty tier below, still deferred and still the right
  answer for an exact *tab*.

**The grant.** `AXIsProcessTrusted()` is asked silently — its `WithOptions` sibling puts a
system alert on screen and this never does. Settings carries the row that offers it and says
what it buys; the Focus button carries a caption only while the grant is missing. Nothing
prompts at launch. The grant is keyed to the code signature and Debug builds have their own
bundle identifier, so granting `io.mgcrea.armada.debug` says nothing about the shipped
`io.mgcrea.armada` — expect to grant twice while working on this.

**One trap that is not about windows at all.** Accessibility calls are synchronous IPC on
the calling thread and the default timeout is six seconds, so a wedged Electron app would
freeze Armada's UI for as long as it stayed wedged. `AXUIElementSetMessagingTimeout` on the
application element covers every message sent to it; 0.2s caps the whole walk at a fraction
of a second per window.

Not yet observed on screen: whether raising before activating is visibly one transition. The
order is deliberate — activating first shows the wrong window for a frame before the raise
corrects it — but it has not been watched happening, and if it flickers the two lines swap.

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

## Deferred: the exact tab

Both tiers below cost a TCC grant and neither reaches the thing people actually mean, so
they waited for evidence that app-level focus was not enough. That evidence arrived for the
second one, which is now built; the first is still waiting, and is what an exact *tab* would
need.

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

**VS Code, by `AXRaise`.** No longer deferred — built on 2026-09-12 and written up under
[the window, by title](#the-window-by-title) above. The ceilings named here when it was
deferred all turned out to be real: two windows on the same folder are still
indistinguishable, and a perfect match still raises the *window* and never the Claude panel
inside it. The one thing that was wrong was the title format, which is not
`<file> — <folder>`.

`SessionHost.containerPID` — the extension-host pid, one per window — would have been an
*exact* handle where a title is a heuristic, and it is captured already. There is still no
supported way to map it to an AX window, and `~/.claude/ide/<port>.lock` does not help:
every lock on this Mac reports `"pid": 3280`, which is the application, not the extension
host. It can still *group* sessions ("these three are in the same window") without ever
resolving which window that is.

## On "v1 watches; it doesn't launch agents"

Focus activates an application that is already running, and nothing here starts a session.
The one edge: when the host has quit, the fallback goes through LaunchServices, which will
relaunch it. The terminal is not the agent.

**Updated 2026-09-13:** the scope line itself has moved — `NewSession` starts sessions now,
in a terminal, on a chosen account (see [design.md](design.md#scope-decided)). This file is
still about the other direction: getting back to a session that already exists. The two
meet at `SessionHost`, which resolves a session started this way exactly as it resolves any
other terminal session, because it is one.
