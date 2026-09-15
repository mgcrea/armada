import Foundation

/// Which agent a project starts, on which account.
///
/// An account **id** rather than a `ClaudeConfigFolder` or a `CodexHome`, because this
/// is stored and those are not rebuilt from a string safely: a Claude folder's
/// `isDefault` comes from where its `.claude.json` was found, and that is what decides
/// whether a launch unsets `CLAUDE_CONFIG_DIR`. `ProjectStore.resolve` turns the id back
/// into the live account's own folder at the moment of the click.
nonisolated enum ProjectAgent: Hashable, Sendable {
  case claude(accountID: String)
  case codex(homeID: String)

  var accountID: String {
    switch self {
    case .claude(let id): id
    case .codex(let id): id
    }
  }

  var vendorName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }
}

/// A folder the person saved, to start sessions in and to see what has been spent there.
///
/// **The id is minted, not the path.** A project can be renamed and pointed at a folder
/// that moved, and the sidebar's remembered selection and any MCP client holding the id
/// should follow it through both.
nonisolated struct Project: Identifiable, Hashable, Sendable {
  let id: String
  /// Normalised by `ProjectPath.normalize`: no trailing slash.
  var path: String
  /// Nil means "the folder's name", which is what nearly every project is called.
  var name: String?
  var agent: ProjectAgent
  let addedAt: Date

  var displayName: String {
    if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
  }

  var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

  var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// `projects.json`, the saved list.
///
/// **Short keys and unescaped slashes**, like `usage-history.json`: it is small, and
/// being able to read it in a text editor is worth more than the bytes. **Versioned, and
/// strict about it**: a file written by a newer build is refused rather than read as an
/// empty list, because the store would then write that empty list back over it.
nonisolated enum ProjectsFile {
  static let version = 1

  enum DecodeError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case unknownAgent(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedVersion(let version):
        "projects.json is version \(version); this build reads version \(ProjectsFile.version)."
      case .unknownAgent(let agent):
        "projects.json names an agent this build does not know: \(agent)."
      }
    }
  }

  private struct File: Codable {
    var v: Int
    var projects: [Entry]
  }

  /// `p` path, `n` name, `g` agent (`claude` / `codex`), `a` account id, `t` added at.
  private struct Entry: Codable {
    let id: String
    let p: String
    let n: String?
    let g: String
    let a: String
    let t: Date
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  static func encode(_ projects: [Project]) throws -> Data {
    let entries = projects.map { project in
      let agent: String
      switch project.agent {
      case .claude: agent = "claude"
      case .codex: agent = "codex"
      }
      return Entry(
        id: project.id, p: project.path, n: project.name, g: agent, a: project.agent.accountID,
        t: project.addedAt)
    }
    return try encoder.encode(File(v: version, projects: entries))
  }

  static func decode(_ data: Data) throws -> [Project] {
    let file = try decoder.decode(File.self, from: data)
    guard file.v == version else { throw DecodeError.unsupportedVersion(file.v) }
    return try file.projects.map { entry in
      let agent: ProjectAgent
      switch entry.g {
      case "claude": agent = .claude(accountID: entry.a)
      case "codex": agent = .codex(homeID: entry.a)
      default: throw DecodeError.unknownAgent(entry.g)
      }
      return Project(id: entry.id, path: entry.p, name: entry.n, agent: agent, addedAt: entry.t)
    }
  }
}
