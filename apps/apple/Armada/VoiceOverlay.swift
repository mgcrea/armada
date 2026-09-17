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
/// - `ignoresMouseEvents`, so a click lands on whatever is underneath. Lifted only once the
///   reply has finished arriving, so the card can copy it or open the Voice pane, and then
///   the panel is cut down to the card, so the empty part below it still lets clicks through.
///   Clicking a panel that cannot become key still does not take the keyboard.
/// - `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`, so it follows you across Spaces.
/// - `sharingType = .none`, so a screenshot or a screen share never contains your question.
///
/// A fixed, mostly transparent panel with the card drawn at its top rather than a panel that
/// resizes to its content: a window that grows from its bottom-left corner would move the card
/// every time a line of the answer arrived. It is cut down once, when the reply is finished and
/// no line is left to arrive, and with its top edge held where it was.
@MainActor
final class VoiceOverlay {
  private var panel: NSPanel?
  static let size = NSSize(width: 480, height: 190)
  /// Below the card, for its shadow.
  static let shadowRoom: CGFloat = 20
  /// The card's own height, top padding included, as it last laid out.
  private var cardHeight: CGFloat = size.height
  private var interactive = false

  /// Whether the card takes clicks. See the type's notes for when.
  func setInteractive(_ on: Bool) {
    guard on != interactive else { return }
    interactive = on
    guard let panel else { return }
    panel.ignoresMouseEvents = !on
    let height = on ? min(Self.size.height, cardHeight + Self.shadowRoom) : Self.size.height
    let top = panel.frame.maxY
    panel.setFrame(
      NSRect(x: panel.frame.minX, y: top - height, width: Self.size.width, height: height),
      display: true)
    if on {
      // Tracking areas report a crossing, and the pointer may already be resting on the card.
      (panel.contentView as? VoiceCardHostingView)?.pointerMoved(
        onCard: NSMouseInRect(NSEvent.mouseLocation, panel.frame, false))
    }
  }

  func show(voice: VoiceController) {
    let panel = panel ?? make(voice: voice)
    self.panel = panel
    guard !panel.isVisible else { return }
    place(panel)
    panel.ignoresMouseEvents = !interactive
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
    let card = VoiceCard(voice: voice) { [weak self] height in self?.cardHeight = height }
    panel.contentView = VoiceCardHostingView(rootView: card, voice: voice)
    return panel
  }

  /// Top centre of the display the pointer is on: the one you are looking at, which on a
  /// two-display Mac is not always the main one.
  private func place(_ panel: NSPanel) {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let height = panel.frame.height
    panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - height - 8))
  }
}

/// Clicks on the first try, and knows when the pointer is on the card.
///
/// **`acceptsFirstMouse`**: Armada is not the active app while the card is up, and without it
/// the first click on a window of an inactive app only brings that window forward. **The
/// tracking area is `.activeAlways`** for the same reason: SwiftUI's `onHover` follows the
/// key window, and this panel is never key.
private final class VoiceCardHostingView: NSHostingView<VoiceCard> {
  private let voice: VoiceController

  init(rootView: VoiceCard, voice: VoiceController) {
    self.voice = voice
    super.init(rootView: rootView)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  @available(*, unavailable)
  required init(rootView: VoiceCard) { fatalError("init(rootView:) has not been implemented") }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseEntered(with event: NSEvent) { pointerMoved(onCard: true) }

  override func mouseExited(with event: NSEvent) { pointerMoved(onCard: false) }

  func pointerMoved(onCard: Bool) { voice.pointerMoved(onCard: onCard) }
}

private struct VoiceCard: View {
  let voice: VoiceController
  let onHeight: (CGFloat) -> Void
  @State private var copied = false

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
        if let reply = voice.finishedReply {
          HStack(spacing: 2) {
            copyButton(reply)
            closeButton
          }
        }
      }
      .padding(14)
      .frame(width: VoiceOverlay.size.width - 24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(.white.opacity(0.12))
      }
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .onTapGesture {
        if voice.finishedReply != nil { voice.openConversation() }
      }
      .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
      .padding(.top, 4)
      .onGeometryChange(for: CGFloat.self, of: \.size.height) { onHeight($0) }
      Spacer(minLength: 0)
    }
    .frame(width: VoiceOverlay.size.width, height: VoiceOverlay.size.height)
  }

  private func copyButton(_ reply: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(reply, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(copied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    .accessibilityLabel(copied ? "Copied" : "Copy reply")
  }

  private var closeButton: some View {
    Button {
      voice.closeCard()
    } label: {
      Image(systemName: "xmark")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Close")
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
