import Darwin
import Foundation
import os

/// The saved projects, and the one place they change.
///
/// **Loaded whatever the licence says**, before the entitlement gate runs: a project is
/// something the person made, not something the watchers found, and it should still be
/// there when a trial lapses and a key is entered. What a project *shows* stays behind
/// the gate with every other pane.
///
/// Persisted to `projects.json` under `AppInfo.supportDirectory`, beside
/// `usage-history.json` and on the same terms: encoded on the main actor, written off it,
/// and never inside `~/.claude` or `~/.codex`.
@MainActor
@Observable
final class ProjectStore {
  static let shared = ProjectStore()

  static let fileName = "projects.json"

  /// By name, then path, which is the sidebar's order.
  private(set) var projects: [Project] = []

  /// Every spelling of each project's folder: the saved path, and the path with its
  /// symlinks resolved when that differs.
  ///
  /// **Both, because the two ends of a match come from different places.** Claude Code
  /// records a session's resolved `cwd`, while the open panel hands back whatever path
  /// the person navigated. Resolved here once per change rather than per match: it is
  /// a system call, and the sidebar matches every live session on every redraw.
  ///
  /// `realpath(3)` rather than `resolvingSymlinksInPath`, which also strips a leading
  /// `/private` and so turns the `/private/tmp` Claude Code records into a `/tmp` that
  /// matches nothing.
  @ObservationIgnored private var matchKeys: [String: [String]] = [:]

  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let writer = ProjectsFileWriter()

  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "projects")

  private init() {}

  var fileURL: URL? { AppInfo.supportDirectory?.appending(path: Self.fileName) }

  /// Read the saved list.
  ///
  /// **A file this build cannot read is moved aside, never overwritten.** Starting empty
  /// and saving would replace a newer build's list with nothing the first time someone
  /// adds a project here.
  func load() {
    guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
    do {
      set(try ProjectsFile.decode(data), persist: false)
    } catch {
      let stamp = Int(Date.now.timeIntervalSince1970)
      let aside = url.deletingLastPathComponent().appending(path: "\(Self.fileName).bak-\(stamp)")
      try? FileManager.default.moveItem(at: url, to: aside)
      Self.logger.error(
        "projects.json unreadable, moved aside: \(error.localizedDescription, privacy: .public)")
    }
  }

  func project(id: String) -> Project? { projects.first { $0.id == id } }

  /// Every project, as `ProjectPath.deepest` takes them.
  var candidates: [ProjectPath.Candidate] {
    projects.map { ProjectPath.Candidate(id: $0.id, keys: matchKeys[$0.id] ?? [$0.path]) }
  }

  /// The project a folder belongs to: itself or the deepest one above it.
  func project(containing cwd: String) -> Project? {
    guard !cwd.isEmpty, let id = ProjectPath.deepest(for: cwd, in: candidates) else { return nil }
    return project(id: id)
  }

  /// The project saved on exactly this folder, under any spelling of it. Not one above it,
  /// which is `project(containing:)`.
  func project(at raw: String) -> Project? {
    let spellings = Self.keys(for: ProjectPath.normalize(raw))
    return projects.first { project in
      let keys = matchKeys[project.id] ?? [project.path]
      return spellings.contains { keys.contains($0) }
    }
  }

  /// Save a folder as a project, or return the one that already is.
  ///
  /// Nil for the root and for anything that is not an absolute path: a project on `/`
  /// would contain every session on the Mac, which is what the account panes already are.
  @discardableResult
  func add(path raw: String, agent: ProjectAgent) -> Project? {
    let path = ProjectPath.normalize(raw)
    guard path.hasPrefix("/"), path != "/" else { return nil }
    if let existing = project(at: path) { return existing }
    // To the whole second, so the value read back from the file compares equal to it.
    let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    let project = Project(
      id: UUID().uuidString, path: path, name: nil, agent: agent, addedAt: now)
    set(projects + [project])
    return project
  }

  func remove(id: String) {
    set(projects.filter { $0.id != id })
  }

  /// An empty name goes back to the folder's.
  func rename(id: String, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    update(id) { $0.name = trimmed.isEmpty ? nil : trimmed }
  }

  func setAgent(id: String, _ agent: ProjectAgent) {
    update(id) { $0.agent = agent }
  }

  /// Point a project at a folder that moved, keeping its id and everything keyed on it.
  func relocate(id: String, to raw: String) {
    let path = ProjectPath.normalize(raw)
    guard path.hasPrefix("/"), path != "/" else { return }
    update(id) { $0.path = path }
  }

  /// The live account behind a stored agent, or nil when it is not on this Mac.
  ///
  /// **Always the account's own folder, never one rebuilt from the id.** A
  /// `ClaudeConfigFolder` knows whether it is the default folder from where its
  /// `.claude.json` was found, and that is what makes the launch script unset
  /// `CLAUDE_CONFIG_DIR` rather than export it — see `NewSession`.
  func resolve(_ agent: ProjectAgent) -> NewSession.Agent? {
    switch agent {
    case .claude(let id): Accounts.shared.account(id: id).map { .claude($0.folder) }
    case .codex(let id): CodexAccounts.shared.account(id: id).map { .codex($0.home) }
    }
  }

  /// "Personal", "Codex": what a menu calls the account an agent runs on.
  func accountName(_ agent: ProjectAgent) -> String? {
    switch agent {
    case .claude(let id): Accounts.shared.account(id: id)?.displayName
    case .codex(let id): CodexAccounts.shared.account(id: id)?.displayName
    }
  }

  /// The agent a newly added folder starts on: the first Claude account, else the first
  /// Codex home. Nil while no account is watched, which is also while Armada is locked.
  var defaultNewAgent: ProjectAgent? {
    if let account = Accounts.shared.all.first { return .claude(accountID: account.id) }
    if let home = CodexAccounts.shared.all.first { return .codex(homeID: home.id) }
    return nil
  }

  /// Folders the accounts ran in lately and that are not saved yet, newest first, each
  /// carrying the account it ran on so that is the account it will start on.
  var suggestions: [ProjectSuggestion] {
    var found: [ProjectSuggestion] = []
    for account in Accounts.shared.all {
      found += account.recentProjects.map {
        ProjectSuggestion(recent: $0, agent: .claude(accountID: account.id))
      }
    }
    for account in CodexAccounts.shared.all {
      found += account.recentProjects.map {
        ProjectSuggestion(recent: $0, agent: .codex(homeID: account.id))
      }
    }
    var seen: Set<String> = []
    return
      found
      .sorted {
        ($0.recent.lastStartedAt ?? .distantPast) > ($1.recent.lastStartedAt ?? .distantPast)
      }
      .filter { suggestion in
        let path = ProjectPath.normalize(suggestion.recent.path)
        let saved = projects.contains { matchKeys[$0.id]?.contains(path) ?? ($0.path == path) }
        return !saved && seen.insert(path).inserted
      }
  }

  func folderExists(_ project: Project) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  // MARK: - Changing and saving

  private func update(_ id: String, _ change: (inout Project) -> Void) {
    guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
    var next = projects
    change(&next[index])
    set(next)
  }

  private func set(_ next: [Project], persist: Bool = true) {
    projects = next.sorted {
      switch $0.displayName.localizedStandardCompare($1.displayName) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: $0.path < $1.path
      }
    }
    // Keeping the first on a duplicate id, which only a hand-edited file can hold.
    matchKeys = Dictionary(
      projects.map { ($0.id, Self.keys(for: $0.path)) }, uniquingKeysWith: { first, _ in first })

    guard persist, let url = fileURL, let data = try? ProjectsFile.encode(projects) else { return }
    generation += 1
    let generation = generation
    let writer = writer
    Task { await writer.write(data, to: url, generation: generation) }
  }

  private static func keys(for path: String) -> [String] {
    guard let resolved = resolved(path), resolved != path else { return [path] }
    return [path, resolved]
  }

  nonisolated static func resolved(_ path: String) -> String? {
    guard let pointer = realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return ProjectPath.normalize(String(cString: pointer))
  }
}

/// One folder the "+" menu offers.
struct ProjectSuggestion: Identifiable {
  let recent: RecentProject
  let agent: ProjectAgent

  var id: String { recent.path }
}

/// Writes `projects.json` in order.
///
/// **Generations, because two detached writes can land out of order.** Renaming a
/// project and then removing it in quick succession must not leave the rename on disk,
/// so a write older than the newest one already written is dropped.
private actor ProjectsFileWriter {
  private var written = 0

  func write(_ data: Data, to url: URL, generation: Int) {
    guard generation > written else { return }
    written = generation
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}

extension NewSession.Agent {
  /// The stored form of this agent, for saving the account a folder ran on.
  var projectAgent: ProjectAgent {
    switch self {
    case .claude(let folder): .claude(accountID: folder.path)
    case .codex(let home): .codex(homeID: home.id)
    }
  }
}
