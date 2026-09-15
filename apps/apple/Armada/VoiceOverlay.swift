import AppKit
import ArmadaSupervisor
import SwiftUI

/// The card at the top of the screen while you talk to Armada.
///
/// **It never takes the keyboard.** You press the shortcut while typing somewhere else, and the
/// answer arrives while you go on typing, so a panel that became key would take your next
/// keystroke. The rules are Cupertino's `DrivingOverlay`, where the same constraint was measured
/// against a live frontmost application:
///
/// - `.nonactivatingPanel` and `orderFrontRegardless()`, never `makeKeyAndOrderFront`.
/// - `.screenSaver` level, above normal and full-screen windows.
/// - `ignoresMouseEvents`, so a click lands on whatever is underneath.
/// - `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`, so it follows you across Spaces.
/// - `sharingType = .none`, so a screenshot or a screen share never contains your question.
///
/// A fixed, mostly transparent panel with the card drawn at its top rather than a panel that
/// resizes to its content: a window that grows from its bottom-left corner would move the card
/// every time a line of the answer arrived.
@MainActor
final class VoiceOverlay {
  private var panel: NSPanel?
  static let size = NSSize(width: 480, height: 190)

  func show(voice: VoiceController) {
    let panel = panel ?? make(voice: voice)
    self.panel = panel
    guard !panel.isVisible else { return }
    place(panel)
    panel.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func make(voice: VoiceController) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.sharingType = .none
    panel.contentView = NSHostingView(rootView: VoiceCard(voice: voice))
    return panel
  }

  /// Top centre of the display the pointer is on: the one you are looking at, which on a
  /// two-display Mac is not always the main one.
  private func place(_ panel: NSPanel) {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    panel.setFrameOrigin(
      NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 8))
  }
}

private struct VoiceCard: View {
  let voice: VoiceController

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        symbol
          .font(.title2)
          .frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(voice.headline)
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .truncationMode(.head)
          if let detail = voice.detail {
            Text(detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(4)
              .truncationMode(.head)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(14)
      .frame(width: VoiceOverlay.size.width - 24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(.white.opacity(0.12))
      }
      .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
      .padding(.top, 4)
      Spacer(minLength: 0)
    }
    .frame(width: VoiceOverlay.size.width, height: VoiceOverlay.size.height)
  }

  @ViewBuilder private var symbol: some View {
    switch voice.turn.phase {
    case .listening:
      Image(systemName: "waveform")
        .symbolEffect(.variableColor.iterative, isActive: voice.level > -45)
        .foregroundStyle(.tint)
    case .thinking:
      ProgressView().controlSize(.small)
    case .answering:
      Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .idle:
      Image(systemName: "waveform").foregroundStyle(.secondary)
    }
  }
}
