import AppKit
import CoreGraphics

/// What the tap does with one event.
///
/// Decided on the main actor, where the bindings and the swallowed set live, and
/// carried out by the C callback, which is the only code holding the event. `CGEvent`
/// is not `Sendable`, so under Swift 6 the event itself cannot cross onto the main
/// actor; the button, the flags and this answer can.
private nonisolated enum TapDecision: Sendable {
  case pass
  case swallow
  /// Swallow the button and post this key, with these modifiers, in its place.
  case send(CGKeyCode, CGEventFlags)
}

/// The event tap behind mouse bindings.
///
/// **User space, not a driver.** A `CGEventTap` is the whole mechanism: one process,
/// no kernel extension, no daemon, and the Accessibility grant Armada already holds
/// for `HostWindow`. What it costs instead is stated in Settings — a tap sees nothing
/// inside a Secure Input context, so a binding is simply dead while a password field
/// has focus, with no event and no error to report.
///
/// **The mask is two event types wide and that is the ceiling.** `otherMouseDown` and
/// `otherMouseUp` are the middle and extra buttons. Left clicks, right clicks, pointer
/// movement, scrolling and every keystroke are outside it and never reach this
/// process. The footer in `GeneralPane` says so, and this comment is the thing that
/// has to stay true for it.
@MainActor
@Observable
final class MouseTap {
  static let shared = MouseTap()

  @ObservationIgnored private var port: CFMachPort?
  @ObservationIgnored private var source: CFRunLoopSource?

  /// Buttons whose press this tap swallowed, so the matching release can be
  /// swallowed too.
  ///
  /// **Not re-matched on the way up, deliberately.** Let go of Option before the
  /// button and the release carries different flags from the press, matches nothing,
  /// and would pass through on its own — leaving the application a button-up it never
  /// saw go down. Which button was swallowed is the only thing that decides this.
  ///
  /// **An entry lasts until that button's next press, never longer.** A release can
  /// fail to arrive: macOS drops a tap's events while it is disabled for a slow
  /// callback, and a Secure Input field hides them. Left in place, that entry would
  /// swallow the release of some later press that was never swallowed, and the
  /// application would see a button go down and stay down. A button cannot go down
  /// twice without coming up, so the next press of it is exactly the moment an old
  /// entry is known to be stale, which bounds it better than a clock would.
  @ObservationIgnored private var swallowed: Set<Int> = []

  @ObservationIgnored private var capture: ((Int) -> Void)?

  /// The modifiers a binding can be built from. Everything else in `CGEventFlags` —
  /// Caps Lock, the numeric-keypad and non-coalesced bits — is masked out before a
  /// comparison, or a press with Caps Lock on would match nothing.
  static let watchedFlags: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift,
  ]

  private init() {}

  /// Whether the tap exists. Observed, because `CGEvent.tapCreate` can refuse with the
  /// grant in place, and the Mouse pane is where that has to show: nothing else about
  /// a refused tap is visible anywhere.
  private(set) var isRunning = false

  /// Whether the bindings, as opposed to a capture, want the tap running.
  ///
  /// Bindings stop with the rest of Armada when the entitlement is refused — see
  /// `EntitlementMonitor`.
  var bindingsWantTap: Bool {
    EntitlementMonitor.shared.current.isEntitled
      && MouseBindingsStore.shared.isEnabled && !MouseBindingsStore.shared.bindings.isEmpty
  }

  /// Start or stop the tap to match what the settings now say.
  ///
  /// Called from everywhere that can change the answer — the store on a write, the
  /// app on launch, the trust object when the grant arrives — rather than each of
  /// them deciding. Idempotent in both directions, and a tap macOS refused is asked
  /// for again on the next call.
  func sync() {
    // Capture runs while unlicensed too: it only learns a button number for the
    // Detect button in Settings.
    let wanted = capture != nil || bindingsWantTap
    if wanted && HostWindow.isTrusted {
      start()
    } else {
      stop()
    }
  }

  /// Learn the next button pressed, for the "Detect" button in Settings.
  ///
  /// Side buttons are numbered by the mouse, not by macOS: 3 and 4 are the common
  /// answer and the offered ones, but a thumb cluster can report anything. Capture
  /// runs the tap even when bindings are off, so this works before the feature has
  /// been turned on — which is the order somebody setting it up will do it in.
  func beginCapture(_ handler: @escaping (Int) -> Void) {
    capture = handler
    sync()
  }

  func cancelCapture() {
    guard capture != nil else { return }
    capture = nil
    sync()
  }

  var isCapturing: Bool { capture != nil }

  private func start() {
    guard port == nil else { return }
    let mask =
      (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
    // The callback is a C function pointer and so captures nothing; `self` reaches it
    // through `userInfo`. Unretained is safe for a singleton that outlives the tap.
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { proxy, type, event, userInfo in
          guard let userInfo else { return Unmanaged.passUnretained(event) }
          let tap = Unmanaged<MouseTap>.fromOpaque(userInfo).takeUnretainedValue()
          // Read out here, so that only values cross onto the main actor. The
          // tap-disabled notifications are not button events and carry no button.
          let isButton = type == .otherMouseDown || type == .otherMouseUp
          let button = isButton ? Int(event.getIntegerValueField(.mouseEventButtonNumber)) : 0
          let flags = event.flags
          // The run loop source is on the main run loop, so this genuinely is the
          // main actor; the assumption is checked in debug builds.
          let decision = MainActor.assumeIsolated {
            tap.decide(type: type, button: button, flags: flags)
          }
          switch decision {
          case .pass:
            return Unmanaged.passUnretained(event)
          case .swallow:
            return nil
          case .send(let key, let modifiers):
            MouseTap.post(key: key, modifiers: modifiers, proxy: proxy)
            return nil
          }
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      // Refused with the grant apparently in place. `isRunning` stays false, which the
      // Mouse pane reads, and the next `sync()` asks again.
      isRunning = false
      return
    }

    self.port = port
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    isRunning = true
  }

  private func stop() {
    guard let port else { return }
    CGEvent.tapEnable(tap: port, enable: false)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    CFMachPortInvalidate(port)
    self.port = nil
    source = nil
    swallowed.removeAll()
    isRunning = false
  }

  /// **Everything here has to be cheap.** macOS disables a tap whose callback runs
  /// long and gives no warning that it did, so the only work done inline is a
  /// dictionary-sized lookup and, for a keystroke, posting two events. Armada's own
  /// commands reach LaunchServices and the Accessibility API and are far too slow, so
  /// they are dispatched and this returns immediately.
  fileprivate func decide(type: CGEventType, button: Int, flags: CGEventFlags) -> TapDecision {
    // Not in the mask, but delivered anyway — this is the one notification that the
    // tap has been turned off, and re-enabling is the only way back. Without it the
    // feature dies silently on the first slow callback and stays dead until relaunch.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
      return .swallow
    }

    if type == .otherMouseUp {
      return swallowed.remove(button) == nil ? .pass : .swallow
    }
    guard type == .otherMouseDown else { return .pass }
    // A press means any release still pending for this button was lost. See `swallowed`.
    swallowed.remove(button)

    if let capture {
      self.capture = nil
      swallowed.insert(button)
      // Out of the callback before touching SwiftUI state, and `sync()` afterwards so
      // the tap stops again if it was only running for this.
      DispatchQueue.main.async {
        capture(button)
        MouseTap.shared.sync()
      }
      return .swallow
    }

    let held = flags.intersection(Self.watchedFlags)
    guard let binding = MouseBindingsStore.shared.binding(button: button, flags: held) else {
      // The unbound case, and the common one: a side button nobody bound is Back in
      // every browser on the Mac and has to arrive untouched.
      return .pass
    }

    swallowed.insert(button)
    if let key = binding.action.keyCode {
      return .send(key, binding.modifiers.flags)
    }
    let action = binding.action
    DispatchQueue.main.async { MouseCommand.run(action) }
    return .swallow
  }

  /// **Posted through the proxy, not `CGEvent.post`.** The proxy injects downstream of
  /// this tap, so the key cannot arrive back at this callback.
  ///
  /// **The trigger's modifiers are carried onto the key**, so ⌘ and a side button
  /// arrive as ⌘F15 rather than as a bare F15. Clearing them was the first shape of
  /// this and it was the wrong one, for a reason that is not about headroom:
  /// **a modifier-less chord cannot drive a hold-and-repeat picker.** VS Code's quick
  /// navigate — what Ctrl+Tab does, and what `quickSwitchWindow` is for — commits when
  /// the modifier of the invoking chord is *released*, testing `metaKey`/`altKey` on
  /// the chord and the modifier's own keycode on the key-up. A chord with no modifier
  /// can never satisfy it, so the picker opens in a mode whose exit condition is
  /// unreachable and the reader has to reach for Return. Carrying the modifier makes
  /// that whole class of binding work, and costs only a longer chord to type on the
  /// far side.
  ///
  /// Armada swallows the button and never the modifier, so the application still sees
  /// the real ⌘ key-down and key-up on either side of this.
  fileprivate nonisolated static func post(
    key: CGKeyCode, modifiers: CGEventFlags, proxy: CGEventTapProxy
  ) {
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
      else { continue }
      event.flags = modifiers
      event.tapPostEvent(proxy)
    }
  }
}
