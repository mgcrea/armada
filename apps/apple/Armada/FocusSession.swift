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
  /// `cwd` rather than anything on `SessionHost`, because the folder is this
  /// action's input and not part of the host's identity; `SessionHost` names an
  /// application and carries no path on purpose.
  @discardableResult
  static func focus(_ host: SessionHost, cwd: String) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: host.pid) else { return reopen(host) }
    let raised = HostWindow.raise(inApplication: host.pid, cwd: cwd)
    NSApp.yieldActivation(to: app)
    if app.activate(from: .current, options: []) { return true }
    // A raise that landed is a visible result even when the activation was
    // declined, so it is not worth going through LaunchServices after one.
    return raised || reopen(host)
  }

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
