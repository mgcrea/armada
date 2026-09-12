import AppKit
import Foundation

/// The application a session is running inside.
///
/// Found by walking the agent process's ancestors up to the first one that is a real
/// application. Verified on this Mac on 2026-09-11:
///
/// ```
/// claude (90861) → Code Helper (Plugin) (90302) → Visual Studio Code (3280)
/// ```
///
/// **This names the app, never the window or the tab.** There is no supported way to
/// get from a process to the window that draws it, and the registry offers no help —
/// see `docs/focusing-sessions.md` for what was measured and what the deferred
/// exact-tab work would need.
nonisolated struct SessionHost: Sendable, Hashable {
  let pid: pid_t
  let bundleID: String?
  let bundleURL: URL?

  /// What to call this application in a sentence: "Visual Studio Code", "Terminal".
  ///
  /// **Not `localizedName`, which is wrong for the most common host here.** Measured
  /// 2026-09-11: VS Code reports `localizedName`, `CFBundleName` and
  /// `CFBundleDisplayName` all as "Code", while its bundle is
  /// `Visual Studio Code.app` — and "Visual Studio Code" is what the Dock shows and
  /// what a person calls it. So the bundle's own filename wins, with `localizedName`
  /// behind it for anything that somehow has no bundle URL. For Terminal, Ghostty
  /// and the rest the two agree and it makes no difference.
  let name: String

  /// The last ancestor *below* the application — the VS Code extension host, or
  /// `login` for a Terminal tab.
  ///
  /// Nothing uses it yet. It is captured because it falls out of the walk for free
  /// and it is the only exact handle that tells two sessions in the same application
  /// apart: sessions sharing a `containerPID` are in the same window. Resolving that
  /// pid *to* a window is the part there is no API for.
  let containerPID: pid_t?
}

/// Which application owns a session, answered once and remembered.
///
/// **Never call this from a row body.** The ancestry walk is free; the
/// `NSRunningApplication` lookup beside it is an IPC round-trip to LaunchServices,
/// and nineteen rows resolving three ancestors apiece on every redraw would be
/// something like fifty-seven round-trips per frame. Call it on a selection change,
/// when a menu is built, or when a summary block appears — the same rule, and for
/// the same reason, as `VendorIcon`.
@MainActor
enum SessionHostLookup {
  /// Agent pid → host, **with misses kept**.
  ///
  /// A miss is permanent for the session that has one: a `claude -p` in CI, a
  /// session over ssh, one inside tmux will never acquire a host, and re-walking on
  /// every redraw to rediscover that buys nothing. The entry carries the agent's
  /// start time so a recycled pid invalidates itself on the next read.
  private static var cache: [pid_t: Entry] = [:]

  private struct Entry {
    let host: SessionHost?
    let agentStart: Date?
  }

  static func host(for registry: SessionRegistry) -> SessionHost? {
    let pid = registry.pid
    let start = ProcessAncestry.startTime(of: pid)
    // One syscall, and it covers both a session that has ended and a pid that has
    // been handed to something else since. Revalidating here is what lets this cache
    // live on its own rather than needing `SessionWatcher` to invalidate it.
    if let hit = cache[pid], hit.agentStart == start { return hit.host }
    let host = resolve(registry, agentStart: start)
    cache[pid] = Entry(host: host, agentStart: start)
    return host
  }

  /// Drop what a quit application left behind, so a stale name never reaches a label.
  ///
  /// `host(for:)` already copes with a host that has gone — the activation falls
  /// through to LaunchServices. This is only so the button stops offering to focus
  /// something that is no longer there.
  static func observeHostTermination() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { note in
      guard
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      else { return }
      MainActor.assumeIsolated {
        cache = cache.filter { $0.value.host?.pid != app.processIdentifier }
      }
    }
  }

  private static func resolve(_ registry: SessionRegistry, agentStart: Date?) -> SessionHost? {
    // The pid-reuse guard. Without it a registry file left behind by a crashed
    // session can name a pid that now belongs to a stranger, and Focus would raise
    // an application that has nothing to do with Claude Code.
    if let claimed = registry.startedAtDate {
      guard let actual = agentStart, abs(actual.timeIntervalSince(claimed)) < 5 else {
        return nil
      }
    }

    let chain = ProcessAncestry.ancestors(of: registry.pid)
    var container: pid_t?
    for ancestor in chain {
      // `NSRunningApplication(processIdentifier:)` returns something for far more
      // than applications — LaunchServices registers anything that touches the
      // WindowServer — so the policy check is mandatory rather than tidy. A
      // `.prohibited` helper such as `Code Helper (Plugin)` is walked *past*, not
      // treated as the answer and not treated as a miss.
      //
      // The cost is that a host running as `.accessory` would be skipped and the
      // walk would carry on to launchd. No shipping terminal does that.
      if let app = NSRunningApplication(processIdentifier: ancestor),
        app.activationPolicy == .regular
      {
        return SessionHost(
          pid: ancestor,
          bundleID: app.bundleIdentifier,
          bundleURL: app.bundleURL,
          name: displayName(of: app),
          containerPID: container
        )
      }
      container = ancestor
    }
    return enclosingBundle(in: chain)
  }

  /// See `SessionHost.name` for why the bundle filename beats `localizedName`.
  private static func displayName(of app: NSRunningApplication) -> String {
    app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.localizedName ?? "the host app"
  }

  /// The iTerm2 hole.
  ///
  /// iTerm2 with session restoration on — the default — runs every shell under a
  /// daemonized `iTermServer-3.5.x` that calls `setsid` and is reparented to launchd,
  /// so the ancestry walk reaches pid 1 without ever passing through iTerm. But that
  /// server lives *inside the bundle*, at
  /// `/Applications/iTerm.app/Contents/MacOS/iTermServer-3.5.x`, so the executable
  /// path names the application that the process tree does not.
  ///
  /// **This does not rescue tmux or screen.** Their server is a binary in no bundle,
  /// and the shell beneath it has no relationship to any application at all. A
  /// session started inside tmux honestly has no host, and the UI says so rather
  /// than guessing at whichever terminal happens to be frontmost.
  private static func enclosingBundle(in chain: [pid_t]) -> SessionHost? {
    for ancestor in chain {
      guard let path = ProcessAncestry.executablePath(of: ancestor) else { continue }
      var url = URL(filePath: path)
      while url.pathComponents.count > 1 {
        url = url.deletingLastPathComponent()
        guard url.pathExtension == "app" else { continue }
        guard
          let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url })
        else { break }
        return SessionHost(
          pid: app.processIdentifier,
          bundleID: app.bundleIdentifier,
          bundleURL: app.bundleURL,
          name: displayName(of: app),
          containerPID: ancestor
        )
      }
    }
    return nil
  }
}
