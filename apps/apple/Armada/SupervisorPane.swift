import AppKit
import MCPKitLoopback
import SwiftUI

/// Settings ▸ Supervisor: the MCP server, and a Claude Code session started with it attached.
///
/// A grouped `Form` rather than `MCPKitUI.MCPServerPanel`, as Almanac chose. Armada's Allow writes
/// switch governs a short, specific list — starting, resuming, closing and messaging sessions — and
/// the sentence under it has to say that, which the panel's generic switch cannot. Delivering
/// messages has a switch of its own, because turning it on edits every account's settings.json.
///
/// What is carried over word for word is the loopback sentence, which is a security surface,
/// and the client configuration, through `ClientSnippet`, so a client this pane tells you to
/// configure cannot drift from the one the listener serves.
struct SupervisorPane: View {
  @AppStorage(MCPServerController.enabledKey) private var enabled = false
  @AppStorage(MCPServerController.portKey) private var port = MCPServerController.defaultPort
  @AppStorage(MCPServerController.allowWritesKey) private var allowWrites = false
  @AppStorage(MessageDelivery.enabledKey) private var deliverMessages = false
  @State private var delivery = MessageDelivery.shared
  @State private var controller = MCPServerController.shared
  @State private var accounts = Accounts.shared
  @State private var monitor = EntitlementMonitor.shared
  @State private var launcher = NewSessionLauncher.shared
  @State private var wiring = MCPClientWiring.shared

  @State private var accountID = ""
  @State private var folder = FileManager.default.homeDirectoryForCurrentUser
  @State private var snippet: ClientSnippet = .claudeCode
  @State private var tokenRevealed = false
  @State private var copied = false
  @State private var showsSnippet = false

  private var selectedAccount: Account? {
    accounts.account(id: accountID) ?? accounts.all.first
  }

  var body: some View {
    Form {
      serverSection
      supervisorSection
      // On the switch rather than on a running listener: configuring a client needs a port and
      // a token, and both exist before the socket is bound.
      if enabled {
        clientsSection
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Supervisor")
    .onChange(of: enabled) { controller.sync() }
    .onChange(of: port) { controller.sync() }
    .newSessionFailureAlert()
    .sessionClosingAlerts()
  }

  // MARK: - Server

  private var serverSection: some View {
    Section {
      Toggle(isOn: $enabled) {
        Text("Run the MCP server")
        Text(
          "Lets an AI agent on this Mac read what Armada knows about your sessions and plan limits. It listens on 127.0.0.1 only — nothing is reachable from another machine, and nothing leaves this one."
        )
      }
      if enabled {
        status
        if !monitor.current.isEntitled {
          Text(
            "Armada has no licence and no trial running, so it is watching nothing and the server stays off."
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
      Toggle(isOn: $allowWrites) {
        Text("Allow writes")
        Text(
          "Lets a connected agent start a fresh Claude Code or Codex session in one of your saved projects, in \(VSCodeLaunch.isChosen ? "\(launcher.terminal.name), or \(VSCodeLaunch.name) for Claude Code," : launcher.terminal.name), optionally with an opening message; resume a closed Claude Code session there; close a Claude Code session, a busy one only when it passes force; and message a session, once delivery is on below. A session it starts asks you for every permission as usual."
        )
      }
      .disabled(!enabled)
      Toggle(isOn: $deliverMessages) {
        Text("Deliver messages to sessions")
        Text(
          "Adds one hook to each Claude Code account's settings.json, so armada_send_message can put a message in front of a running session: an idle one starts a turn on it, a busy one reads it when its turn ends. The session sees it labelled as coming from an agent, not from you. Turning this off removes that hook and nothing else. Codex sessions cannot be reached."
        )
      }
      .disabled(!enabled || !allowWrites)
      .onChange(of: deliverMessages) { delivery.sync() }
      if deliverMessages {
        ForEach(delivery.accounts) { account in
          switch account.state {
          case .installed:
            Label("\(account.name): hook installed", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          case .removed:
            Label("\(account.name): hook not installed", systemImage: "circle")
              .foregroundStyle(.secondary)
          case .failed(let reason):
            Label("\(account.name): \(reason)", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption)
      }
      if let tokenError = controller.tokenError {
        Text(tokenError)
          .font(.caption)
          .foregroundStyle(.orange)
      }
      LabeledContent("Port") {
        TextField("Port", value: $port, format: .number.grouping(.never))
          .labelsHidden()
          .frame(width: 90)
          // Changing the port under a live listener would leave clients pointed at a socket
          // that is no longer there, with nothing on screen saying so.
          .disabled(controller.runningPort != nil)
      }
      if !(1024...65_535).contains(port) {
        Text(
          "Ports below 1024 need privileges Armada does not have, so it uses \(String(MCPServerController.defaultPort))."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("Server")
    } footer: {
      // Says what the tools cannot do, because "an agent can read my sessions" is the sentence
      // someone will stop on, and the answer to "and then what" is the reassurance.
      Text(
        allowWrites
          ? "An agent connected here can see sessions, projects, plan limits and the end of each transcript, and wait for a session to need you. armada_start_session can open or resume a session in a saved project, armada_close_session can end a Claude Code session, and armada_send_message can message one while delivery is on. None of them answers a permission prompt for you. A client already connected sees the change once it reconnects. The server runs only while Armada does."
          : "Every tool is read-only. An agent connected here can see sessions, projects, plan limits and the end of each transcript; it cannot change a session, start one, or write to a vendor's folder. The server runs only while Armada does."
      )
    }
  }

  @ViewBuilder private var status: some View {
    switch controller.state {
    case .running(let boundPort):
      // `String(boundPort)`, not the `Int`: interpolated into a `LocalizedStringKey`, an `Int`
      // gets the locale's grouping separator, and 8790 becomes a port nobody can copy.
      Label("Listening on 127.0.0.1:\(String(boundPort))", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .stopped:
      Label("Not running", systemImage: "circle")
        .foregroundStyle(.secondary)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }

  // MARK: - Supervisor session

  private var supervisorSection: some View {
    Section {
      if accounts.all.isEmpty {
        Text("No Claude account found").foregroundStyle(.secondary)
      } else {
        Picker(
          "Account",
          selection: Binding(
            get: { selectedAccount?.id ?? "" },
            set: { accountID = $0 })
        ) {
          ForEach(accounts.all) { account in
            Text(account.displayName).tag(account.id)
          }
        }
        LabeledContent("Folder") {
          HStack(spacing: 6) {
            Text(
              (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            )
            .truncationMode(.head)
            .lineLimit(1)
            Button("Choose…", action: chooseFolder)
              .buttonStyle(.borderless)
          }
        }
        Button("Start Supervisor Session") {
          guard let account = selectedAccount else { return }
          launcher.startSupervisor(on: account.folder, in: folder)
        }
        .disabled(controller.runningPort == nil)
      }
    } header: {
      Text("Supervisor session")
    } footer: {
      Text(
        controller.runningPort == nil
          ? "Turn the server on to start a Claude Code session that can see every session on this Mac."
          : "Opens \(launcher.terminal.name) with claude running in that folder on that account, connected to this server, and asks which sessions need you. It is an ordinary session on your own plan and appears in the list like any other. Its connection details are passed on its command line and in a file beside its startup script; nothing is added to your Claude configuration. Its read tools are pre-allowed; starting a session is not, so it asks you first."
      )
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder
    panel.prompt = "Choose"
    panel.message = "Choose the folder the supervisor session runs in."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    folder = url
  }

  // MARK: - Clients

  /// One row per client Armada can configure, then the token and, folded away, the snippet for
  /// any client that is not on the list.
  @ViewBuilder private var clientsSection: some View {
    Section {
      ForEach(wiring.clients) { client in
        MCPClientRow(client: client)
      }
      LabeledContent("Token") {
        HStack(spacing: 8) {
          Text(tokenRevealed ? controller.token : String(repeating: "•", count: 24))
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
          Button(tokenRevealed ? "Hide" : "Reveal") { tokenRevealed.toggle() }
            .buttonStyle(.borderless)
          Button("Regenerate", action: controller.regenerateToken)
            .buttonStyle(.borderless)
        }
      }
      DisclosureGroup("Set up another client by hand", isExpanded: $showsSnippet) {
        Picker("Set up in", selection: $snippet) {
          ForEach(ClientSnippet.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        let name = NewSession.Supervisor.serverName
        let port = MCPServerController.port
        let text = snippet.text(serverName: name, port: port, token: controller.token)
        // Drawn masked while the token is masked, and copied whole either way — a bulleted
        // token one row up and the same token in clear one row down would make Reveal a button
        // that reveals nothing.
        let shown =
          tokenRevealed
          ? text
          : snippet.text(serverName: name, port: port, token: String(repeating: "•", count: 24))
        ScrollView(.horizontal) {
          Text(shown)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
        HStack {
          Spacer()
          Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
          }
          .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
          }
        }
      }
    } header: {
      Text("Clients")
    } footer: {
      Text(
        "Configure adds an \(NewSession.Supervisor.serverName) entry to that client's own config, with this server's address and token, and leaves the rest of the file as it was. The previous file is kept beside it with an .armada-backup suffix, and Remove takes out that entry and nothing else. Regenerating the token or changing the port updates every client configured here; one already running picks the change up when it reconnects. A supervisor session already running keeps the token it started with."
      )
    }
  }
}
