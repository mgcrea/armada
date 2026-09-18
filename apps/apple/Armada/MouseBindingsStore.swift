import Foundation

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

  func add() {
    bindings.append(MouseBinding(modifiers: .command, button: 3, action: .f13))
  }

  func remove(_ binding: MouseBinding) {
    bindings.removeAll { $0.id == binding.id }
  }
}
