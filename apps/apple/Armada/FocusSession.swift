import AppKit

/// Bring the application a session is running in to the front.
///
/// Kept apart from `SessionHostLookup` because this is the *action*: the lookup
/// answers which application owns a session, and this decides what to do about it.
/// The window half lives in `HostWindow`, for the same reason and behind the same
/// line. See `docs/focusing-sessions.md`.
@MainActor
enum FocusSession {
  /// **`NSRunningApplication` has no no-argument `activate()`.** That one belongs to
  /// `NSApplication`, and reaching for it here is the obvious mistake. The one that
  /// exists takes a *from*, and the reason it does is exactly what makes a plain
  /// `activateWithOptions([])` unreliable: since macOS 14, activation is cooperative
  /// and the system declines requests from an application that is not itself
  /// frontmost. `NSRunningApplication.h` says so outright — "The other application
  /// should call `-yieldActivationToApplication:` or equivalent prior to this
  /// request being sent."
  ///
  /// Armada is normally frontmost when this runs: the popover is open, or the main
  /// window is key. That is the case that would have worked anyway. The yield is
  /// what keeps it working when it is not.
  ///
  /// **The window first, then the application.** Activating raises whichever window
  /// of the host was frontmost last, which for a Mac with eleven VS Code windows is
  /// almost never the session's own — so `HostWindow` gets the first word, and the
  /// activation that follows carries the window it just raised. The other order
  /// shows the wrong window for a frame before correcting itself.
  ///
  /// **Then the tab, when there is one to ask for.** See `reveal`.
  ///
  /// `cwd` rather than anything on `SessionHost`, because the folder is this
  /// action's input and not part of the host's identity; `SessionHost` names an
  /// application and carries no path on purpose.
  @discardableResult
  static func focus(_ host: SessionHost, cwd: String, session: Session? = nil) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: host.pid) else { return reopen(host) }
    let window = HostWindow.raise(inApplication: host.pid, cwd: cwd)
    if let window, let tab = session.flatMap({ ExtensionTab($0, host: host) }),
      HostWindow.hasEditorTab(in: window, titledAnyOf: tab.labels)
    {
      reveal(tab, in: host, window: window)
    }
    NSApp.yieldActivation(to: app)
    if app.activate(from: .current, options: []) { return true }
    // A raise that landed is a visible result even when the activation was
    // declined, so it is not worth going through LaunchServices after one.
    return window != nil || reopen(host)
  }

  /// What `focus` would reach, found without raising or sending anything.
  ///
  /// For a marker drawn before anyone clicks, so it has to agree with `focus`: the same
  /// window match and the same tab check, stopping short of the two steps that act.
  /// `nonisolated` so the caller can keep the Accessibility IPC off the main thread — a
  /// wedged host answers each message only when the timeout runs out. `labels` is
  /// `ExtensionTab.labels`, nil when there is no extension tab to ask for.
  nonisolated static func reach(
    inApplication pid: pid_t, cwd: String, labels: [String]?
  ) -> FocusReach {
    guard let window = HostWindow.matchingWindow(inApplication: pid, cwd: cwd) else {
      return .application
    }
    guard let labels, HostWindow.hasEditorTab(in: window, titledAnyOf: labels) else {
      return .window
    }
    return .tab
  }

  /// Hosts and reach for the sessions a list is about to draw a Focus glyph for.
  ///
  /// Hosts on the main actor, where `SessionHostLookup` lives and caches; the reach off
  /// it, for the reason `reach` gives. **Identical probes are asked once**: sessions in
  /// one window share a folder and their labels, and the tab walk is the expensive part,
  /// so twenty rows across six windows cost six walks rather than twenty.
  static func resolve(
    _ sessions: [Session]
  ) async -> (hosts: [pid_t: SessionHost?], reaches: [String: FocusReach]) {
    var hosts: [pid_t: SessionHost?] = [:]
    var probes: [(id: String, probe: FocusProbe)] = []
    for session in sessions {
      let host = SessionHostLookup.host(for: session.registry)
      hosts[session.registry.pid] = host
      guard let host else { continue }
      let labels = ExtensionTab(session, host: host)?.labels.sorted()
      let probe = FocusProbe(pid: host.pid, cwd: session.registry.cwd, labels: labels)
      probes.append((session.id, probe))
    }
    let reaches = await Task.detached {
      var memo: [FocusProbe: FocusReach] = [:]
      var reaches: [String: FocusReach] = [:]
      for (id, probe) in probes {
        let reach =
          memo[probe]
          ?? FocusSession.reach(inApplication: probe.pid, cwd: probe.cwd, labels: probe.labels)
        memo[probe] = reach
        reaches[id] = reach
      }
      return reaches
    }.value
    return (hosts, reaches)
  }

  /// Ask the Claude Code extension to show `tab`, once the window holding it is the one
  /// VS Code will give the request to.
  ///
  /// **The extension's own URI, because nothing else switches the tab.** Accessibility
  /// can read VS Code's tabs and cannot select one (see `HostWindow.hasEditorTab`).
  /// `vscode://anthropic.claude-code/open?session=<id>` runs the extension's
  /// `primaryEditor.open`, which reveals the panel bound to that session id — exactly,
  /// where a tab's label is only a heuristic.
  ///
  /// **Gated three ways, because the wrong window does real harm.** A window with no
  /// panel for the session does not refuse: it opens a new one on the same id, which
  /// resumes a session that is still running somewhere else — two writers on one
  /// transcript. VS Code routes an incoming URI to its focused window, so the URI goes
  /// only when the session is the extension's own (`ExtensionTab`), the window
  /// `HostWindow` matched has a tab labelled for this session or one sharing its
  /// extension host, and that window has become VS Code's focused one. Any gate that
  /// fails leaves the window raised and the tab where it was, which is what Focus did
  /// before.
  ///
  /// Polled rather than sent straight after `activate`, because activation is a request
  /// the system answers asynchronously: sent at once, the URI can reach the window that
  /// was focused a moment ago.
  private static func reveal(_ tab: ExtensionTab, in host: SessionHost, window: AXUIElement) {
    guard let bundleURL = host.bundleURL else { return }
    let url = tab.url
    Task {
      for _ in 0..<revealAttempts {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid,
          HostWindow.isFocused(window, inApplication: host.pid)
        {
          NSWorkspace.shared.open(
            [url], withApplicationAt: bundleURL, configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil)
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  /// A second, in 50ms steps: an activation that has not landed by then was declined.
  private static let revealAttempts = 20

  /// LaunchServices, the way `open -a` does it.
  ///
  /// The fallback for two different failures with the same right answer: an
  /// activation the system declined, and a host that has quit since the lookup ran.
  /// It raises a running application and launches a quit one.
  ///
  /// Launching a quit host is the one place this app starts something rather than
  /// watching it. It stays within `docs/design.md`'s "v1 watches; it doesn't launch
  /// agents" — the terminal is not the agent, and nothing here starts a session.
  @discardableResult
  private static func reopen(_ host: SessionHost) -> Bool {
    guard let url = host.bundleURL else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    return true
  }
}

/// How far `FocusSession.focus` gets for one session.
nonisolated enum FocusReach: Sendable {
  /// The session's own tab, through the Claude Code extension.
  case tab
  /// The window with the session's folder open, showing whatever tab it was showing.
  case window
  /// The application alone: no Accessibility grant, or no window title names the folder.
  case application

  /// `arrow.up.forward.app` for the session's own tab, `macwindow` for anything short of
  /// it. Two looks rather than three: the question a glyph answers is "will this land on
  /// my session", and the tooltip says which of the two shortfalls it is.
  var systemImage: String { self == .tab ? "arrow.up.forward.app" : "macwindow" }

  func help(hostName: String) -> String {
    switch self {
    case .tab: "Focus this session's tab in \(hostName)"
    case .window: "Focus in \(hostName): the window, not this session's tab"
    case .application: "Focus in \(hostName): the app, not this session's window"
    }
  }
}

/// A row's Focus glyph: how far it reaches, and the application it reaches into.
nonisolated struct FocusMarker: Equatable, Sendable {
  let reach: FocusReach
  let hostName: String
}

/// One `FocusSession.reach` question, hashable so identical ones are asked once.
private nonisolated struct FocusProbe: Hashable, Sendable {
  let pid: pid_t
  let cwd: String
  let labels: [String]?
}

/// A session the Claude Code extension shows in an editor tab, and what it takes to ask
/// for that tab.
struct ExtensionTab {
  let sessionID: String

  /// Titles that prove a window holds this session: its own, and those of every other
  /// session its extension host runs.
  ///
  /// **The siblings are what make untitled sessions reachable.** A session's own title is
  /// often not what its tab says — a fork carries only a `custom-title`, and a session
  /// opened on `/commit` has no title and a tab labelled `/commit`. But every `claude` a
  /// VS Code window runs is a child of that window's one extension host
  /// (`SessionHost.containerPID`; 21 live sessions on 2026-09-15 fell into nine hosts,
  /// one per window), so a titled sibling's tab proves the window for all of them.
  let labels: [String]

  /// `<scheme>://anthropic.claude-code/open?session=<id>`.
  let url: URL

  /// Nil for anything the extension does not own, for a host that registers no URL
  /// scheme, and when neither the session nor any sibling has a title to look for.
  ///
  /// **The entrypoint is the safety, not a filter for tidiness.** A `claude` started in
  /// VS Code's integrated terminal has VS Code as its host too, and has no panel in any
  /// window — asking the extension for it would open one and resume the session a second
  /// time.
  ///
  /// Resolves a host for every session, so call it when something is about to happen —
  /// a click, a panel opening — and never from a row body. See `SessionHostLookup`.
  init?(_ session: Session, host: SessionHost) {
    guard session.registry.entrypoint == Self.entrypoint,
      let scheme = host.bundleURL.flatMap(Self.urlScheme(of:))
    else { return nil }
    let siblings =
      host.containerPID.map { container in
        Accounts.shared.allSessions.filter {
          $0.id != session.id && SessionHostLookup.host(for: $0.registry)?.containerPID == container
        }
      } ?? []
    labels = ([session] + siblings).compactMap(\.title)

    var components = URLComponents()
    components.scheme = scheme
    components.host = Self.extensionID
    components.path = "/open"
    components.queryItems = [URLQueryItem(name: "session", value: session.id)]
    guard !labels.isEmpty, let url = components.url else { return nil }
    self.url = url
    sessionID = session.id
  }

  /// The registry's `entrypoint` for a session the VS Code extension started.
  static let entrypoint = "claude-vscode"

  /// The same id on the VS Code Marketplace and Open VSX, so Cursor and VSCodium take
  /// the same path.
  static let extensionID = "anthropic.claude-code"

  /// The scheme the host registers — `vscode`, `vscode-insiders`, `cursor` — read from
  /// its bundle rather than listed, for the reason `HostWindow` names no bundle
  /// identifier.
  private static func urlScheme(of bundleURL: URL) -> String? {
    let types = Bundle(url: bundleURL)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
    return types?.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
  }
}
