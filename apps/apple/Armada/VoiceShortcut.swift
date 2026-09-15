import AppKit
import Carbon.HIToolbox
import Observation

/// The one global shortcut voice listens for.
///
/// **`RegisterEventHotKey`, not an event tap.** A hot key needs no Accessibility or Input
/// Monitoring grant, and the system delivers exactly the registered chord, pressed and
/// released, and nothing else: every other keystroke on the Mac never reaches Armada. That is
/// the claim `MouseTap` makes for the mouse, and a keyboard tap would have broken it.
///
/// **Presses are de-duplicated.** Holding a hot key can deliver repeated presses; only the
/// first press after a release counts, so hold mode sees one press and one release, and press
/// mode never reads a held key as a second press.
@MainActor @Observable
final class VoiceShortcut {
  struct Chord: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32
    /// The key's name as it was recorded. A key code alone does not say what the keyboard
    /// prints on that key.
    var key: String

    static let `default` = Chord(
      keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Space")

    nonisolated static let defaultsKey = "armada.voiceShortcut"

    static var stored: Chord {
      guard let data = UserDefaults.standard.data(forKey: defaultsKey),
        let chord = try? JSONDecoder().decode(Chord.self, from: data)
      else { return .default }
      return chord
    }

    func store() {
      UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    var display: String {
      var text = ""
      if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
      if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
      if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
      if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
      return text + key
    }
  }

  enum State: Equatable {
    case off
    case registered(Chord)
    /// Another application holds that chord.
    case taken(Chord)
  }

  static let shared = VoiceShortcut()

  private(set) var state: State = .off

  @ObservationIgnored var onPress: (() -> Void)?
  @ObservationIgnored var onRelease: (() -> Void)?

  @ObservationIgnored private var hotKey: EventHotKeyRef?
  @ObservationIgnored private var handler: EventHandlerRef?
  @ObservationIgnored private var isDown = false

  /// "ARMD", so the event can be told apart from another hot key in the same process.
  private static let signature: OSType = 0x4152_4D44

  private init() {}

  func register(_ chord: Chord) {
    if case .registered(let current) = state, current == chord { return }
    unregister()
    installHandler()
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      chord.keyCode, chord.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
      GetApplicationEventTarget(), 0, &reference)
    if status == noErr, let reference {
      hotKey = reference
      state = .registered(chord)
    } else {
      state = .taken(chord)
    }
  }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    isDown = false
    state = .off
  }

  private func installHandler() {
    guard handler == nil else { return }
    var kinds = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    // The application event target calls back on the main thread, which is what makes
    // `assumeIsolated` true rather than hopeful.
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        let shortcut = Unmanaged<VoiceShortcut>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { shortcut.deliver(pressed: pressed) }
        return noErr
      }, kinds.count, &kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  private func deliver(pressed: Bool) {
    guard pressed != isDown else { return }
    isDown = pressed
    if pressed { onPress?() } else { onRelease?() }
  }
}
