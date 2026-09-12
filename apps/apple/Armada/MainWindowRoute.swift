import SwiftUI

/// Where the menu bar panel is sending the main window.
///
/// The panel's rows used to be a way *out* of Armada: a click raised the terminal
/// the session was running in. They are a way *into* it now — the same click opens
/// the window on the pane that owns the row, with that row selected. Everything the
/// panel can only hint at in 320pt (the transcript context, the folder, the model,
/// the full session list) is one click away rather than two, and the panel stops
/// being a dead end for anything it cannot fit. Focusing the host is still there,
/// on the right-click: "take me to my terminal" is a different intent from "show me
/// the details", and it is the rarer of the two.
///
/// **Two halves, because the window's two selections live in different places.** The
/// sidebar's is in defaults, so it is written straight there — which is what makes
/// this work whether the window is already up (`@AppStorage` observes the key) or is
/// about to be built for the first time (it reads the key as it is created). The
/// pane's session selection is `@State` inside a view that may not exist yet, so it
/// is parked here for the pane to take when it appears.
@MainActor
@Observable
final class MainWindowRoute {
  static let shared = MainWindowRoute()

  /// Bumped on every request, and the thing the panes actually watch. Asking twice
  /// for the same session has to be two events: a second click on the same row
  /// should re-select it after the reader has clicked elsewhere in the window.
  private(set) var token = 0

  private var target: SidebarItem?
  private var session: String?

  private init() {}

  /// Show `item` in the main window, with `session` selected in it.
  ///
  /// Write first, then open — the same order `AppDelegate.showSettings(_:)` needs,
  /// and for the same reason: it is what makes a deep link work on a window that is
  /// already up.
  func open(_ item: SidebarItem, session: String? = nil) {
    UserDefaults.standard.set(item.stored, forKey: SidebarItem.defaultsKey)
    target = item
    self.session = session
    token &+= 1
    AppDelegate.shared?.showMain()
  }

  /// The session this route wants selected in `item`, if nobody has taken it yet.
  ///
  /// One-shot. A pane is rebuilt every time the sidebar moves to it, and a click
  /// from an hour ago should not re-select its row each time someone comes back.
  func takeSession(in item: SidebarItem) -> String? {
    guard target == item, let session else { return nil }
    self.session = nil
    return session
  }
}
