import MCPKitWiring
import SwiftUI

/// One MCP client in Settings ▸ Supervisor: what its config says about Armada, and the button
/// that changes it.
///
/// The status is read off the client's file on every redraw rather than kept — see
/// `MCPClientWiring.status(of:)` — so the row cannot go on showing an answer that Armada's own
/// last write has since contradicted.
struct MCPClientRow: View {
  let client: WiringClient

  @State private var wiring = MCPClientWiring.shared
  @State private var failure: String?
  @State private var confirmsReplace = false

  private var key: String { NewSession.Supervisor.serverName }

  var body: some View {
    let status = wiring.status(of: client)
    LabeledContent {
      HStack(spacing: 8) { actions(for: status) }
    } label: {
      HStack(spacing: 8) {
        icon
        VStack(alignment: .leading, spacing: 2) {
          Text(client.displayName)
          Text(summary(of: status))
            .font(.caption)
            .foregroundStyle(tint(of: status))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
    .help(
      client.note
        ?? (client.configURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    )
    .contextMenu {
      Button("Reveal in Finder") { wiring.reveal(client) }
    }
    .alert("Replace the existing “\(key)” entry?", isPresented: $confirmsReplace) {
      Button("Replace", role: .destructive) {
        perform { try wiring.configure(client, force: true) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "\(client.displayName) already has a server named \(key) that Armada did not add. Replacing it removes that server from \(client.displayName). The previous file is kept beside it with an .armada-backup suffix."
      )
    }
    .alert(
      "Couldn't change \(client.displayName)",
      isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(failure ?? "")
    }
  }

  @ViewBuilder private func actions(for status: WiringStatus) -> some View {
    switch status {
    case .notConfigured:
      Button("Configure") { perform { try wiring.configure(client) } }
        .disabled(wiring.server == nil)
    case .configured:
      Button("Remove") { perform { try wiring.remove(client) } }
    case .stale:
      Button("Update") { perform { try wiring.configure(client) } }
        .disabled(wiring.server == nil)
      Button("Remove") { perform { try wiring.remove(client) } }
    case .taken:
      Button("Replace…") { confirmsReplace = true }
        .disabled(wiring.server == nil)
    case .unreadable, .notInstalled:
      Button("Reveal") { wiring.reveal(client) }
    }
  }

  /// Claude Code has no app of its own, so its rows borrow the Claude icon the sidebar uses.
  @ViewBuilder private var icon: some View {
    Group {
      if client.id.hasPrefix("claude-code") {
        ClaudeIconView(size: 20)
      } else if let bundleID = client.bundleID, let image = VendorIcon.image(bundleID: bundleID) {
        Image(nsImage: image).resizable()
      } else {
        Image(systemName: client.symbol).foregroundStyle(.secondary)
      }
    }
    .frame(width: 20, height: 20)
  }

  private func summary(of status: WiringStatus) -> String {
    switch status {
    case .notInstalled: "Not installed"
    case .notConfigured: "Not configured"
    case .configured: "Configured"
    case .stale: "Configured with an old port or token"
    case .taken(let found): "Another server is named \(key)" + (found.map { ": \($0)" } ?? "")
    case .unreadable(let why): why
    }
  }

  private func tint(of status: WiringStatus) -> Color {
    switch status {
    case .configured: .green
    case .stale, .taken: .orange
    case .unreadable: .red
    case .notInstalled, .notConfigured: .secondary
    }
  }

  private func perform(_ change: () throws -> Void) {
    do { try change() } catch { failure = error.localizedDescription }
  }
}
