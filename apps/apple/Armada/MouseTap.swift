import AppKit
import CoreGraphics

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
final class MouseTap {
  static let shared = MouseTap()

  private var port: CFMachPort?
  private var source: CFRunLoopSource?

  /// Buttons whose press this tap swallowed, so the matching release can be
  /// swallowed too.
  ///
  /// **Not re-matched on the way up, deliberately.** Let go of Option before the
  /// button and the release carries different flags from the press, matches nothing,
  /// and would pass through on its own — leaving the application a button-up it never
  /// saw go down. Which button was swallowed is the only thing that decides this.
  private var swallowed: Set<Int> = []

  private var capture: ((Int) -> Void)?

  /// The modifiers a binding can be built from. Everything else in `CGEventFlags` —
  /// Caps Lock, the numeric-keypad and non-coalesced bits — is masked out before a
  /// comparison, or a press with Caps Lock on would match nothing.
  static let watchedFlags: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift,
  ]

  private init() {}

  var isRunning: Bool { port != nil }

  /// Start or stop the tap to match what the settings now say.
  ///
  /// Called from everywhere that can change the answer — the store on a write, the
  /// app on launch, the trust object when the grant arrives — rather than each of
  /// them deciding. Idempotent in both directions.
  func sync() {
    let wanted =
      capture != nil
      || (MouseBindingsStore.shared.isEnabled && !MouseBindingsStore.shared.bindings.isEmpty)
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
          // The run loop source is on the main run loop, so this genuinely is the
          // main actor; the assumption is checked in debug builds.
          return MainActor.assumeIsolated {
            tap.handle(proxy: proxy, type: type, event: event)
          }
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return }

    self.port = port
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
  }

  private func stop() {
    guard let port else { return }
    CGEvent.tapEnable(tap: port, enable: false)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    CFMachPortInvalidate(port)
    self.port = nil
    source = nil
    swallowed.removeAll()
  }

  /// **Everything here has to be cheap.** macOS disables a tap whose callback runs
  /// long and gives no warning that it did, so the only work done inline is a
  /// dictionary-sized lookup and, for a keystroke, posting two events. Armada's own
  /// commands reach LaunchServices and the Accessibility API and are far too slow, so
  /// they are dispatched and this returns immediately.
  fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent)
    -> Unmanaged<CGEvent>?
  {
    // Not in the mask, but delivered anyway — this is the one notification that the
    // tap has been turned off, and re-enabling is the only way back. Without it the
    // feature dies silently on the first slow callback and stays dead until relaunch.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
      return nil
    }

    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

    if type == .otherMouseUp {
      return swallowed.remove(button) == nil ? Unmanaged.passUnretained(event) : nil
    }
    guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }

    if let capture {
      self.capture = nil
      swallowed.insert(button)
      // Out of the callback before touching SwiftUI state, and `sync()` afterwards so
      // the tap stops again if it was only running for this.
      DispatchQueue.main.async {
        capture(button)
        MouseTap.shared.sync()
      }
      return nil
    }

    let flags = event.flags.intersection(Self.watchedFlags)
    guard let binding = MouseBindingsStore.shared.binding(button: button, flags: flags) else {
      // The unbound case, and the common one: an unmodified side button is Back in
      // every browser on the Mac and has to arrive untouched.
      return Unmanaged.passUnretained(event)
    }

    swallowed.insert(button)
    if let key = binding.action.keyCode {
      post(key: key, proxy: proxy)
    } else {
      let action = binding.action
      DispatchQueue.main.async { MouseCommand.run(action) }
    }
    return nil
  }

  /// **Posted through the proxy, not `CGEvent.post`.** The proxy injects downstream of
  /// this tap, so the key cannot arrive back at this callback.
  ///
  /// **Flags cleared.** The modifier that triggered the binding is still physically
  /// down, and leaving it on the synthesised event would deliver ⌥F13 to an
  /// application told to expect F13. What the application reads is the event's own
  /// flags, so clearing them is what makes the binding in the far side's settings the
  /// obvious one.
  private func post(key: CGKeyCode, proxy: CGEventTapProxy) {
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
      else { continue }
      event.flags = []
      event.tapPostEvent(proxy)
    }
  }
}
