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
enum MouseAction: String, CaseIterable, Codable, Identifiable, Hashable {
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

  /// The row's label, which for a keystroke has to name the chord that will actually
  /// arrive rather than the key alone.
  ///
  /// `MouseTap` carries the trigger's modifiers onto the key it sends, so a row
  /// reading "Send F15" next to a ⌘ trigger would send the reader off to bind `f15`
  /// in another application and watch nothing happen. Armada's own commands do not
  /// vary with the trigger and ignore it.
  func label(firedWith modifiers: MouseModifiers) -> String {
    guard let keyName else { return label }
    return "Send \(modifiers.label)\(keyName)"
  }
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
enum MouseModifiers: String, CaseIterable, Codable, Identifiable, Hashable {
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
struct MouseBinding: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var modifiers: MouseModifiers = .option
  /// `mouseEventButtonNumber`, which is zero-based: 2 is the middle button, 3 and 4
  /// are the two side buttons on a mouse that has them. Left and right are 0 and 1
  /// and never reach here — the tap does not ask for them.
  var button: Int = 3
  var action: MouseAction = .focusNextWaiting

  /// How the button is named in a row. The displayed number is one-based, because
  /// that is what every mouse's own documentation and configuration software calls
  /// it: `mouseEventButtonNumber` 3 is the button Logitech and Razer both label 4.
  static func buttonLabel(_ button: Int) -> String {
    switch button {
    case 2: "Middle button"
    case 3: "Button 4 (back)"
    case 4: "Button 5 (forward)"
    default: "Button \(button + 1)"
    }
  }

  /// The buttons offered without asking the mouse. Anything else arrives through
  /// `MouseTap.beginCapture` — a mouse with a thumb cluster numbers them however it
  /// likes, and guessing would be worse than asking.
  static let offeredButtons = [2, 3, 4]

  var label: String {
    modifiers == .none
      ? Self.buttonLabel(button) : "\(modifiers.label) \(Self.buttonLabel(button))"
  }

  /// Whether this binding takes a button the rest of the Mac already uses on its own:
  /// Back and Forward, which every browser and editor answers to.
  var replacesSystemButton: Bool { modifiers == .none && (button == 3 || button == 4) }
}

/// The bindings, and whether they are live.
///
/// **Not `@AppStorage`, unlike every other setting in this app.** The reader of this
/// list is `MouseTap`, which is not a view and has no property wrapper to observe
/// the key with; a settings pane writing to defaults and a tap polling them would be
/// two sources of truth for something that has to be exactly right at the moment a
/// button goes down. So the store is the authority, it persists on write, and it
/// tells the tap to re-evaluate itself. The JSON round-trip through a defaults string
/// is the same shape `DayWeights.stored` uses, and for the same reason: a list
/// written by a later version has to degrade to something usable rather than trap.
@MainActor
@Observable
final class MouseBindingsStore {
  static let shared = MouseBindingsStore()

  static let enabledKey = "armada.mouseBindingsEnabled"
  static let bindingsKey = "armada.mouseBindings"

  var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
      MouseTap.shared.sync()
    }
  }

  var bindings: [MouseBinding] {
    didSet {
      guard bindings != oldValue else { return }
      persist()
      MouseTap.shared.sync()
    }
  }

  /// What a fresh install gets the first time the toggle is turned on.
  ///
  /// Two bindings rather than none, because an empty list makes the toggle do
  /// nothing and reads as a broken setting. Both are Armada's own commands: seeding
  /// a keystroke would send F13 to applications that have not been told to expect
  /// it, which is harmless but also pointless until somebody binds it.
  static let seed: [MouseBinding] = [
    MouseBinding(modifiers: .option, button: 3, action: .focusNextWaiting),
    MouseBinding(modifiers: .option, button: 4, action: .showArmada),
  ]

  private init() {
    let defaults = UserDefaults.standard
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    if let stored = defaults.string(forKey: Self.bindingsKey),
      let data = stored.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([MouseBinding].self, from: data)
    {
      bindings = decoded
    } else {
      bindings = Self.seed
    }
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(bindings),
      let json = String(data: data, encoding: .utf8)
    else { return }
    UserDefaults.standard.set(json, forKey: Self.bindingsKey)
  }

  /// The binding a press matches, or nil. First match wins, so a list that somehow
  /// holds two bindings for one trigger behaves predictably rather than arbitrarily.
  func binding(button: Int, flags: CGEventFlags) -> MouseBinding? {
    bindings.first { $0.button == button && $0.modifiers.flags == flags }
  }

  func add() {
    bindings.append(MouseBinding(modifiers: .command, button: 3, action: .f13))
  }

  func remove(_ binding: MouseBinding) {
    bindings.removeAll { $0.id == binding.id }
  }
}
