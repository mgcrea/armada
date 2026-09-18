import CoreGraphics
import Foundation

/// What a bound mouse button does.
///
/// **One flat enum rather than a command case and a keystroke case with an
/// associated value.** The two halves are genuinely different — half of these drive
/// Armada, half send a key it knows nothing about — but the key set is fixed at
/// eight and never grows, so splitting them would buy a custom `Codable`
/// conformance and a two-level picker in exchange for nothing. The split that
/// matters is `keyCode`, which is nil for exactly the Armada half.
///
/// **F13–F20 and nothing else.** They are the only keys macOS leaves entirely
/// unclaimed, which is what makes them safe to send system-wide: an application that
/// binds F13 asked for it, and one that does not sees a key it ignores. That is also
/// why this needs no per-application scoping — Armada does not decide what the key
/// means, the application receiving it does.
nonisolated enum MouseAction: String, CaseIterable, Codable, Identifiable, Hashable {
  case focusNextWaiting
  case focusNextSession
  case focusPreviousSession
  case showArmada
  case f13, f14, f15, f16, f17, f18, f19, f20

  var id: String { rawValue }

  /// The Armada half, in menu order.
  static let commands: [MouseAction] = [
    .focusNextWaiting, .focusNextSession, .focusPreviousSession, .showArmada,
  ]

  /// The keystroke half.
  static let keys: [MouseAction] = [.f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]

  /// The virtual key to send, or nil for an action Armada performs itself.
  ///
  /// The constants are `kVK_F13`…`kVK_F20` from HIToolbox, written out because
  /// importing Carbon for eight integers is not a trade worth making. They are not
  /// contiguous and are not in an order anyone would guess — F16 is 0x6A, between
  /// F13 and F14 — so they are spelled one per line where a typo is visible.
  var keyCode: CGKeyCode? {
    switch self {
    case .f13: 0x69
    case .f14: 0x6B
    case .f15: 0x71
    case .f16: 0x6A
    case .f17: 0x40
    case .f18: 0x4F
    case .f19: 0x50
    case .f20: 0x5A
    default: nil
    }
  }

  var label: String {
    switch self {
    case .focusNextWaiting: "Focus next waiting session"
    case .focusNextSession: "Focus next session"
    case .focusPreviousSession: "Focus previous session"
    case .showArmada: "Open Armada"
    default: "Send \(rawValue.uppercased())"
    }
  }

  /// "F15" for the keystroke half, nil for Armada's own commands.
  var keyName: String? { keyCode == nil ? nil : rawValue.uppercased() }
}

/// The modifiers a binding fires on, as a closed list of combinations.
///
/// **`none` is allowed, and it is the one case that costs something elsewhere.** A
/// bare side button is Back and Forward in every browser and editor on the Mac, and
/// a binding that claims it takes that away everywhere for as long as the setting
/// stays on. That is the reader's call to make — a middle button nobody uses, or a
/// thumb button with no other job, is exactly what a bare binding is for — so the
/// case exists, sits last in the picker, and the Mouse pane says what it replaces.
/// Unbound presses, modified or not, still pass straight through.
///
/// A closed list rather than a set of four toggles because the picker is then one
/// control with readable rows. The combinations left out — anything with three
/// modifiers, Shift alone with a button — are the ones nobody reaches for.
nonisolated enum MouseModifiers: String, CaseIterable, Codable, Identifiable, Hashable {
  case option
  case command
  case control
  case shift
  case optionCommand
  case optionShift
  case commandShift
  case controlOption
  case none

  var id: String { rawValue }

  var flags: CGEventFlags {
    switch self {
    case .option: [.maskAlternate]
    case .command: [.maskCommand]
    case .control: [.maskControl]
    case .shift: [.maskShift]
    case .optionCommand: [.maskAlternate, .maskCommand]
    case .optionShift: [.maskAlternate, .maskShift]
    case .commandShift: [.maskCommand, .maskShift]
    case .controlOption: [.maskControl, .maskAlternate]
    case .none: []
    }
  }

  /// The glyphs, in Apple's canonical modifier order (⌃⌥⇧⌘), because that is the
  /// order every menu on the Mac prints them in and a row that disagreed would read
  /// as a different chord.
  var label: String {
    switch self {
    case .option: "⌥"
    case .command: "⌘"
    case .control: "⌃"
    case .shift: "⇧"
    case .optionCommand: "⌥⌘"
    case .optionShift: "⌥⇧"
    case .commandShift: "⇧⌘"
    case .controlOption: "⌃⌥"
    case .none: ""
    }
  }

  /// How the case reads in the picker, where an empty glyph would be a blank row.
  var pickerLabel: String { self == .none ? "No modifier" : label }
}

/// One trigger and what it does.
nonisolated struct MouseBinding: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var modifiers: MouseModifiers = .option
  /// `mouseEventButtonNumber`, which is zero-based: 2 is the middle button, 3 and 4
  /// are the two side buttons on a mouse that has them. Left and right are 0 and 1
  /// and never reach here — the tap does not ask for them. A negative number is one
  /// of the combos below rather than a button.
  var button: Int = 3
  var action: MouseAction = .focusNextWaiting
  /// The modifiers a key is sent with, or nil to send it with the ones held on the
  /// trigger.
  ///
  /// **Nil, "as held", is the default, and not only so that lists saved before this
  /// existed decode unchanged.** It is what makes a hold-and-release picker work from
  /// the mouse: hold ⌥ and a button, and VS Code sees ⌥F13 go down and picks when ⌥
  /// comes up. A chosen modifier is for a trigger that has none to give — a combo on
  /// the bare thumb buttons that should still arrive as ⌘F16 — and it replaces what
  /// is held rather than adding to it, so the row can name exactly one chord.
  var sentModifiers: MouseModifiers?

  /// What a sent key carries. See `sentModifiers`.
  var sentFlags: CGEventFlags { (sentModifiers ?? modifiers).flags }

  /// The flags a sent key is actually posted with: `sentFlags`, plus fn.
  ///
  /// **fn is not optional.** Every F-key a real keyboard sends has it set, and a
  /// Carbon hot key — `RegisterEventHotKey`, which is how Cadence and most menu bar
  /// apps take a global shortcut — does not match an F-key without it. Sent bare, F17
  /// went straight past Cadence's dictation shortcut and landed on the front app as a
  /// key nobody handles, which is a beep. Applications that read the key event
  /// directly, VS Code among them, get what a keyboard would have sent them either
  /// way.
  var keystrokeFlags: CGEventFlags { sentFlags.union(.maskSecondaryFn) }

  /// What the action column reads: the chord that will actually arrive for a key, so
  /// the reader binds the right thing in the other application.
  var actionLabel: String {
    guard let keyName = action.keyName else { return action.label }
    return "Send \((sentModifiers ?? modifiers).label)\(keyName)"
  }

  /// The two thumb buttons pressed together.
  ///
  /// **A negative number in the button field rather than a trigger type of its own.**
  /// A binding stays one modifier, one button and one action, so a list written
  /// before combos existed decodes unchanged and no migration runs. No mouse reports
  /// a negative button, so these can never match a press. `-1` is the number Cadence
  /// writes for the same trigger, and the two apps share this mechanism.
  static let backAndForward = -1
  /// Back held, Forward clicked — and clicked again, as often as you like.
  static let backThenForward = -2
  /// The same the other way round.
  static let forwardThenBack = -3

  /// The combos, in menu order.
  static let combos = [backAndForward, backThenForward, forwardThenBack]

  /// The only pair a combo is built from: the two buttons one thumb can work at
  /// once. Every other button on a mouse needs the hand to move, which is not a
  /// chord anybody would press.
  static let comboPair: Set<Int> = [3, 4]

  /// The modifiers a binding can be built from. Everything else in `CGEventFlags` —
  /// Caps Lock, the keypad and non-coalesced bits — is masked out before comparing,
  /// or a press with Caps Lock on would match nothing.
  static let watchedFlags: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift,
  ]

  var isCombo: Bool { button < 0 }

  /// The button that is *held* by an ordered combo, or nil for anything else.
  var orderedAnchor: Int? {
    switch button {
    case Self.backThenForward: 3
    case Self.forwardThenBack: 4
    default: nil
    }
  }

  /// Whether a press of this button could turn out to be this binding, which is what
  /// decides that the press has to be held back at all.
  func comboStarts(with button: Int) -> Bool {
    switch self.button {
    case Self.backAndForward: Self.comboPair.contains(button)
    case Self.backThenForward, Self.forwardThenBack: orderedAnchor == button
    default: false
    }
  }

  /// How the button is named in a row. The displayed number is one-based, because
  /// that is what every mouse's own documentation and configuration software calls
  /// it: `mouseEventButtonNumber` 3 is the button Logitech and Razer both label 4.
  static func buttonLabel(_ button: Int) -> String {
    switch button {
    case backAndForward: "Back + Forward together"
    case backThenForward: "Hold Back, press Forward"
    case forwardThenBack: "Hold Forward, press Back"
    case 2: "Middle button"
    case 3: "Button 4 (back)"
    case 4: "Button 5 (forward)"
    default: "Button \(button + 1)"
    }
  }

  /// The buttons offered without asking the mouse. Anything else arrives through
  /// `MouseTap.beginCapture` — a mouse with a thumb cluster numbers them however it
  /// likes, and guessing would be worse than asking.
  static let singleButtons = [2, 3, 4]

  /// Every trigger the picker offers without asking the mouse: the buttons, then the
  /// combos.
  static let offeredButtons = singleButtons + combos

  var label: String {
    modifiers == .none
      ? Self.buttonLabel(button) : "\(modifiers.label) \(Self.buttonLabel(button))"
  }

  /// What a binding with no modifier costs the rest of the Mac, said in the row that
  /// sets it. Nil when it costs nothing: with a modifier held, every one of these
  /// buttons still does what it always did.
  ///
  /// A combo costs something too, and something stranger than losing a button: the
  /// press it waits on cannot be delivered until the wait is over. That is worth a
  /// line where it is chosen rather than a surprise in a browser later.
  var systemCost: String? {
    guard modifiers == .none else { return nil }
    switch button {
    case 2:
      return "With no modifier, this button stops opening links in a new tab."
    case 3, 4:
      let direction = button == 3 ? "back" : "forward"
      return "With no modifier, this button stops going \(direction) in every app."
    case Self.backAndForward:
      return "With no modifier, Back and Forward reach other apps 70 ms late."
    case Self.backThenForward, Self.forwardThenBack:
      let held = orderedAnchor == 3 ? "Back" : "Forward"
      return "With no modifier, \(held) only reaches other apps when you let the button go."
    default:
      return nil
    }
  }

}
