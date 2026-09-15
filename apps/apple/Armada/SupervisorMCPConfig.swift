import Foundation

/// The MCP configuration a supervisor `claude` is started with, in the shape `--mcp-config`
/// reads.
///
/// Shared by the Terminal supervisor (`NewSession`) and the voice one (`VoiceController`),
/// because the bearer token is in it and the rules for writing it are the security surface:
///
/// - **Created with its permissions**, never chmodded after. A file written and then
///   restricted is readable by anyone for the moment in between.
/// - **Built with `JSONSerialization`**, never interpolated, so no value can break out of its
///   string.
/// - **A file rather than inline JSON on the command line**, so the token never appears in
///   `ps`.
nonisolated enum SupervisorMCPConfig {
  static let fileName = "armada-mcp.json"

  static func write(serverName: String, port: Int, token: String, in directory: URL) throws -> URL {
    let server: [String: Any] = [
      "type": "http",
      "url": "http://127.0.0.1:\(port)/mcp",
      "headers": ["Authorization": "Bearer \(token)"],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: ["mcpServers": [serverName: server]],
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let url = directory.appending(path: fileName, directoryHint: .notDirectory)
    guard
      FileManager.default.createFile(
        atPath: url.path(percentEncoded: false), contents: data,
        attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return url
  }
}
