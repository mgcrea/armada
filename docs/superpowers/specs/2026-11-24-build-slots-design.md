# Build slots

Approved in conversation on 2026-11-24, from a brief written after measuring the Mac that day.

## Why

Olivier runs many agent sessions at once on one Mac (18 cores, 64 GB). Several work in the same
repo at once, each in its own git worktree with its own `.build`, so each compiles from scratch
at full parallelism. Measured on 2026-11-24 with four agents in the Maquette repo:

- The load stayed at 24–29 for at least 15 minutes.
- A 90-second sample of compiler, test and link processes found builds colliding, mostly across
  repos: a Maquette worktree and a Valise worktree built together, peaking at about 11.6 cores
  and 7.4 GB.
- Memory was the worse problem: swap at 31.1 of 31.7 GB, with five booted iOS simulators holding
  12.5 GB. macOS sizes swap dynamically, so swap totals are no stable threshold.

So the fix covers every repo on the machine, and accounts for memory as well as CPU.

## Goals

- At most N builds or test runs at once, machine-wide (N = 2 by default), across every repo,
  every agent vendor and every terminal.
- No build starts under memory pressure unless it has waited long enough.
- A queued command says on stderr that it is queued and behind whom, so an agent whose Bash tool
  times out at two minutes learns it was waiting, not hung.
- Armada shows who holds and who waits, on the session rows and through MCP.

## Non-goals

- First-come order among waiters. Waiters poll and the next to look wins. Strict order would
  need Armada to arbitrate over a socket, and the queue must work with Armada down.
- Queueing Xcode's own builds, `xcrun swift …`, a direct `swift-build`, or the Xcode MCP's
  `BuildProject`. None goes through PATH. Documented, not fixed.
- Throttling a build once it runs. The memory rule is checked only before a slot is taken.

## Anti-goals

- **Breaking a build.** A shim that cannot find Armada, cannot read its settings, or cannot
  open its slot directory runs the real tool, unqueued. Queueing is best effort; the build is not.
- **Any Makefile change, in any repo.** Makefiles must stay portable to Macs without Armada.
- **Depending on Armada running.** Builds queue while Armada is down, crashed or mid-update.
- **An acquire or release step anyone can forget.** No MCP acquire or release tools.
- **Self-deadlock.** A build nested inside a held slot (a script phase calling `swift build`,
  a Makefile recursing) never waits on its own parent.

## Approaches considered

1. **Acquire and release through MCP.** Rejected: agents forget to release, compaction or an
   interruption loses the release step, and `make test-all`, subagents and hand-typed builds
   never queue.
2. **Armada arbitrates over a socket.** Gives strict order. Rejected: the queue would stop when
   Armada is down or updating.
3. **Kernel file locks taken by a PATH shim in the build's own process.** Chosen. The kernel
   drops a lock when its process dies, so a lock never goes stale and no daemon is needed.

## Design

The shim script under **Shims** is the one that ships, which tightened the shape approved here;
that section says what changed and why. Smaller departures (the monitor's 30 s idle poll, the
row badge as caption text rather than a capsule) and the build's limits are in
`docs/implementation.md`.

### Package and binary

A new local package, `apps/apple/Packages/BuildSlot`:

- **`BuildSlotCore`** (library): lock primitives, the slot-file format, which invocations queue,
  settings, the holder label, the memory-pressure read, and the shim installer. Foundation and
  Darwin only. Tested with `swift test`, added to `apps/apple`'s `make test`.
- **`buildslot`** (executable): a thin `main` over the core.

The app links `BuildSlotCore` to read slots, so the reader and the writer share one format.

The helper ships at `Armada.app/Contents/Helpers/buildslot`. How it gets there is the builder's
call; the expected route is a command-line-tool target in `Armada.xcodeproj` that compiles the
package's `main.swift` against `BuildSlotCore`, copied by a Copy Files phase into
`Contents/Helpers`. The root Makefile's `sign` target signs it (`--options runtime --timestamp`,
no entitlements) before the app wrapper, inside out as for everything else, and
`codesign --verify --deep --strict` must still pass. It must not trip `make audit` (the network
audit): it opens no socket.

The `buildslot` binary dispatches on how it is invoked:

- `buildslot --as swift …` / `buildslot --as xcodebuild …`: the shim path (below).
- `buildslot run -- <cmd> …`: queue an arbitrary command; useful for testing and by hand.
- `buildslot status [--json]`: holders, waiters, settings, pressure.
- `buildslot install [--bin-dir DIR]` / `buildslot uninstall`: write or remove the shims, pointing
  at this binary's own resolved path.

### Where the files live

Two fixed paths, the same for every build of Armada. Neither is under `AppInfo.supportDirectory`,
which is keyed by bundle id, so a Debug and a Release build would each get their own queue.

- **Settings**: `~/Library/Application Support/Armada/build-slots/settings.json`. Written by the
  app, only read by the tool, on every poll.
- **Locks**: `/private/tmp/armada-build-slots-<uid>/`, holding `slots/N.lock` (one per slot) and
  `waiting/<pid>.lock` (one per waiting shim). Created on demand by whoever needs them first,
  mode 0700.

The locks live under `/tmp` because the shim runs inside the agents' sandboxes. Codex runs in
`workspace-write` on this Mac (`~/.codex/config.toml`), which refuses writes outside the workspace
and the temp folders, and `fcntl` needs a writable descriptor for a write lock. Under
Application Support every Codex build would fall back to unqueued. `/tmp` is writable under
Codex's and Claude Code's sandboxes, and a reboot clears it, which is when every lock is gone
anyway. macOS's daily `/tmp` sweep removes files untouched for three days; a slot file is
re-created on demand, so that only costs a stale record. Settings stay in Application Support:
sandboxes allow reads there.

When the lock directory cannot be created or opened for writing, the shim says so once and runs
unqueued (anti-goal: never break a build).

### The lock

POSIX record locks: `fcntl(F_SETLK)` with a whole-file write lock on `slots/N.lock`, not `flock`.
Both are dropped by the kernel when the process dies. `fcntl` also gives:

- **No inheritance.** Child processes never inherit a POSIX record lock, so a stray
  `swift-frontend` or test host cannot keep a slot.
- **`F_GETLK`.** Any process can ask who holds the lock, and get the holder's pid, without taking
  it. Armada, waiters and `buildslot status` observe without disturbing the queue.

Two POSIX traps, both contained by rule:

- Closing *any* descriptor on a file drops the process's lock on it. So a shim never opens a file
  it holds a lock on a second time, including to read it back: it reads others' records through
  fresh descriptors and its own from memory.
- `F_GETLK` never reports the caller's own locks. So a shim skips its own slot and its own
  waiting file when scanning, and knows its own state from memory.

Descriptors are opened `O_CLOEXEC`.

**Holder record.** Once it holds slot N, the shim truncates and writes into `slots/N.lock`:

```json
{"version":1,"pid":17804,"processStart":"2026-11-24T10:02:11Z","startedAt":"2026-11-24T10:04:40Z",
 "cwd":"/Users/olivier/Projects/apps/valise/.claude/worktrees/land-gate-f764fa9",
 "label":"valise/land-gate-f764fa9","tool":"swift","argv":["swift","test"]}
```

`argv` is truncated to a sensible length (builder's call, e.g. 20 arguments, 2 KB). A reader
trusts the record only when `F_GETLK` reports a holder and its pid equals the record's `pid`;
otherwise the content is leftover from a dead holder and ignored. A slot whose lock is free is
free, whatever the file says.

**Acquiring.** The shim tries each slot `0..<count` with `F_SETLK` (non-blocking). If all are
busy, or the memory rule says wait, it registers as a waiter and polls every 0.5 s, re-reading
`settings.json` each time so a changed count or rule applies to waiters. Lowering the count
leaves higher slots held until their holders exit; new acquirers only try `0..<count`.

**Waiters.** A waiting shim creates `waiting/.<pid>.tmp`, takes an `F_SETLK` write lock on it,
writes the same record shape (with `waitingSince` in place of `startedAt`), and only then renames
it to `waiting/<pid>.lock`. A reader therefore never sees a waiting file that is not yet locked.
The shim deletes its file once it holds a slot, or when it gives up. Any other reader that finds
a `<pid>.lock` whose lock is free deletes it (the waiter died); dot-files older than a minute are
swept the same way.

### Child process, not exec

The shim keeps the lock and runs the real tool as a child (`posix_spawn`), then waits for it.
Exec would keep the slot in whatever the tool becomes, which for some invocations is a
long-lived process.

- **Signals.** The child stays in the shim's process group, so a terminal's ^C and a kill aimed at
  the group reach it directly. While the child runs, the shim **ignores SIGINT and SIGQUIT** and
  forwards nothing for them: forwarding would deliver ^C twice, and a second SIGINT makes
  SwiftPM and xcodebuild abort hard instead of cancelling. (There is no reliable way to tell a
  tty's ^C from a `kill` aimed at the shim alone: measured on this Mac, a pty's ^C arrives with
  `si_pid` set to the writer's pid.) The shim **forwards SIGTERM and SIGHUP**; a group-wide
  SIGTERM then reaches the child twice, which only terminates it. While still waiting (no child
  yet), every signal has its default effect and the shim simply dies, freeing its waiting file.
- **Exit status.** The shim exits with the child's code. When the child died from SIGINT,
  SIGTERM, SIGHUP, SIGKILL or SIGPIPE, the shim resets that signal to default and raises it on
  itself, so callers see the same `WIFSIGNALED`. For crash signals (SIGABRT, SIGSEGV, SIGBUS,
  SIGILL, SIGTRAP, SIGFPE, SIGQUIT) it exits `128 + signal` instead: re-raising those would make
  macOS write a crash report blaming `buildslot` every time a test crashes.
- **`kill -9` on the shim** frees the slot at once and leaves its child running unqueued until
  it ends. Documented. Agent tools that time out kill the process group, which takes the child
  with it.

### What queues

**`swift`**: `build` and `test` (first non-option argument), unless any argument is `--help`,
`-h`, `--version` or `--show-bin-path`. Everything else passes through: `run`, `package`,
`format`, `repl`, no subcommand, `--version`.

`swift run` does not queue: it execs the product it built in the same process, so a server or a
long-running CLI would hold a slot for its whole life.

**`xcodebuild`**:

- Queues: actions `build`, `build-for-testing`, `test`, `archive`, `analyze`, `install`,
  `docbuild`, and an invocation naming no action (xcodebuild's default is `build`).
- Passes through: `test-without-building`, `clean`, `installsrc`, and any invocation carrying
  one of `-showBuildSettings`, `-list`, `-version`, `-exportArchive`,
  `-resolvePackageDependencies`, `-showsdks`, `-showdestinations`, `-showTestPlans`,
  `-create-xcframework`, `-checkFirstLaunchStatus`, `-runFirstLaunch`, `-help`, `-usage`.
- Passes through any invocation with an argument containing `WebDriverAgent` (the iOS simulator
  MCP keeps a WebDriverAgent run alive for days).

Telling an action from an option's value: xcodebuild options that take a value (`-scheme X`,
`-destination X`, `-project X`, …) are skipped with their value; bare words left over are
actions or `KEY=VALUE` build settings. The builder pins the option table with tests over real
invocations taken from the fleet's Makefiles.

### Nesting and the escape hatch

A nested build must never wait on its own parent. Three rules, any one of which lets a shim
through:

- **Ancestry.** The holder sets `ARMADA_BUILDSLOT_HOLDER=<its pid>` in the child's environment. A
  nested shim passes straight through if that pid is one of its own ancestors (walking
  `kinfo_proc` parents), so a variable leaked into an unrelated process cannot skip the queue.
- **Same tree.** A shim whose cwd is a held slot's cwd or below it, in the same git working tree,
  passes straight through. "Same working tree" means both cwds resolve to the same nearest
  ancestor holding a `.git` (file or directory); a worktree under `<repo>/.claude/worktrees/`
  has its own `.git` file, so it never counts as inside its main checkout. Paths are compared
  after resolving symlinks. This
  catches nesting the ancestry walk cannot see: `xcodebuild test` on macOS starts its test host
  through testmanagerd and launchd, so a test that runs `swift build` is not a descendant of its
  holder; and a sandbox may deny reading other processes' info. It costs nothing in CPU: two
  builds in one tree share its `.build` or derived data, and SwiftPM and xcodebuild already
  serialise on those themselves.
- **Cap.** No shim waits for a slot longer than **30 minutes** (`slotWaitCapSeconds`, default
  1800). Then it runs anyway and says so. This is the backstop for nesting no rule recognises (a
  test building a fixture in a temp folder with Slots at 1), and for a holder that hangs.

- `ARMADA_BUILDSLOT=off` makes the shim pass straight through.
- Maquette's `make test-all` runs `swift test` and `xcodebuild` steps one after another, so each
  step takes and returns a slot; it cannot deadlock. Other worktrees may slip in between steps,
  which is accepted.

### Memory rule

The tool reads `kern.memorystatus_vm_pressure_level` with `sysctlbyname`: 1 normal, 2 warning,
4 critical. Settings choose: `off`, `critical` (wait while critical), or `warning` (wait while
warning or critical). **Default `warning`.**

The rule applies only before taking a slot, only while a slot is free (with every slot busy,
the shim is waiting anyway), and **only while at least one other slot is held**. With nothing
building, holding a build back cannot relieve the pressure, so the first build always starts. After **10 minutes** of waiting on memory alone (the cap,
`memoryWaitCapSeconds`, default 600), the shim takes the slot anyway and says so. Chronic
pressure must not block builds forever. A sysctl that fails reads as normal.

### What the shim says

On stderr, each line prefixed `buildslot: `. Printed when it starts waiting, whenever the set of
holders changes, and every 60 s while waiting:

```
buildslot: waiting for a slot (2 of 2 busy), held by valise/land-gate-f764fa9 (pid 17804, swift test, 2 min) and maquette/components (pid 11208, xcodebuild test, 40 s). Queued, not hung.
buildslot: a slot is free; waiting for memory pressure (warning) to ease, runs anyway in 8 min.
buildslot: memory pressure still warning after 10 min; running anyway.
buildslot: no slot after 30 min; running anyway.
buildslot: got slot 1 after 3 min 12 s.
```

A command that gets a slot at once prints nothing. Problems that make the shim fall back to an
unqueued run print one line (`buildslot: <reason>; running unqueued.`) and continue.

**Label.** If the cwd is under `<repo>/.claude/worktrees/<name>`, the label is `<repo
basename>/<name>`. Otherwise it is the basename of the nearest ancestor holding `.git` (file or
directory), and failing that the cwd's own basename.

### Shims

Two POSIX `sh` scripts, `swift` and `xcodebuild`, in `~/.local/bin`, **not symlinks**. A shell
that hashed a symlink's path fails the command once Armada is deleted or moved; a script can
check first. The script that ships (`ShimInstaller.script`), for an app in `/Applications`:

```sh
#!/bin/sh
# armada-buildslot-shim v1 — written by Armada; Armada repairs or removes this file.
b='/Applications/Armada.app/Contents/Helpers/buildslot'
[ -f "$b" ] && [ -x "$b" ] && exec "$b" --as swift "$@"
# Armada is gone: run the real swift, unqueued.
self_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
set -f; IFS=:
for d in $PATH; do
  [ -n "$d" ] && [ -f "$d/swift" ] && [ -x "$d/swift" ] || continue
  [ "$(CDPATH= cd -- "$d" 2>/dev/null && pwd -P)" = "$self_dir" ] && continue
  /usr/bin/head -c 256 "$d/swift" 2>/dev/null | /usr/bin/grep -qF 'armada-buildslot-shim v1' && continue
  exec "$d/swift" "$@"
done
exec /usr/bin/swift "$@"
```

It tightens the shape first approved here, which was a one-line loop that skipped only its own
folder. The fallback now also skips any other shim (by its marker), since two shims whose helper
is gone would otherwise exec each other in a loop; tests `-f`, on the helper and in the walk, so
a folder at either path is not taken for the program; clears `CDPATH` and ends options with `--`; turns off globbing (`set -f`)
so a `*` in a `PATH` entry stays literal; and names `dirname`, `head` and `grep` by full path,
as the `PATH` it was given may lack `/usr/bin`. The installer compares the whole file, so any
change to the script reaches installed shims on the next install.

The Swift binary finds the real tool the same way: walk `PATH`, skip any directory that resolves
to the shim's directory, skip any candidate that is a shim (marker line) or resolves to the
`buildslot` binary, and fall back to `/usr/bin/swift` or `/usr/bin/xcodebuild` (Apple's stubs,
which honour `DEVELOPER_DIR` and `xcode-select`).

**Installer rules** (`BuildSlotCore`, shared by the app and `buildslot install`):

- Writes only into `~/.local/bin`, creating it if missing.
- Never overwrites a file named `swift` or `xcodebuild` there that lacks the marker line; reports
  it instead.
- Rewrites a shim whose embedded helper path differs from the installing binary's.
- Uninstall removes only files carrying the marker.

**Who installs.** Only the Release bundle (`io.mgcrea.armada`), at launch while the switch is on,
and on the switch. It re-points the shims if the app moved. Debug builds never install: on a
branch, run the Debug bundle's `Contents/Helpers/buildslot install` to point the shims at it;
the next Release launch takes them back.

**PATH check.** Settings shows a warning when the login shell's `PATH` (from `LoginShell`) does
not put `~/.local/bin` before the directory holding the real `swift` (normally `/usr/bin`).

### Settings ▸ Build Slots

A new pane on the shared settings scaffold:

- **Queue builds** switch: installs or removes the shims. **Off by default**: Armada ships to
  customers, and a shadow `swift` on their PATH is their choice.
- **Slots**: 1–8, default 2.
- **Memory**: Off, Wait while critical, Wait while under pressure (default).
- The PATH warning, and any refused install (a foreign `swift` in `~/.local/bin`).
- A live list of holders and waiters (label, command, age, session when matched).
- One line on the limits: Xcode's own builds and `xcrun swift` don't queue.

The app writes `settings.json` (`{"version":1,"slots":2,"memoryRule":"warning",
"memoryWaitCapSeconds":600,"slotWaitCapSeconds":1800}`; the two caps have no control in the
pane) through `StoreFile`'s conventions. A missing or unreadable file
means the defaults, for the tool; the tool never writes it. Turning the switch off removes the
shims and leaves `settings.json`.

Not behind the licence: the tool never checks one, and the switch works in the trial.

### Armada shows the queue

**`BuildSlotMonitor`** (`@Observable`, main actor, reads off the main actor): polls every 2 s
while the switch is on, or while any slot file or waiter exists. A `kill -9` produces no file
event, so polling, not FSEvents. Each poll is a few `open` + `F_GETLK` + small reads.

**Matching to a session.** For each holder and waiter, walk `ProcessAncestry.ancestors(of:)`:

- **Claude Code, Grok Build:** the first ancestor that is a live session's pid names the session.
- **Codex:** Codex has no session pid. When an ancestor's executable is `codex`, match by cwd
  among live Codex sessions: the session whose cwd is the holder's cwd or an ancestor of it,
  deepest first. Unique match → that session; otherwise "a Codex session".
- **No match:** shown as `Terminal · <label>`.

**Rows.** A session with a match gets a capsule in its row and a line in its detail pane:

- holding: "building · 2 min" (detail: the command and slot);
- waiting: "waiting for a slot · 40 s" (or "waiting on memory").

**Popover.** One line when the feature is on: "Build slots 2/2 · 1 waiting".

### MCP

- **`armada_get_build_slots`** (read-only, always listed): `enabled`, `settings`,
  `memoryPressure` (`normal`/`warning`/`critical`), `holders` and `waiters`, each with `slot`
  (holders), `pid`, `label`, `cwd`, `tool`, `argv`, `since`, and `session` (`id`, `vendor`,
  `title`) when matched. Description tells an agent to check it before a long suite and to do
  other work first when every slot is busy.
- Sessions in `armada_get_fleet` and `armada_get_session` gain an optional `buildSlot`
  (`{state: "holding"|"waiting", since, tool}`).
- Same shape as the other tools: snapshot types and a source protocol in `ArmadaMCP`, tested
  against a fake; a bridge in the app.
- No acquire or release tools.

## Documented limits

- `xcrun swift …`, a direct `swift-build`/`swift-test`, Xcode's own builds and the Xcode MCP's
  `BuildProject` bypass PATH and do not queue. The fleet's Makefiles call bare `swift test` and
  `xcodebuild`, so they do.
- `kill -9` on a shim frees its slot and leaves its build running unqueued.
- `swift run` does not queue.
- Waiters are served in no particular order.
- A process that does not inherit the login shell's PATH (a GUI app launching `swift`) does not
  queue.
- A shim that cannot write the lock directory (a stricter sandbox) runs unqueued, and says so.
- Two agents in one tree, or a parent and child in one tree, share a slot (the same-tree rule).
- ^C or SIGQUIT sent with `kill` to the shim's pid alone, while its build runs, is ignored; send it
  to the process group, or send SIGTERM.

These go in `docs/implementation.md` (a section, plus table rows for the new types) and in the
Settings pane's footnote.

## End-to-end check

1. Three `swift test` runs from three worktrees of one repo: two run, one waits and prints the
   waiting line naming both holders.
2. `kill -9` on a holder's shim: the waiter gets the slot within a second.
3. Armada's session rows and `armada_get_build_slots` show the right holders and waiter.
4. `make test-all` in `~/Projects/apps/maquette/apps/apple` runs through without deadlock.
5. `swift build --show-bin-path` and `xcodebuild -version` pass straight through, without
   waiting even when every slot is busy.
6. A `swift test` run from inside a Codex session (sandbox `workspace-write`) takes a slot rather
   than falling back to unqueued.
7. With the helper path made unreachable (rename the bundle), the shim runs the real `swift`,
   unqueued, and the build succeeds.

## Left to the builder

- The Xcode wiring for the helper (target vs. other route), as long as it lands signed in
  `Contents/Helpers`.
- The xcodebuild option table, pinned by tests.
- argv truncation limits; poll intervals within reason.
- Row capsule styling, following the existing row badges.
