import CoreGraphics

/// The modifier keys Armada holds down for as long as the trigger that sent a key is
/// held, the way a hand holds ⌘ through ⌘Tab.
///
/// **A flag on the key is not the same as the key.** A sent F15 has always carried ⌘
/// in its flags, and that is enough for an application to read the chord. It is not
/// enough for one that waits for ⌘ to come *up*: VS Code's window picker opens on
/// ⌘F15, walks on each further ⌘F15, and picks when the ⌘ key is released — a key
/// event of its own that nothing ever sent, so the picker stayed open until Return.
/// So the modifier goes down as a real key before the first sent key of a run, stays
/// down through every repeat, and comes up when the trigger is let go. From the
/// application's side that is indistinguishable from the keyboard.
///
/// **Only modifiers the hand is not already holding.** "As held" sends the chord the
/// hand is making, and the real ⌘ key-down and key-up are already on their way; a
/// second ⌘ from here would be a key that goes down twice.
///
/// **Nothing may be left down.** A ⌘ stuck down turns every later keystroke into a
/// shortcut, which is worse than the picker it fixes. So besides the trigger's own
/// release, `reset()` lets go of everything, and `MouseTap` calls it whenever the tap
/// stops, is disabled by macOS, or has its bindings changed.
///
/// Numbers in, events out, like `MouseChord`, so `make unit` checks it.
nonisolated struct ModifierHold {
  /// One modifier key going down or up, and the flags the event carries: everything
  /// held once it has happened.
  struct Event: Equatable {
    let key: CGKeyCode
    let down: Bool
    let flags: CGEventFlags
  }

  /// In the order a hand presses them, and so the order they go down; they come up
  /// in reverse. `kVK_Shift`, `kVK_Control`, `kVK_Option` and `kVK_Command`, written
  /// out for the same reason as the F-keys in `MouseAction`.
  private static let keys: [(flag: CGEventFlags, key: CGKeyCode)] = [
    (.maskShift, 0x38), (.maskControl, 0x3B), (.maskAlternate, 0x3A), (.maskCommand, 0x37),
  ]

  /// What this has pressed and not yet released.
  private(set) var held: CGEventFlags = []
  /// The buttons whose release ends the hold.
  private var releasedBy: Set<Int> = []

  /// A key is about to be sent with `sent`, while the hand holds `physical`. Returns
  /// the modifier events to post first, in order.
  mutating func fire(
    sent: CGEventFlags, physical: CGEventFlags, releasedBy buttons: Set<Int>
  ) -> [Event] {
    let wanted = sent.intersection(MouseBinding.watchedFlags).subtracting(
      physical.intersection(MouseBinding.watchedFlags))
    var events: [Event] = []
    // A different chord from the one being held: let that one go before this one
    // goes down, as a hand would.
    if !held.isEmpty, held != wanted {
      events += reset()
    }
    if held.isEmpty, !wanted.isEmpty {
      for (flag, key) in Self.keys where wanted.contains(flag) {
        held.insert(flag)
        events.append(Event(key: key, down: true, flags: held))
      }
    }
    if !held.isEmpty { releasedBy.formUnion(buttons) }
    return events
  }

  /// A button came up. If it is one the hold is waiting on, let go.
  mutating func release(button: Int) -> [Event] {
    guard releasedBy.contains(button) else { return [] }
    return reset()
  }

  /// Let go of everything.
  mutating func reset() -> [Event] {
    var events: [Event] = []
    for (flag, key) in Self.keys.reversed() where held.contains(flag) {
      held.remove(flag)
      events.append(Event(key: key, down: false, flags: held))
    }
    releasedBy.removeAll()
    return events
  }
}
