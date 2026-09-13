import SwiftUI

/// The Mouse pane: what the side buttons do.
///
/// **A pane rather than a section of General, and not because of its length.**
/// Everything else in Settings is a control that answers on the spot — a toggle, a
/// picker, a slider. This is a list you build, it is the only surface here that
/// takes a live event while you are looking at it (Detect), and it is the only one
/// whose setting can be on and correct and still do nothing, because the grant it
/// needs lives behind another switch. Each of those wants room to say so.
///
/// **The Accessibility row is repeated here, not moved.** It is also in General,
/// where it belongs to Focus. Two features need one grant, and a pane that sent
/// people to another pane to find out why nothing fires would be the worse of the
/// two duplications.
struct MousePane: View {
  @State private var mouse = MouseBindingsStore.shared
  @State private var trust = AccessibilityTrust.shared

  /// The binding currently waiting to be told which button it is, if any.
  @State private var capturing: UUID?

  var body: some View {
    @Bindable var mouse = mouse

    Form {
      Section {
        Toggle("Drive Armada with your mouse buttons", isOn: $mouse.isEnabled)

        if mouse.isEnabled {
          LabeledContent("Accessibility") {
            HStack(spacing: 8) {
              Text(trust.isTrusted ? "Allowed" : "Not allowed")
              Button("Open System Settings…") { HostWindow.openAccessibilitySettings() }
                .buttonStyle(.borderless)
            }
          }
          if !trust.isTrusted {
            // The failure this pane exists to make visible: the switch is on, the
            // bindings are right, and macOS is dropping the events before Armada
            // sees them. Nothing in the list below would hint at it.
            Text("Until this is allowed, nothing below will fire.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        // What Armada can see, and what it deliberately leaves alone. A permission
        // with no stated ceiling is the kind people deny — the same reasoning as the
        // Focus grant in General, and the ceiling here is genuinely narrow.
        Text(
          "Armada sees your mouse's middle and extra buttons and the modifiers held with them — never your clicks, your pointer, or your typing. A button pressed on its own is left alone, so Back and Forward keep working. Bindings do nothing while a password field has focus, because macOS hides those presses from every application."
        )
      }

      if mouse.isEnabled {
        Section {
          ForEach($mouse.bindings) { $binding in
            MouseBindingRow(
              binding: $binding,
              isCapturing: capturing == binding.id,
              onDetect: { startCapture(for: $binding) },
              onCancelDetect: cancelCapture,
              onRemove: { mouse.remove(binding) })
          }

          Button("Add a binding") { mouse.add() }
        } header: {
          Text("Bindings")
        } footer: {
          Text(
            "Sending a key is the way out to everything else: bind F13–F20 in another app's own keyboard settings — VS Code, Xcode, anything — and Armada will fire it from a button. macOS itself uses none of them, and the key arrives without the modifier you held, so bind F13 rather than a chord."
          )
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Mouse")
    // A capture left armed would keep the tap running for a button press nobody is
    // waiting for any more.
    .onDisappear(perform: cancelCapture)
  }

  private func startCapture(for binding: Binding<MouseBinding>) {
    capturing = binding.wrappedValue.id
    MouseTap.shared.beginCapture { button in
      binding.wrappedValue.button = button
      capturing = nil
    }
  }

  private func cancelCapture() {
    MouseTap.shared.cancelCapture()
    capturing = nil
  }
}

/// One binding: the trigger, what it does, and a way to delete it.
///
/// **The trigger is one menu, not two pickers side by side.** A pane is about 420pt
/// wide once the settings sidebar has taken its 240, which is not enough for a
/// modifier picker, a button picker, an action picker and a delete button on one
/// line. Folding the two trigger controls into a single menu that displays the chord
/// — "⌥ Button 4 (back)" — spends one control where two would not fit, and reads as
/// the thing it sets rather than as two halves of it.
private struct MouseBindingRow: View {
  @Binding var binding: MouseBinding
  let isCapturing: Bool
  let onDetect: () -> Void
  let onCancelDetect: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if isCapturing {
        Text("Press a button…")
          .foregroundStyle(.secondary)
          .frame(minWidth: 150, alignment: .leading)
        Button("Cancel", action: onCancelDetect)
          .buttonStyle(.borderless)
        Spacer(minLength: 0)
      } else {
        Menu {
          // Inline pickers render as checkmarked sections of the menu rather than as
          // submenus, so the whole trigger is set in one press without a hover-walk.
          Picker("Modifier", selection: $binding.modifiers) {
            ForEach(MouseModifiers.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.inline)

          Picker("Button", selection: $binding.button) {
            ForEach(MouseBinding.offeredButtons, id: \.self) {
              Text(MouseBinding.buttonLabel($0)).tag($0)
            }
            // The button this binding already uses, when it is one the list does not
            // offer — arrived at through Detect, and it has to stay selectable or
            // opening the menu would silently move it to Button 4.
            if !MouseBinding.offeredButtons.contains(binding.button) {
              Text(MouseBinding.buttonLabel(binding.button)).tag(binding.button)
            }
          }
          .pickerStyle(.inline)

          Divider()
          Button("Detect…", action: onDetect)
        } label: {
          Text(binding.label)
        }
        .frame(minWidth: 150)

        Image(systemName: "arrow.right")
          .font(.caption)
          .foregroundStyle(.tertiary)

        Picker("", selection: $binding.action) {
          Section("Armada") {
            ForEach(MouseAction.commands) { Text($0.label).tag($0) }
          }
          Section("Send a key") {
            ForEach(MouseAction.keys) { Text($0.label).tag($0) }
          }
        }
        .labelsHidden()

        Button(action: onRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove this binding")
      }
    }
  }
}
