import MCPKitLoopback
import MCPKitUI
import MCPKitWiring
import SwiftUI

/// The supervisor's MCP server in the main window's toolbar: swift-mcp-kit's button, fed from
/// Settings ▸ Supervisor's switch, the entitlement and the controller. The server is otherwise
/// a pane deep in Settings, where nobody who does not already know it is there looks.
///
/// Its setup is Armada's own client rows rather than the kit's copy-and-paste: Armada is not
/// sandboxed, so it writes the server into each client's config itself (`MCPClientWiring`).
struct MCPToolbarItem: View {
  @AppStorage(MCPServerController.enabledKey) private var enabled = false
  @AppStorage(MCPServerController.allowWritesKey) private var allowWrites = false
  @State private var controller = MCPServerController.shared
  @State private var monitor = EntitlementMonitor.shared
  @State private var wiring = MCPClientWiring.shared

  var body: some View {
    MCPToolbarButton(
      isAvailable: monitor.current.isEntitled, isEnabled: isEnabled, state: controller.state,
      activity: controller.activity,
      // Settings carries the whole list of what a write may do; this is its gist.
      access: Text(
        allowWrites
          ? "Agents can read the fleet, and start, message and close sessions."
          : "Agents can read the fleet, and start nothing. Allow writes in Settings."),
      unavailableSettingsTitle: "Licence…",
      openSettings: openSupervisor
    ) { _ in
      // Never in a capture: each row reads that client's real config on this Mac.
      if !ScreenshotMode.isEnabled {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(wiring.clients) { MCPClientRow(client: $0) }
        }
      }
    } unavailable: {
      Text("The supervisor's MCP server runs while Armada is licensed or in its trial.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The switch, which also brings the listener into line: the controller binds nothing until
  /// `sync()` is called, as Settings ▸ Supervisor does when its own copy moves.
  private var isEnabled: Binding<Bool> {
    Binding(
      get: { enabled },
      set: { newValue in
        enabled = newValue
        controller.sync()
      })
  }

  private func openSupervisor() {
    AppDelegate.shared?.showSettings(monitor.current.isEntitled ? .supervisor : .licence)
  }
}
