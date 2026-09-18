import AppKit
import SwiftUI

/// A SwiftUI view in a real `NSWindow`, openable from anywhere.
///
/// Both of this app's windows are held this way rather than declared as SwiftUI
/// `Window` scenes, and the reason is the same for each: they have to be openable
/// from `AppDelegate`, which has no view hierarchy and therefore no `openWindow`
/// to read out of the environment.
///
/// SwiftUI's `Settings` scene was tried first in two sibling apps and does not
/// work here at all: it opens via `showSettingsWindow:`, routed through an app
/// menu that an `LSUIElement` app does not have.
@MainActor
final class HostedWindow {
  private let title: String
  private let autosaveName: String
  private let contentSize: NSSize?
  private let content: () -> AnyView

  /// Not released on close, so reopening restores the same window and AppKit
  /// keeps the frame it autosaved.
  private var window: NSWindow?

  /// Lives only long enough to see off SwiftUI's opening resize. See `show()`.
  private var resizeGuard: OpeningResizeGuard?

  /// Writes the frame back out, in place of the autosave that used to. See `FrameSaver`.
  private var frameSaver: FrameSaver?

  /// `contentSize` is the size the window opens at the very first time, before
  /// there is an autosaved frame to restore. Worth stating for a window built out
  /// of a `NavigationSplitView`: SwiftUI's fitting size for that is the width
  /// every footer sentence would need to avoid wrapping. `idealWidth` on the
  /// content does not reach the hosting controller; this does.
  init(
    title: String, autosaveName: String, contentSize: NSSize? = nil,
    content: @escaping () -> some View
  ) {
    self.title = title
    self.autosaveName = autosaveName
    self.contentSize = contentSize
    self.content = { AnyView(content()) }
  }

  /// The floor under which a restored frame is corrupt rather than merely small.
  /// `contentMinSize` is the real answer wherever AppKit has one, but it is zero
  /// for content that declares no minimum, and zero accepts the 1x32 frame this
  /// exists to reject.
  private static let degenerateContentSize = NSSize(width: 200, height: 150)

  /// Whether `window` is currently sized to hold its own content.
  ///
  /// The tolerance is for the equality case, which is the common one and must not
  /// trip: AppKit clamps a drag at `contentMinSize`, autosaves exactly that, and
  /// restores it back. Rejecting a frame the user themselves resized to the
  /// minimum would trade a crash for a window that forgets its size.
  fileprivate static func canHoldContent(_ window: NSWindow) -> Bool {
    let content = window.contentRect(forFrameRect: window.frame).size
    let minimum = window.contentMinSize
    let required = NSSize(
      width: max(minimum.width, degenerateContentSize.width),
      height: max(minimum.height, degenerateContentSize.height))
    return content.width >= required.width - 1 && content.height >= required.height - 1
  }

  func show() {
    if window == nil {
      let hosting = NSHostingController(rootView: content())
      // The minimum and nothing else. An `NSHostingController` will otherwise
      // push SwiftUI's preferred size onto the window as well, and for a window
      // that names its own size below there is nothing to prefer — while the
      // content's `minWidth`/`minHeight` still has to become the resize floor.
      if contentSize != nil {
        hosting.sizingOptions = [.minSize]
      }

      let created = NSWindow(contentViewController: hosting)
      created.title = title
      created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      created.isReleasedWhenClosed = false
      // Neither of this app's two windows is a document, and macOS tabs any two
      // same-class titled, resizable windows when the user has set Desktop & Dock
      // → "Prefer tabs when opening documents" to Always. `.automatic` is the
      // NSWindow default, so without this the Settings window is absorbed as a TAB
      // of the main window on those Macs — and ⌘, appears to do nothing because
      // the pane it opened is behind the tab you were already looking at.
      created.tabbingMode = .disallowed

      // SwiftUI's own fitting size, read before a remembered frame overwrites it.
      let natural = created.frame
      // `setFrameUsingName`, and never `setFrameAutosaveName`. The two read the same
      // key in the same format — a frame saved by a build that used the autosave still
      // restores here — but naming a window for autosave also makes AppKit write the
      // frame out from inside `-[NSWindow _setFrameCommon:]`, and that write aborts this
      // app. The sequence, off the 2026-09-18 report: SwiftUI resizes the window during
      // the window's own layout pass (`NSHostingView.windowDidLayout`), the autosave
      // persists the new frame, persisting posts `NSUserDefaultsDidChange`, SwiftUI's
      // `@AppStorage` observer reads that as a settings change and dirties the hosting
      // view, and the `setNeedsUpdateConstraints` that follows lands inside the layout
      // pass that is still running. AppKit throws rather than re-enter, nobody catches
      // it, and the process takes SIGABRT. It needs no bad frame and no bad window: any
      // `@AppStorage` anywhere in the app is enough, and this app is full of it.
      //
      // The answer is not to stop persisting but to persist somewhere that is not inside
      // a layout pass, which is `FrameSaver` below. The return value is the question that
      // used to be asked of `UserDefaults` directly: has anybody ever sized this window?
      let remembered = created.setFrameUsingName(autosaveName)
      // A remembered frame wins — but only if the content can live in it. AppKit
      // restores whatever was last written under that key, including a frame no
      // layout can satisfy, and a SwiftUI `NavigationSplitView` handed one of
      // those does not merely look wrong: it fails to converge. Past 193
      // constraint passes in one display cycle AppKit throws an exception nobody
      // catches. Seen for real in a sibling app with a saved frame of 1x32 — it
      // died 1.4s into launch, before a window had ever been on screen.
      //
      // Self-perpetuating, which is what earns a guard rather than a one-time
      // reset of the key: `OpeningResizeGuard` pins the window at whatever it
      // opened with, and the autosave writes that straight back out. One bad
      // frame poisons every launch that follows it.
      let unusable = remembered && !Self.canHoldContent(created)
      if unusable {
        created.setFrame(natural, display: false)
      }
      // After the restore, never before. Restoring resizes the window — to the
      // remembered frame when there is one, and to SwiftUI's own idea of the
      // content's width when there is not.
      if !remembered || unusable, let contentSize {
        created.setContentSize(contentSize)
      }
      created.center()
      // Overwrite the frame that was just rejected. `FrameSaver` writes on a user
      // resize, and nothing done here is one, so without this the bad value sits
      // in prefs forever — rediscovered and discarded on every launch.
      if unusable {
        created.saveFrame(usingName: autosaveName)
      }
      window = created
      frameSaver = FrameSaver(window: created, name: autosaveName)

      // SwiftUI sizes a `NavigationSplitView` window to its own idea of the
      // content's width, on a layout pass that lands after `show()` has already
      // returned. Nothing set beforehand survives it: not `setContentSize`, not
      // `sizingOptions`, not an `idealWidth` on the content, and not a frame
      // restored from the autosave — which is the part that matters.
      resizeGuard = OpeningResizeGuard(window: created, intended: created.frame)
    }
    // `makeKeyAndOrderFront` does not restore a miniaturized window: it orders the
    // Dock tile front and leaves the window in the Dock, so "Open Armada" on a
    // window somebody had minimised looks like a button that does nothing. The
    // window is reused rather than rebuilt, so this is the state it is genuinely
    // most likely to be found in.
    if window?.isMiniaturized == true {
      window?.deminiaturize(nil)
    }
    window?.makeKeyAndOrderFront(nil)
    // Then the app itself, every time and not only on the first open. An accessory
    // app does not come forward on its own, and ordering a window front is order
    // *within* an app — it says nothing about which app the user is looking at.
    //
    // `activate(ignoringOtherApps:)`, not the cooperative `activate()`. The
    // cooperative call asks the frontmost app to yield and is refused when nobody
    // does, which is every time the request arrives from a menu bar extra: the
    // user is in some other app, and that app was never asked.
    NSApp.activate(ignoringOtherApps: true)
    DockPresence.update()
  }
}

/// Holds a window at the size it was opened at, for as long as it takes SwiftUI to
/// stop arguing — and not one moment longer.
///
/// SwiftUI resizes a hosted `NavigationSplitView` window unprompted, a layout pass
/// or two after it is ordered front. Every resize after that is a person dragging
/// a corner, and undoing one of those is the bug this must not become, so the
/// whole thing expires on a deadline.
@MainActor
private final class OpeningResizeGuard {
  /// How long SwiftUI gets to argue. Three quarters of a second is long enough for a
  /// window that has only just appeared and far too short for anyone to have grabbed its
  /// edge. `FrameSaver` waits the same span out before it starts believing what it sees.
  static let settle = Duration.milliseconds(750)

  private var token: NSObjectProtocol?

  init?(window: NSWindow, intended: NSRect) {
    // Refusing here is what stops a bad frame becoming permanent: this observer is
    // what would hold the window at it long enough for the autosave to write it
    // back out. Nothing to see off is better than a size nothing can satisfy.
    guard HostedWindow.canHoldContent(window) else { return nil }
    token = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        window.setFrame(intended, display: false)
      }
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.settle)
      self?.stop()
    }
  }

  func stop() {
    guard let token else { return }
    NotificationCenter.default.removeObserver(token)
    self.token = nil
  }
}

/// Remembers where the person put a window, in place of AppKit's frame autosave.
///
/// Two differences from `setFrameAutosaveName`, and each is the whole reason this exists.
///
/// **It writes on a turn of its own.** The autosave writes from inside the `setFrame` that
/// prompted it, which on a SwiftUI-driven resize means writing to `UserDefaults` in the
/// middle of the window's layout pass — the abort described in `HostedWindow.show()`. Every
/// write here is one main-actor hop removed from whatever caused it, so the `@AppStorage`
/// invalidation it sets off arrives at a window that has finished laying out.
///
/// **It only believes the person.** `didEndLiveResize` and `didMove` are somebody dragging
/// an edge or a title bar; `didResize` is also every size SwiftUI tries on its own, which is
/// the value `contentSize` exists to overrule. Listening starts once `OpeningResizeGuard`
/// has stopped pushing the frame around, for the same reason.
@MainActor
private final class FrameSaver {
  private let window: NSWindow
  private let name: String
  private var tokens: [NSObjectProtocol] = []
  private var pending = false

  init(window: NSWindow, name: String) {
    self.window = window
    self.name = name
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: OpeningResizeGuard.settle)
      self?.listen()
    }
  }

  private func listen() {
    for notification in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
      tokens.append(
        NotificationCenter.default.addObserver(
          forName: notification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.schedule() }
        })
    }
  }

  /// One write per turn, however many notifications land in it: a drag that both resizes
  /// and moves the window posts two, and they describe the same frame.
  private func schedule() {
    guard !pending else { return }
    pending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      pending = false
      // The same floor the restore applies, on the way out rather than on the way in.
      // A frame no layout can satisfy is not worth keeping, and keeping one is what
      // makes it permanent — see `show()`.
      guard window.isVisible, HostedWindow.canHoldContent(window) else { return }
      window.saveFrame(usingName: name)
    }
  }
}
