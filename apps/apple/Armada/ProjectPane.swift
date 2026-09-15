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

/// Adding a folder, from anywhere that offers it.
@MainActor
enum ProjectAdder {
  static func add(path: String, agent: ProjectAgent) {
    add(paths: [path], agent: agent)
  }

  /// Several at once, all starting on `agent`. Selects the first one chosen, so the pane
  /// lands on something the person just picked; a folder already saved counts, and `/` is
  /// skipped as `ProjectStore.add` refuses it.
  static func add(paths: [String], agent: ProjectAgent) {
    let added = paths.compactMap { ProjectStore.shared.add(path: $0, agent: agent) }
    guard let first = added.first else { return }
    MainWindowRoute.shared.open(project: first.id)
  }

  /// Folders dropped from Finder. Files among them are ignored rather than refusing the drop,
  /// so a selection that caught a stray file still adds its folders.
  static func add(dropped urls: [URL]) -> Bool {
    guard let agent = ProjectStore.shared.defaultNewAgent else { return false }
    let folders = urls.filter {
      $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    guard !folders.isEmpty else { return false }
    add(paths: folders.map { $0.path(percentEncoded: false) }, agent: agent)
    return true
  }

  /// `runModal`, for the reason `NewSessionLauncher.chooseFolder` gives.
  static func chooseFolder() {
    guard let agent = ProjectStore.shared.defaultNewAgent else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    panel.message =
      "Choose one or more folders to start sessions in. They do not need to have had a session before."
    guard panel.runModal() == .OK else { return }
    add(paths: panel.urls.map { $0.path(percentEncoded: false) }, agent: agent)
  }
}

/// "Choose Folder…" and the recent folders, one click each: the items behind the list's "+"
/// and the empty pane's "Add Project".
struct ProjectAddItems: View {
  @State private var store = ProjectStore.shared

  var body: some View {
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
          MainWindowRoute.shared.open(project: project.id)
        }
      } else {
        Button("Add “\((path as NSString).lastPathComponent)” to Projects") {
          ProjectAdder.add(path: path, agent: agent)
        }
      }
    }
  }
}

// MARK: - Pane

/// Every saved project: the list on the left, the selected project on the right.
///
/// The same split as `AccountPaneView`, `GeometryReader`s included and for the reason given
/// there: the right half swaps between an empty state and a form, and without them the
/// divider would jump on the first click.
struct ProjectsPaneView: View {
  @State private var store = ProjectStore.shared
  @State private var index = UsageIndex.shared
  @State private var launcher = NewSessionLauncher.shared
  @State private var route = MainWindowRoute.shared
  @State private var removing: Project?

  /// Kept across visits, where an account pane's session selection is not: this pane has no
  /// overview to show instead, so coming back to an empty right half would only cost a click.
  @AppStorage("armada.selectedProject") private var storedSelection = ""

  /// The window the project form's picker chose, so the list's figures and the form's agree.
  @AppStorage(StatsWindow.defaultsKey) private var storedWindow = StatsWindow.week.rawValue

  var body: some View {
    Group {
      if store.projects.isEmpty {
        empty
      } else {
        HSplitView {
          GeometryReader { _ in list }
            .frame(minWidth: 260, idealWidth: 320)
          GeometryReader { _ in detail }
            .frame(minWidth: 380, idealWidth: 520)
        }
      }
    }
    // Folders dragged in from Finder, as many as were dragged.
    .dropDestination(for: URL.self) { urls, _ in ProjectAdder.add(dropped: urls) }
    .navigationTitle("Projects")
    .navigationSubtitle(subtitle)
    .newSessionFailureAlert()
    .confirmationDialog(
      "Remove “\(removing?.displayName ?? "")” from Projects?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      presenting: removing
    ) { project in
      Button("Remove", role: .destructive) { store.remove(id: project.id) }
    } message: { _ in
      Text("Nothing on disk changes: the folder and its sessions stay where they are.")
    }
    // Both, for the reason `AccountPaneView` gives.
    .onAppear { applyRoute() }
    .onChange(of: route.token) { applyRoute() }
  }

  /// Take the project "Add to Projects" or "Show Project" asked for. The route parks a row
  /// to select, which in this pane is a project id.
  private func applyRoute() {
    guard let id = route.takeSession(in: .projects) else { return }
    storedSelection = id
  }

  private var selection: Binding<String?> {
    Binding(
      get: { selected?.id },
      set: { storedSelection = $0 ?? "" })
  }

  private var selected: Project? { store.project(id: storedSelection) }

  private var window: StatsWindow { StatsWindow(rawValue: storedWindow) ?? .week }

  // MARK: Left

  private var empty: some View {
    ContentUnavailableView {
      Label("No projects", systemImage: "folder")
    } description: {
      Text(
        "Save the folders you work in, or drop them here from Finder: a session is then one click away in any of them, even where none has run yet, with the tokens spent there."
      )
    } actions: {
      Menu("Add Project") { ProjectAddItems() }
        .fixedSize()
        .disabled(store.defaultNewAgent == nil)
    }
  }

  private var list: some View {
    let usage = index.projectUsage(store: store)
    return VStack(spacing: 0) {
      List(selection: selection) {
        ForEach(store.projects) { project in
          ProjectRow(
            project: project, tokens: usage[project.id]?.tokens[window]?.total ?? 0,
            window: window
          )
          .tag(project.id)
        }
      }
      // On the `List` and typed `String`, for the reasons `AccountPaneView` gives.
      .contextMenu(forSelectionType: String.self) { ids in
        if let id = ids.first, ids.count == 1, let project = store.project(id: id) {
          contextMenu(for: project)
        }
      }
      .onDeleteCommand { removing = selected }
      Divider()
      bar
    }
  }

  @ViewBuilder private func contextMenu(for project: Project) -> some View {
    let exists = store.folderExists(project)
    if exists, let agent = store.resolve(project.agent) {
      Button("New \(agent.vendorName) Session on \(store.accountName(project.agent) ?? "")") {
        launcher.start(agent, in: project.url)
      }
    }
    Button("Reveal in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }
    .disabled(!exists)
    Divider()
    Button("Remove from Projects…") { removing = project }
  }

  /// The "+ −" under the list, as System Settings' own lists have.
  private var bar: some View {
    HStack(spacing: 0) {
      Menu {
        ProjectAddItems()
      } label: {
        Image(systemName: "plus")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .frame(width: 28, height: 22)
      .help("Add a project")
      .disabled(store.defaultNewAgent == nil)
      Divider()
        .frame(height: 14)
      Button {
        removing = selected
      } label: {
        Image(systemName: "minus")
          .frame(width: 28, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help("Remove the selected project")
      .disabled(selected == nil)
      Spacer()
    }
    .padding(.horizontal, 4)
    .background(.bar)
  }

  // MARK: Right

  @ViewBuilder private var detail: some View {
    if let selected {
      ProjectDetail(project: selected) { removing = selected }
        // Rebuilt per project, so the name field starts from the right name and commits
        // the one it was editing as it goes.
        .id(selected.id)
    } else {
      ContentUnavailableView {
        Label("No project selected", systemImage: "folder")
      } description: {
        Text("Select a project to start a session in it and see the tokens spent there.")
      }
    }
  }

  private var subtitle: String {
    let count = store.projects.count
    let projects = count == 1 ? "1 project" : "\(count) projects"
    let live = store.projects.reduce(0) { $0 + ProjectSession.live(in: $1, store: store).count }
    return live == 0 ? projects : "\(projects) · \(live) live"
  }
}

/// One project in the list: its name and folder, the tokens spent there in the chosen window,
/// and how many sessions are live in it.
///
/// Badge and working dot as `AccountSidebarRow` has them, so a project reads as a place work
/// happens rather than as a bookmark.
struct ProjectRow: View {
  let project: Project
  let tokens: Int
  let window: StatsWindow

  var body: some View {
    let live = ProjectSession.live(in: project)
    let working = live.count(where: \.isWorking)
    let exists = ProjectStore.shared.folderExists(project)
    HStack(spacing: 8) {
      Image(systemName: exists ? "folder" : "folder.badge.questionmark")
        .foregroundStyle(exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        .frame(width: 18)
        .help(exists ? "" : "\(project.displayPath) is not there any more")
        // Only the missing folder says something the name beside it does not. VoiceOver
        // reads the plain symbol as "Move".
        .accessibilityLabel("Folder missing")
        .accessibilityHidden(exists)
      VStack(alignment: .leading, spacing: 1) {
        Text(project.displayName)
          .lineLimit(1)
        Text(project.displayPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 4)
      if tokens > 0 {
        Text(TokenCount.short(tokens))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .help("\(tokens.formatted()) tokens (\(window.title.lowercased()))")
      }
      if working > 0 {
        Circle()
          .fill(SessionState.working.tint)
          .frame(width: 6, height: 6)
          .help("\(working) working")
      }
    }
    .padding(.vertical, 2)
    .badge(live.count)
  }
}

/// A project: start a session in it, see what is running there, and change it.
struct ProjectDetail: View {
  let project: Project
  /// Asks the pane to confirm, so the "−" under the list and this button share one dialog.
  let remove: () -> Void

  @State private var store = ProjectStore.shared
  @State private var launcher = NewSessionLauncher.shared
  @State private var accounts = Accounts.shared
  @State private var codex = CodexAccounts.shared
  @State private var name = ""

  var body: some View {
    Form {
      newSessionSection
      liveSection
      ProjectUsageSection(project: project)
      projectSection
    }
    .formStyle(.grouped)
    .onAppear { name = project.name ?? "" }
    .onDisappear { commitName() }
  }

  // MARK: New session

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

  // MARK: Live sessions

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

  // MARK: Project

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
      Button("Remove from Projects…", role: .destructive) { remove() }
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
