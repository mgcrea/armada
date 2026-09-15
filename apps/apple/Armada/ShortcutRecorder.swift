import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that records the next key chord typed after it is clicked.
///
/// **A local monitor, and only while recording.** It sees keys typed into Armada's own
/// Settings window and nothing else, and it is removed as soon as a chord is taken, Esc is
/// pressed, or the pane goes away.
///
/// **The shortcut is unregistered while recording**, so typing the current chord to record it
/// again reaches this field instead of starting a question.
///
/// **A modifier is required**, except on a function key: a bare letter as a global hot key
/// would take that letter from every other application.
struct ShortcutRecorder: View {
  @Binding var chord: VoiceShortcut.Chord
  @State private var recording = false
  @State private var monitor: Any?
  @State private var rejected = false

  var body: some View {
    HStack(spacing: 8) {
      if rejected {
        Text("Include ⌘, ⌥ or ⌃")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Button(recording ? "Type a shortcut…" : chord.display) {
        if recording { stop() } else { start() }
      }
    }
    .onDisappear(perform: stop)
  }

  private func start() {
    rejected = false
    recording = true
    VoiceShortcut.shared.unregister()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event) ? nil : event
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    guard recording else { return }
    recording = false
    VoiceController.shared.sync()
  }

  /// Whether the event was taken, which is every key while recording.
  private func handle(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let keyCode = Int(event.keyCode)
    if keyCode == kVK_Escape, flags.isEmpty {
      stop()
      return true
    }
    let modifiers = Self.carbonModifiers(flags)
    let functionKey = Self.functionKeys[keyCode]
    guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || functionKey != nil else {
      rejected = true
      return true
    }
    let recorded = VoiceShortcut.Chord(
      keyCode: UInt32(keyCode), modifiers: modifiers,
      key: functionKey ?? Self.name(for: event, keyCode: keyCode))
    // Stored before `stop()` re-registers, so it registers the new chord rather than the old.
    recorded.store()
    chord = recorded
    rejected = false
    stop()
    return true
  }

  private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var value: UInt32 = 0
    if flags.contains(.command) { value |= UInt32(cmdKey) }
    if flags.contains(.option) { value |= UInt32(optionKey) }
    if flags.contains(.control) { value |= UInt32(controlKey) }
    if flags.contains(.shift) { value |= UInt32(shiftKey) }
    return value
  }

  private static func name(for event: NSEvent, keyCode: Int) -> String {
    switch keyCode {
    case kVK_Space: "Space"
    case kVK_Return: "↩"
    case kVK_Tab: "⇥"
    case kVK_Delete: "⌫"
    case kVK_LeftArrow: "←"
    case kVK_RightArrow: "→"
    case kVK_UpArrow: "↑"
    case kVK_DownArrow: "↓"
    default:
      event.charactersIgnoringModifiers.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        ?? "Key \(keyCode)"
    }
  }

  private static let functionKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
    kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]
}
