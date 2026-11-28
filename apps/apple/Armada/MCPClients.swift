import ArmadaMCP
import MCPKitUI
import MCPKitWiring
import SwiftUI

/// The clients Armada writes its MCP server into, and the policy for doing it unasked.
///
/// The writing itself — the merge, the TOML splice, the backup, the refusal to overwrite
/// somebody else's `armada`, the rows — is swift-mcp-kit's (`MCPClientWiring`, `MCPClientRow`).
/// What is left here is Armada's own:
///
/// **One Claude Code row per account.** Each config folder keeps its own `.claude.json`, and a
/// server added to one is invisible to every session on the others. `usageJSON` is that file
/// for both shapes of folder — beside the default one, inside a `CLAUDE_CONFIG_DIR` one — which
/// is the asymmetry `ClaudeConfigFolder` exists to record.
///
/// **Grok Build reaches the server already** when the default Claude Code folder is wired,
/// because it reads `~/.claude.json` too. Its own row writes `~/.grok/config.toml`, which
/// outranks that, so Grok stops depending on one account's file.
///
/// **Kept current unasked, in Release only.** Regenerating the token or moving the port breaks
/// every client still holding the old values, so `rewire()` updates each config that already
/// holds an entry of ours, and never one that has none. A Debug build keeps its own Keychain
/// token — the item is per bundle identifier — while sharing every client config with the
/// installed app, so rewiring from it would point the real clients at a token the installed
/// Armada does not have. `-autoWireClients YES` turns it on for a developer exercising the path;
/// pressing Configure works in both builds, because that one is somebody asking.
extension MCPClientWiring {
  static let shared = MCPClientWiring(
    appName: "Armada", key: NewSession.Supervisor.serverName, backupSuffix: "armada-backup",
    autoRewires: autoWires, subsystem: "io.mgcrea.armada", clients: { armadaClients },
    // The stored port rather than the bound one, so the address matches the listener the switch
    // will start.
    url: { "http://127.0.0.1:\(MCPServerController.port)/mcp" },
    token: { MCPServerController.shared.token },
    tokenProblem: { MCPServerController.shared.tokenError })

  /// Every Claude account Armada watches, then whichever other clients are installed. Claude
  /// Desktop, LM Studio and Windsurf take a command only, and Armada ships no bridge.
  private static var armadaClients: [WiringClient] {
    let accounts = Accounts.shared.all
    let claude = accounts.map { account in
      WiringClient.claudeCode(
        configURL: account.folder.usageJSON, evidence: [account.folder.base],
        id: "claude-code:\(account.id)",
        displayName: accounts.count > 1 ? "Claude Code · \(account.displayName)" : "Claude Code")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let others: [WiringClient] = [
      .codex(home: home), .grok(home: home), .antigravity(home: home), .cursor(home: home),
      .visualStudioCode(home: home),
    ]
    return claude + others.filter(\.isInstalled)
  }

  private static var autoWires: Bool {
    if let override = UserDefaults.standard.object(forKey: "autoWireClients") as? Bool {
      return override
    }
    #if DEBUG
      return false
    #else
      return true
    #endif
  }
}

/// The kit's row, with the icons Armada draws for its own vendors: the terminal programs have no
/// app bundle for the kit to ask LaunchServices about.
struct ArmadaClientRow: View {
  let client: WiringClient

  var body: some View {
    MCPClientRow(client: client, wiring: .shared) { icon }
  }

  @ViewBuilder private var icon: some View {
    switch client.id {
    case let id where id.hasPrefix("claude-code"): ClaudeIconView(size: 20)
    case "codex": CodexIconView(size: 20)
    case "grok": GrokIconView(size: 20)
    case "antigravity": AntigravityIconView(size: 20)
    default: MCPClientIcon(client: client)
    }
  }
}
