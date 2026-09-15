import AppKit
import SwiftUI

/// A live session inside a project, from either vendor.
///
/// **Live only.** The Claude registry holds live sessions already; a Codex home's list
/// also carries the last 12 hours of ended ones, and a project pane that listed those
/// under "Live sessions" would be claiming work that stopped this morning.
@MainActor
struct ProjectSession: Identifiable {
  enum Source {
    case claude(Session, Account)
    case codex(CodexSession, CodexAccount)
  }

  let source: Source

  var id: String {
    switch source {
    case .claude(let session, _): "claude:" + session.id
    case .codex(let session, _): "codex:" + session.id
    }
  }

  var displayName: String {
    switch source {
    case .claude(let session, _): session.displayName
    case .codex(let session, _): session.displayName
    }
  }

  var cwd: String {
    switch source {
    case .claude(let session, _): session.registry.cwd
    case .codex(let session, _): session.meta.cwd
    }
  }

  var accountName: String {
    switch source {
    case .claude(_, let account): account.displayName
    case .codex(_, let account): account.displayName
    }
  }

  var lastActivity: Date? {
    switch source {
    case .claude(let session, _): session.lastActivity
    case .codex(let session, _): session.lastActivity
    }
  }

  /// "Not idle" for Claude Code, as `AccountSidebarRow`'s dot counts it; Codex's own
  /// `working` for Codex.
  var isWorking: Bool {
    switch source {
    case .claude(let session, _): session.state != .idle
    case .codex(let session, _): session.state == .working
    }
  }

  /// Open the session in its own account's pane, selected.
  func open() {
    switch source {
    case .claude(let session, let account):
      MainWindowRoute.shared.open(.account(account.id), session: session.id)
    case .codex(let session, let account):
      MainWindowRoute.shared.open(.codex(account.id), session: session.id)
    }
  }

  /// Every live session whose folder belongs to `project`, most recently active first.
  ///
  /// Matched with `ProjectPath.deepest` over every saved project rather than a plain
  /// containment test, so a session in a nested project is counted there and not here.
  static func live(in project: Project, store: ProjectStore = .shared) -> [ProjectSession] {
    let candidates = store.candidates
    func belongs(_ cwd: String) -> Bool {
      !cwd.isEmpty && ProjectPath.deepest(for: cwd, in: candidates) == project.id
    }
    var found: [ProjectSession] = []
    for account in Accounts.shared.all {
      for session in account.sessions.sessions where belongs(session.registry.cwd) {
        found.append(ProjectSession(source: .claude(session, account)))
      }
    }
    for account in CodexAccounts.shared.all {
      for session in account.sessions.liveSessions
      where !session.isSubagent && belongs(session.meta.cwd) {
        found.append(ProjectSession(source: .codex(session, account)))
      }
    }
    return found.sorted {
      ($0.lastActivity ?? .distantPast, $0.id) > ($1.lastActivity ?? .distantPast, $1.id)
    }
  }
}

/// One project in the sidebar: a folder, its name, and how many sessions are live in it.
///
/// The same shape as `AccountSidebarRow`, badge and working dot included, so a project
/// reads as a place work happens rather than as a bookmark.
struct ProjectSidebarRow: View {
  let project: Project

  var body: some View {
    let live = ProjectSession.live(in: project)
    let working = live.count(where: \.isWorking)
    HStack(spacing: 8) {
      // Decorative: VoiceOver reads the symbol's own description, which for `folder` is
      // "Move", and the name beside it already says what the row is.
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(project.displayName)
        .lineLimit(1)
      Spacer(minLength: 4)
      if working > 0 {
        Circle()
          .fill(SessionState.working.tint)
          .frame(width: 6, height: 6)
          .help("\(working) working")
      }
    }
    .badge(live.count)
    .help(project.displayPath)
  }
}

/// Adding a folder, from anywhere that offers it.
@MainActor
enum ProjectAdder {
  static func add(path: String, agent: ProjectAgent) {
    guard let project = ProjectStore.shared.add(path: path, agent: agent) else { return }
    MainWindowRoute.shared.open(.project(project.id))
  }

  /// `runModal`, for the reason `NewSessionLauncher.chooseFolder` gives.
  static func chooseFolder() {
    guard let agent = ProjectStore.shared.defaultNewAgent else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add Project"
    panel.message =
      "Choose a folder to start sessions in. It does not need to have had a session before."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    add(path: url.path(percentEncoded: false), agent: agent)
  }
}

/// The sidebar's "+": recent folders one click each, and the picker for anything else.
struct ProjectAddMenu: View {
  @State private var store = ProjectStore.shared

  var body: some View {
    Menu {
      Button("Choose Folder…") { ProjectAdder.chooseFolder() }
      let suggestions = store.suggestions.prefix(10)
      if !suggestions.isEmpty {
        Section("Recent folders") {
          ForEach(suggestions) { suggestion in
            Button(suggestion.recent.displayPath) {
              ProjectAdder.add(path: suggestion.recent.path, agent: suggestion.agent)
            }
          }
        }
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Add a project")
    .disabled(store.defaultNewAgent == nil)
  }
}

/// "Add to Projects", or "Show Project" when the folder already belongs to one, for a
/// session row's or a recent folder's context menu.
///
/// Nothing for a temporary folder: a scratchpad is the one place nobody wants a project.
struct ProjectContextButton: View {
  let path: String
  let agent: ProjectAgent

  var body: some View {
    if !path.isEmpty, !ProjectPath.isTemporary(path) {
      if let project = ProjectStore.shared.project(containing: path) {
        Button("Show Project “\(project.displayName)”") {
          MainWindowRoute.shared.open(.project(project.id))
        }
      } else {
        Button("Add “\((path as NSString).lastPathComponent)” to Projects") {
          ProjectAdder.add(path: path, agent: agent)
        }
      }
    }
  }
}

/// A project: start a session in it, see what is running there, and change it.
struct ProjectPaneView: View {
  let project: Project

  @State private var store = ProjectStore.shared
  @State private var launcher = NewSessionLauncher.shared
  @State private var accounts = Accounts.shared
  @State private var codex = CodexAccounts.shared
  @State private var name = ""
  @State private var confirmingRemoval = false

  var body: some View {
    Form {
      newSessionSection
      liveSection
      ProjectUsageSection(project: project)
      projectSection
    }
    .formStyle(.grouped)
    .newSessionFailureAlert()
    .onAppear { name = project.name ?? "" }
    .onDisappear { commitName() }
    .confirmationDialog(
      "Remove “\(project.displayName)” from Projects?", isPresented: $confirmingRemoval
    ) {
      Button("Remove", role: .destructive) { store.remove(id: project.id) }
    } message: {
      Text("Nothing on disk changes: the folder and its sessions stay where they are.")
    }
  }

  // MARK: - New session

  private var exists: Bool { store.folderExists(project) }

  @ViewBuilder private var newSessionSection: some View {
    Section {
      if !exists {
        Label(
          "\(project.displayPath) is not there any more.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        Button("Locate…") { locate() }
      } else if let agent = store.resolve(project.agent) {
        Menu {
          otherAgents
        } label: {
          Text("New \(agent.vendorName) Session on \(store.accountName(project.agent) ?? "")")
        } primaryAction: {
          launcher.start(agent, in: project.url)
        }
        .fixedSize()
      } else {
        // The default account is gone — a config folder removed, a Codex home unset —
        // so there is no one-click launch, only the choice.
        Menu("Start a Session") { otherAgents }
          .fixedSize()
          .disabled(accounts.all.isEmpty && codex.all.isEmpty)
        Text(
          "The account this project starts on is not on this Mac. Choose another under Project."
        )
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("New session")
    } footer: {
      Text(
        "Opens \(launcher.terminal.name) in \(project.displayPath). The arrow starts one on another account."
      )
    }
  }

  @ViewBuilder private var otherAgents: some View {
    ForEach(accounts.all) { account in
      Button("Claude Code on \(account.displayName)") {
        launcher.start(.claude(account.folder), in: project.url)
      }
    }
    ForEach(codex.all) { account in
      Button("Codex on \(account.displayName)") {
        launcher.start(.codex(account.home), in: project.url)
      }
    }
  }

  // MARK: - Live sessions

  private var liveSection: some View {
    Section("Live sessions") {
      let sessions = ProjectSession.live(in: project, store: store)
      if sessions.isEmpty {
        Text("Nothing running here.").foregroundStyle(.secondary)
      } else {
        ForEach(sessions) { session in
          PanelRow(help: "Show this session") {
            session.open()
          } label: {
            HStack(spacing: 8) {
              switch session.source {
              case .claude(let claude, _): StateDot(state: claude.state)
              case .codex(let codex, _): CodexStateDot(state: codex.state)
              }
              VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                  .lineLimit(1)
                Text(subtitle(for: session))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.head)
              }
              Spacer(minLength: 8)
              if let last = session.lastActivity {
                Text(last, format: .relative(presentation: .numeric))
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
          }
        }
      }
    }
  }

  /// The subfolder relative to the project, then the account: `apps/apple · Personal`.
  private func subtitle(for session: ProjectSession) -> String {
    let cwd = ProjectPath.normalize(session.cwd)
    var parts: [String] = []
    if cwd != project.path {
      parts.append(
        ProjectPath.contains(project.path, cwd)
          ? String(cwd.dropFirst(project.path.count + 1))
          : (cwd as NSString).abbreviatingWithTildeInPath)
    }
    parts.append(session.accountName)
    return parts.joined(separator: " · ")
  }

  // MARK: - Project

  private var projectSection: some View {
    Section("Project") {
      TextField(
        "Name", text: $name, prompt: Text((project.path as NSString).lastPathComponent)
      )
      .onSubmit { commitName() }
      LabeledContent("Folder") {
        HStack(spacing: 8) {
          Text(project.displayPath)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
          Button("Reveal") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
          }
          .disabled(!exists)
          Button("Change…") { locate() }
        }
      }
      Picker("Starts on", selection: agentBinding) {
        ForEach(accounts.all) { account in
          Text("Claude Code on \(account.displayName)")
            .tag(ProjectAgent.claude(accountID: account.id))
        }
        ForEach(codex.all) { account in
          Text("Codex on \(account.displayName)")
            .tag(ProjectAgent.codex(homeID: account.id))
        }
        if store.resolve(project.agent) == nil {
          Text("\(project.agent.vendorName), an account not on this Mac").tag(project.agent)
        }
      }
      Button("Remove from Projects…", role: .destructive) { confirmingRemoval = true }
    }
  }

  private var agentBinding: Binding<ProjectAgent> {
    Binding(
      get: { project.agent },
      set: { store.setAgent(id: project.id, $0) })
  }

  private func commitName() {
    guard (project.name ?? "") != name else { return }
    store.rename(id: project.id, to: name)
  }

  private func locate() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = project.url.deletingLastPathComponent()
    panel.prompt = "Use Folder"
    panel.message = "Choose where “\(project.displayName)” is now."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.relocate(id: project.id, to: url.path(percentEncoded: false))
  }
}
