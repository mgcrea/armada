import AppKit
import MCPKitLoopback
import SwiftUI

/// Settings ▸ Supervisor: the MCP server, and a Claude Code session started with it attached.
///
/// A grouped `Form` rather than `MCPKitUI.MCPServerPanel`, as Almanac chose, and for a sharper
/// reason here: that panel always draws an "Allow writes" switch, and Armada has nothing for it
/// to govern. A switch that does nothing reads as a promise that something could.
///
/// What is carried over word for word is the loopback sentence, which is a security surface,
/// and the client configuration, through `ClientSnippet`, so a client this pane tells you to
/// configure cannot drift from the one the listener serves.
struct SupervisorPane: View {
  @AppStorage(MCPServerController.enabledKey) private var enabled = false
  @AppStorage(MCPServerController.portKey) private var port = MCPServerController.defaultPort
  @State private var controller = MCPServerController.shared
  @State private var accounts = Accounts.shared
  @State private var monitor = EntitlementMonitor.shared
  @State private var launcher = NewSessionLauncher.shared

  @State private var accountID = ""
  @State private var folder = FileManager.default.homeDirectoryForCurrentUser
  @State private var snippet: ClientSnippet = .claudeCode
  @State private var tokenRevealed = false
  @State private var copied = false

  private var selectedAccount: Account? {
    accounts.account(id: accountID) ?? accounts.all.first
  }

  var body: some View {
    Form {
      serverSection
      supervisorSection
      if let port = controller.runningPort {
        connectionSection(port: port)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Supervisor")
    .onChange(of: enabled) { controller.sync() }
    .onChange(of: port) { controller.sync() }
    .newSessionFailureAlert()
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
        "Every tool is read-only. An agent connected here can see sessions, plan limits and the end of each transcript; it cannot change a session, start one, or write to a vendor's folder. The server runs only while Armada does."
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
          : "Opens \(launcher.terminal.name) with claude running in that folder on that account, connected to this server, and asks which sessions need you. It is an ordinary session on your own plan and appears in the list like any other. Its connection details are passed on its command line and in a file beside its startup script; nothing is added to your Claude configuration."
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

  // MARK: - Connecting by hand

  @ViewBuilder private func connectionSection(port: Int) -> some View {
    Section {
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
      Picker("Set up in", selection: $snippet) {
        ForEach(ClientSnippet.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      let name = NewSession.Supervisor.serverName
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
    } header: {
      Text("Connect another client")
    } footer: {
      Text(
        "Copy takes the real token, masked here or not, and it goes into a config file on this Mac. Regenerating stops every client still using the old one, including a supervisor session already running."
      )
    }
  }
}
