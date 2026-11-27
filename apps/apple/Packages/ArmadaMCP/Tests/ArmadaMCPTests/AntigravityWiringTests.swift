import ArmadaMCP
import Foundation
import MCPKitWiring
import Testing

@Suite("AntigravityWiring")
struct AntigravityWiringTests {

  private let server = WiredServer(
    key: "armada", url: "http://127.0.0.1:8790/mcp", token: "tok", backupSuffix: "armada-backup")

  private func scratchHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "armada-agy-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test("Points at ~/.gemini/config/mcp_config.json under mcpServers with no bundle id")
  func clientMetadata() throws {
    let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
    let client = AntigravityWiring.client(home: home, systemExecutables: [])

    #expect(client.id == "antigravity")
    #expect(client.displayName == "Antigravity CLI")
    #expect(
      client.configURL.path(percentEncoded: false) == "/Users/me/.gemini/config/mcp_config.json")
    #expect(client.rootKey == "mcpServers")
    #expect(client.bundleID == nil)
    #expect(client.symbol == "terminal")
  }

  @Test("~/.gemini alone does not count as Antigravity CLI being installed")
  func installationEvidence() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let client = AntigravityWiring.client(home: home, systemExecutables: [])

    // Gemini CLI shares ~/.gemini; only antigravity-cli, the binary or mcp_config.json counts.
    try FileManager.default.createDirectory(
      at: home.appending(path: ".gemini"), withIntermediateDirectories: true)
    #expect(!client.isInstalled)
    #expect(client.status(of: server) == .notInstalled)

    try FileManager.default.createDirectory(
      at: home.appending(path: ".gemini/antigravity-cli"), withIntermediateDirectories: true)
    #expect(client.isInstalled)
    #expect(client.status(of: server) == .notConfigured)
  }

  @Test("~/.local/bin/agy counts as installed before a first conversation")
  func binaryCountsAsInstalled() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let client = AntigravityWiring.client(home: home, systemExecutables: [])

    let bin = home.appending(path: ".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data().write(to: bin.appending(path: "agy"))

    #expect(client.isInstalled)
    #expect(client.status(of: server) == .notConfigured)
  }

  @Test("Configures, preserves agy mcp disable and sibling servers, rotates and removes cleanly")
  func lifecycle() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appending(path: ".gemini/config"), withIntermediateDirectories: true)
    let client = AntigravityWiring.client(home: home, systemExecutables: [])

    let original: [String: Any] = [
      "mcpServers": [
        "bastion-github": [
          "serverUrl": "http://127.0.0.1:8720/s/mgcrea/github",
          "headers": ["Authorization": "Bearer other"],
        ]
      ]
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: client.configURL)

    #expect(client.status(of: server) == .notConfigured)
    try client.configure(server)
    #expect(client.status(of: server) == .configured)

    let attrs = try FileManager.default.attributesOfItem(atPath: client.configURL.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)

    // Simulate `agy mcp disable armada`, which adds `disabled: true` beside Armada's keys.
    var disabledDoc = try WiringFile.readJSON(client.configURL)
    var servers = try #require(disabledDoc["mcpServers"] as? [String: Any])
    var entry = try #require(servers["armada"] as? [String: Any])
    entry["disabled"] = true
    servers["armada"] = entry
    disabledDoc["mcpServers"] = servers
    try JSONSerialization.data(withJSONObject: disabledDoc).write(to: client.configURL)

    // Still ours and current; rotating the token updates the header and keeps `disabled: true`.
    #expect(client.status(of: server) == .configured)
    let rotated = WiredServer(
      key: "armada", url: server.url, token: "new-tok", backupSuffix: "armada-backup")
    #expect(client.status(of: rotated) == .stale(server.url))
    try client.configure(rotated)
    #expect(client.status(of: rotated) == .configured)

    let afterRotate = try WiringFile.readJSON(client.configURL)
    let rotatedServers = try #require(afterRotate["mcpServers"] as? [String: Any])
    let rotatedEntry = try #require(rotatedServers["armada"] as? [String: Any])
    #expect(rotatedEntry["disabled"] as? Bool == true)
    #expect(rotatedServers["bastion-github"] != nil)

    try client.unwire(rotated)
    #expect(client.status(of: rotated) == .notConfigured)
    let afterUnwire = try WiringFile.readJSON(client.configURL)
    #expect(NSDictionary(dictionary: afterUnwire).isEqual(to: original))
  }

  @Test("A hand-added agy serverUrl entry under armada is treated as taken until forced")
  func refusesHandAddedServerUrlEntry() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appending(path: ".gemini/config"), withIntermediateDirectories: true)
    let client = AntigravityWiring.client(home: home, systemExecutables: [])

    let handAdded =
      #"{"mcpServers":{"armada":{"serverUrl":"https://example.com/mcp"}}}"#
    try Data(handAdded.utf8).write(to: client.configURL)

    #expect(client.status(of: server) == .taken(nil))
    #expect(throws: WiringError.taken(client: "Antigravity CLI", key: "armada")) {
      try client.configure(server)
    }

    try client.configure(server, force: true)
    #expect(client.status(of: server) == .configured)
  }
}
