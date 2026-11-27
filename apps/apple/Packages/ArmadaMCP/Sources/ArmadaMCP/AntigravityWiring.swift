import Foundation
import MCPKitWiring

/// Antigravity CLI (`agy`) as a `WiringClient`, until `swift-mcp-kit` adds it to its catalog.
///
/// `agy mcp add` writes `~/.gemini/config/mcp_config.json` under `mcpServers` using Windsurf's
/// `serverUrl` + `headers` shape, but `agy 1.5.18` reads `type`/`url`/`headers` just as well: a
/// loopback probe in Bastion saw `Authorization: Bearer …` on `initialize` and `tools/list` from
/// both shapes. `agy mcp disable` adds `disabled: true` beside the entry's keys, which
/// `WiringMerge` preserves on subsequent rewires.
public enum AntigravityWiring {

  /// The Antigravity CLI client rooted at `home`.
  ///
  /// Evidence mirrors `AntigravityHome.executable()` plus `~/.gemini/antigravity-cli` — never
  /// `~/.gemini`, which is shared with Gemini CLI. No `bundleID`: the Antigravity IDE is a
  /// separate application, and nothing yet says it reads this file.
  public static func client(
    home: URL,
    systemExecutables: [URL] = [
      URL(filePath: "/opt/homebrew/bin/agy"),
      URL(filePath: "/usr/local/bin/agy"),
    ]
  ) -> WiringClient {
    WiringClient(
      id: "antigravity",
      displayName: "Antigravity CLI",
      configURL: home.appending(path: ".gemini/config/mcp_config.json"),
      format: .json(rootKey: "mcpServers"),
      bundleID: nil,
      evidence: [
        home.appending(path: ".gemini/antigravity-cli"),
        home.appending(path: ".local/bin/agy"),
      ] + systemExecutables,
      symbol: "terminal")
  }
}
