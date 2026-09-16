import SwiftUI

/// What the detail pane shows when no session is selected.
///
/// **The pane used to show the first session in the list instead**, which meant the
/// window opened on a row nobody had chosen and there was no state in which the pane
/// was about the *account*. Mail's "No Message Selected" is the shape this follows:
/// deselecting is a real state, and the space it frees is worth something. Here it
/// carries the two things a session row cannot — where to start a new session, and
/// what the whole account is doing.
///
/// It is reached by clicking empty space in the list, by ⌘-clicking the selected row,
/// and at launch, which is where it earns its place: the window now opens on a summary
/// rather than on an arbitrary session.
///
/// Claude and Codex get one each because their sections differ in what the vendors
/// record, and both are assembled from the same two shared pieces below — the same
/// arrangement `ContextPanel` and its two adapters already use.
struct AccountOverview: View {
  let account: Account

  var body: some View {
    Form {
      NewSessionSection(agent: .claude(account.folder), projects: account.recentProjects)
      SessionTallySection(
        sessions: account.sessions.sessions,
        empty: "Nothing is running in this account."
      ) { key in
        // The list's own dot, not a second one: the ring on an inferred state is part
        // of what a state dot means here, and a tally drawing a plain circle would be
        // claiming more than the rows below it do.
        StateDot(state: SessionState(rawValue: key) ?? .idle)
      }
      AccountSection(account: account)
    }
    .formStyle(.grouped)
  }
}

/// The Codex half, section for section.
struct CodexOverview: View {
  let account: CodexAccount

  var body: some View {
    Form {
      NewSessionSection(agent: .codex(account.home), projects: account.recentProjects)
      // "Recent", not "running": this pane's list holds the last 12 hours, so most of
      // what the tally counts has ended. The empty line says so rather than implying
      // the home is idle right now.
      SessionTallySection(
        sessions: account.sessions.sessions,
        empty: "Nothing has run here in the last 12 hours."
      ) { key in
        CodexStateDot(state: CodexSessionState(rawValue: key) ?? .ended)
      }
      CodexHomeSection(account: account)
    }
    .formStyle(.grouped)
  }
}

/// Start a session here, or anywhere.
///
/// **The recents are the point.** A folder picker alone would be slower than the
/// terminal the person already has open; the six folders this account ran in last, one
/// click each, are the thing they do not have. The picker stays underneath for the
/// seventh.
///
/// `PanelRow` is the menu bar panel's row, reused rather than copied: it carries the
/// hover fill and the pointer that a `.plain` button in a `Form` does not get, and
/// nothing about it was ever specific to the popover.
struct NewSessionSection: View {
  let agent: NewSession.Agent
  let projects: [RecentProject]

  @State private var launcher = NewSessionLauncher.shared
  @State private var mcp = MCPServerController.shared

  var body: some View {
    Section {
      ForEach(projects) { project in
        PanelRow(help: "Start a \(agent.vendorName) session in \(project.displayPath)") {
          launcher.start(agent, in: project.url)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text(project.name)
                .lineLimit(1)
              // The path rather than a disambiguating suffix: two checkouts called
              // `website` are the case this has to make legible, and at this width the
              // whole path fits where a menu item's single line would not have.
              Text(project.displayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let started = project.lastStartedAt {
              Text(started, format: .relative(presentation: .numeric))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }
        }
        .contextMenu {
          ProjectContextButton(path: project.path, agent: agent.projectAgent)
        }
      }
      Button("Choose Folder…") {
        launcher.chooseFolder(for: agent, near: projects.first?.url)
      }
      // Claude only: the supervisor is a Claude Code session, and the home folder because it
      // belongs to no one project. Settings ▸ Supervisor offers a folder picker.
      if case .claude(let folder) = agent {
        Button("Start Supervisor Session") {
          launcher.startSupervisor(
            on: folder, in: FileManager.default.homeDirectoryForCurrentUser)
        }
        .disabled(mcp.runningPort == nil)
        .help(
          mcp.runningPort == nil
            ? "Turn on the MCP server in Settings ▸ Supervisor to start a session that can see every session on this Mac."
            : "Start claude in your home folder, connected to Armada, to ask about every session at once."
        )
      }
    } header: {
      Text("New session")
    } footer: {
      // Names the terminal, because that is a setting somebody chose once and will not
      // remember, and it is the whole of what this button does that is not obvious.
      Text(
        launcher.opensInVSCode(agent)
          ? "Opens a \(agent.vendorName) tab in that folder's \(VSCodeLaunch.name) window, or a new window on this account."
          : "Opens \(launcher.terminal.name) with \(agent.commandName) running in that folder, on this account."
      )
    }
  }
}

/// What this account's sessions are doing, in one block.
///
/// **Built from the list's own grouping**, `SessionOrder.group(_:by:)` with `.state`,
/// so the buckets, their order and their names are the same ones the list shows when
/// grouping is switched on — each vendor's own vocabulary, ranked by what wants you
/// first. A tally that counted states some other way would be a second opinion about
/// the same sessions.
///
/// Generic over the dot so each pane keeps its own, which is also why this takes a
/// state key rather than a colour: `SessionState` and `CodexSessionState` are
/// different sets on purpose, and the closure is where that stays true.
struct SessionTallySection<Item: SessionListItem, Dot: View>: View {
  let sessions: [Item]
  let empty: String
  @ViewBuilder let dot: (String) -> Dot

  var body: some View {
    Section("Sessions") {
      if sessions.isEmpty {
        Text(empty).foregroundStyle(.secondary)
      } else {
        ForEach(SessionOrder.group(sessions, by: .state)) { group in
          LabeledContent {
            Text(group.items.count.formatted()).monospacedDigit()
          } label: {
            HStack(spacing: 6) {
              // The group's id is the state's raw value — see `SessionOrder.group`.
              dot(group.id)
              Text(group.title)
            }
          }
        }
        LabeledContent("Projects", value: projectCount.formatted())
        if let tokens = contextTokens {
          LabeledContent("Context in play", value: TokenCount.short(tokens))
            // The same warning `SessionGroupHeader` carries, for the same figure: this
            // is what the sessions are holding right now, and it falls when any one of
            // them compacts. It is not what they have cost — see `SessionListItem`.
            .help(
              "What these sessions are holding between them as of their newest turns. Not a running total of what they have cost."
            )
        }
      }
    }
  }

  /// Distinct checkouts, keyed on the path rather than the name: `~/work/api` and
  /// `~/oss/api` are two projects, and counting names would say one.
  private var projectCount: Int {
    Set(sessions.map(\.projectPath)).count
  }

  /// Nil when nothing has a reading yet, so the row is absent rather than claiming 0.
  private var contextTokens: Int? {
    let known = sessions.compactMap(\.contextTokens)
    return known.isEmpty ? nil : known.reduce(0, +)
  }
}

/// Which Claude account this pane is about.
///
/// Shared by the session detail and the overview rather than written twice: it is the
/// same three facts in the same order, and the pane a person is looking at should not
/// change what the account is called.
struct AccountSection: View {
  let account: Account

  var body: some View {
    Section("Account") {
      LabeledContent("Organization", value: account.displayName)
      if let plan = account.planLabel {
        LabeledContent("Plan", value: plan)
      }
      LabeledContent("Config folder", value: account.displayPath)
        .lineLimit(2)
        .truncationMode(.head)
    }
  }
}

/// The Codex twin of `AccountSection`.
struct CodexHomeSection: View {
  let account: CodexAccount

  var body: some View {
    Section("Codex") {
      LabeledContent("Home", value: account.displayPath)
        .lineLimit(2)
        .truncationMode(.head)
      if let plan = account.planLabel {
        LabeledContent("Plan", value: plan)
      }
    }
  }
}
