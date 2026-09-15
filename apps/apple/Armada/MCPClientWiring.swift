import AppKit
import MCPKitWiring
import Observation
import os

/// Writes Armada's MCP server into the clients installed on this Mac, and takes it back out.
///
/// The step between "the server is on" and "an agent can reach it". Settings used to hand over
/// a `claude mcp add` line with the token in clear, to paste into a terminal. Everything about
/// touching another application's file — the merge, the Codex TOML splice, the backup, the
/// refusal to overwrite somebody else's `armada` — is `MCPKitWiring`'s, shared with the other
/// apps on the kit. What is left here is policy: which clients, which address, and when a
/// config may be rewritten without anyone pressing a button.
///
/// **One Claude Code row per account.** Each config folder keeps its own `.claude.json`, and a
/// server added to one is invisible to every session on the others. `usageJSON` is that file
/// for both shapes of folder — beside the default one, inside a `CLAUDE_CONFIG_DIR` one — which
/// is the asymmetry `ClaudeConfigFolder` exists to record.
///
/// **Kept current unasked, in Release only.** Regenerating the token or moving the port breaks
/// every client still holding the old values, so `rewire()` updates each config that already
/// holds an entry of ours, and never one that has none. A Debug build keeps its own Keychain
/// token — the item is per bundle identifier — while sharing every client config with the
/// installed app, so rewiring from it would point the real clients at a token the installed
/// Armada does not have. `-autoWireClients YES` turns it on for a developer exercising the path;
/// pressing Configure works in both builds, because that one is somebody asking.
@MainActor
@Observable
final class MCPClientWiring {
  static let shared = MCPClientWiring()

  /// Bumped on every write Armada makes. Statuses are read off disk on every call and cached
  /// nowhere, so this is the only way a view reading one learns the file changed. A config
  /// rewritten by its own client bumps nothing; the row keeps its answer until the next redraw.
  private(set) var revision = 0

  @ObservationIgnored private let logger = Logger(
    subsystem: "io.mgcrea.armada", category: "wiring")

  private init() {}

  /// Every Claude account Armada watches, then whichever other clients are installed.
  var clients: [WiringClient] {
    let accounts = Accounts.shared.all
    let claude = accounts.map { account in
      WiringClient.claudeCode(
        configURL: account.folder.usageJSON, evidence: [account.folder.base],
        id: "claude-code:\(account.id)",
        displayName: accounts.count > 1 ? "Claude Code · \(account.displayName)" : "Claude Code")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let others: [WiringClient] = [
      .codex(home: home), .cursor(home: home), .visualStudioCode(home: home),
    ]
    return claude + others.filter(\.isInstalled)
  }

  /// The entry as it should read now.
  ///
  /// The stored port rather than the bound one, so the address matches the listener the switch
  /// will start. `nil` when the Keychain refused the token: an entry without one would reach the
  /// server and be turned away at the door.
  var server: WiredServer? {
    let token = MCPServerController.shared.token
    guard !token.isEmpty else { return nil }
    return WiredServer(
      key: NewSession.Supervisor.serverName,
      url: "http://127.0.0.1:\(MCPServerController.port)/mcp", token: token,
      backupSuffix: "armada-backup")
  }

  func status(of client: WiringClient) -> WiringStatus {
    // Read so a view calling this redraws after a write; the answer itself comes off disk.
    _ = revision
    guard let server else {
      return .unreadable(MCPServerController.shared.tokenError ?? Unavailable.noToken.message)
    }
    return client.status(of: server)
  }

  func configure(_ client: WiringClient, force: Bool = false) throws {
    guard let server else { throw Unavailable.noToken }
    try client.configure(server, force: force)
    revision += 1
    logger.info("configured \(client.displayName, privacy: .public)")
  }

  /// Needs no token: ownership is the key and a loopback URL, so an entry can be taken out
  /// even while the Keychain is refusing to say what the token is.
  func remove(_ client: WiringClient) throws {
    let key = NewSession.Supervisor.serverName
    try client.unwire(
      server ?? WiredServer(key: key, url: "", token: "", backupSuffix: "armada-backup"))
    revision += 1
    logger.info("removed armada from \(client.displayName, privacy: .public)")
  }

  /// The config itself, or the folder it will be written in when there is none yet.
  func reveal(_ client: WiringClient) {
    let exists = FileManager.default.fileExists(
      atPath: client.configURL.path(percentEncoded: false))
    NSWorkspace.shared.activateFileViewerSelecting([
      exists ? client.configURL : client.configURL.deletingLastPathComponent()
    ])
  }

  /// Update every client whose entry is ours and out of date. Silent: a config that is locked
  /// or unreadable is not a reason to fail a token regeneration, so each outcome goes to the log
  /// and the Clients rows go on reporting what each file actually holds.
  func rewire() {
    guard Self.autoWires, let server else { return }
    for client in clients {
      // `stale` is only ever an entry of ours, so a client nobody configured is never touched.
      guard case .stale = client.status(of: server) else { continue }
      do {
        try client.configure(server)
        revision += 1
        logger.info("updated \(client.displayName, privacy: .public) to the current port and token")
      } catch {
        logger.error(
          "left \(client.displayName, privacy: .public) unchanged: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  static var autoWires: Bool {
    if let override = UserDefaults.standard.object(forKey: "autoWireClients") as? Bool {
      return override
    }
    #if DEBUG
      return false
    #else
      return true
    #endif
  }

  nonisolated enum Unavailable: LocalizedError {
    case noToken

    var message: String { "Armada has no token to write, because the Keychain refused it." }
    var errorDescription: String? { message }
  }
}
