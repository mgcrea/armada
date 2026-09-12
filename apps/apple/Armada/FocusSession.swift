import AppKit

/// Bring the application a session is running in to the front.
///
/// Kept apart from `SessionHostLookup` because this is the *action*, and because the
/// deferred exact-window work in `docs/focusing-sessions.md` grows here rather than
/// in the lookup.
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
  @discardableResult
  static func focus(_ host: SessionHost) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: host.pid) else { return reopen(host) }
    NSApp.yieldActivation(to: app)
    if app.activate(from: .current, options: []) { return true }
    return reopen(host)
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
