import Foundation
import MCPKitLoopback
import MCPKitUI
import SwiftUI

/// The supervisor's MCP server on the menu bar panel: its light and one line, while it is
/// switched on.
///
/// **Here and not on the glyph.** The menu bar label is one template image, so it can carry no
/// colour, and a dot composed over it is never drawn (`MenuBarLabel`); the glyph's three rungs
/// and the starred figure already say what the sessions are doing. The panel is an ordinary
/// window, so the light keeps the colour it has on the main window's toolbar button, and means
/// the same: green while the server listens, pulsing for a minute after a request, orange when a
/// request was turned away for its token, red when the listener failed.
///
/// Nothing while the server is off or the entitlement refuses it: the server is opt-in, and a
/// row about something nobody switched on is the panel's summary spent on chrome. Nothing in a
/// capture either, where whether the server runs on this Mac must not change the plate.
struct MCPPanelRow: View {
  /// The panel's clock, so "2 minutes ago" moves with the rest of the panel and a capture
  /// draws at `AppClock`'s pinned time.
  let now: Date

  @AppStorage(MCPServerController.enabledKey) private var enabled = false
  @State private var controller = MCPServerController.shared
  @State private var monitor = EntitlementMonitor.shared

  var body: some View {
    let status = MCPStatus(
      isAvailable: monitor.current.isEntitled, isEnabled: enabled, state: controller.state,
      activity: controller.activity, now: now)
    if Self.shows(status), !ScreenshotMode.isEnabled {
      Divider()
      PanelRow(help: "Open Settings ▸ Supervisor") {
        MenuBarPanel.dismiss()
        AppDelegate.shared?.showSettings(.supervisor)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(status.tint ?? .secondary)
            .symbolEffect(.pulse, isActive: status.isWorking)
          Text(line(status))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
        }
      }
      .accessibilityLabel(Text(status.summary))
    }
  }

  static func shows(_ status: MCPStatus) -> Bool {
    switch status {
    case .unavailable, .off: false
    case .starting, .listening, .working, .turnedAway, .failed: true
    }
  }

  private func line(_ status: MCPStatus) -> String {
    switch status {
    case .unavailable, .off: ""
    case .starting: "MCP server · starting"
    case .working: "MCP server · an agent is using it"
    case .listening:
      if let served = controller.activity.lastServed {
        "MCP server · last request \(Self.relative.localizedString(for: served, relativeTo: now))"
      } else {
        "MCP server · no request yet"
      }
    case .turnedAway: "MCP server · an agent was turned away for its token"
    case .failed(let message): "MCP server · \(message)"
    }
  }

  /// Relative to the panel's `now` rather than the system clock, which `Date.formatted` reads.
  private static let relative: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()
}
