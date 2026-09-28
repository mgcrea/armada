import SwiftUI

/// What the detail pane shows when no session is selected.
///
/// **The pane used to show the first session in the list instead**, which meant the
/// window opened on a row nobody had chosen and there was no state in which the pane
/// was about the *account*. Mail's "No Message Selected" is the shape this follows:
/// deselecting is a real state, and the space it frees is worth something. Here it
/// carries what a session row cannot: the account's plan windows and its week, a way to
/// start another session, and the account itself. What its sessions are doing is counted
/// above the list instead (`SessionListBar`), where it stays while a session is open.
///
/// It is reached by clicking empty space in the list, by ⌘-clicking the selected row,
/// and at launch, which is where it earns its place: the window now opens on a summary
/// rather than on an arbitrary session.
///
/// Claude and Codex get one each because their sections differ in what the vendors
/// record, and both are assembled from the same shared pieces below — the same
/// arrangement `ContextPanel` and its two adapters already use.
struct AccountOverview: View {
  let account: Account
  let now: Date

  var body: some View {
    Form {
      let usage = account.usage.flatMap { $0.isEmpty ? nil : $0 }
      // The chart is fed the uncorrected weekly window, as the Usage pane's is: one account's
      // week should not be two different lines depending on the pane.
      OverviewUsageSection(
        accountID: account.id, rows: usage.map { account.windowRows(for: $0, now: now) } ?? [],
        week: usage?.sevenDay, fetchedAt: usage?.fetchedAt, now: now,
        empty: account.didReadUsage ? "No usage data yet" : "Reading usage…"
      ) {
        if let usage {
          StalenessBadge(
            fetchedAt: usage.fetchedAt, now: now, source: usage.source, style: .inline)
        }
      }
      NewSessionSection(
        agent: .claude(account.folder), suggestion: account.recentProjects.first?.url)
      AccountSection(account: account)
      ArchiveSection(account: account.id)
    }
    .formStyle(.grouped)
  }
}

/// The Codex half, section for section.
struct CodexOverview: View {
  let account: CodexAccount
  let now: Date

  var body: some View {
    Form {
      let snapshot = account.usage.flatMap { $0.isEmpty ? nil : $0.asSnapshot }
      OverviewUsageSection(
        accountID: account.id, rows: snapshot.map { account.windowRows(for: $0) } ?? [],
        week: snapshot?.sevenDay, fetchedAt: snapshot?.fetchedAt, now: now,
        empty: account.sessions.didScan ? "No usage reported yet" : "Reading usage…"
      ) {
        if let observedAt = account.usage?.observedAt {
          CodexLastTurn(observedAt: observedAt)
        }
      }
      NewSessionSection(
        agent: .codex(account.home), suggestion: account.recentProjects.first?.url)
      CodexHomeSection(account: account)
      ArchiveSection(account: account.id)
    }
    .formStyle(.grouped)
  }
}

/// An account's plan windows and its week, first thing on its overview.
///
/// **This is where the usage strip above the session list went.** The strip was the glance,
/// and it showed one account's two percentages beside a list that, with a session
/// selected, is about something else. The glance is the sidebar row's now (`SidebarUsage`),
/// for every account at once, and this is the look: every window the account has, per-model
/// ones included, each with its pace and projection, over the week's recorded climb. It is
/// the Usage pane's card for this one account, built from the same rows.
struct OverviewUsageSection<Status: View>: View {
  let accountID: String
  let rows: [WindowRowModel]
  /// The weekly window the chart is drawn from, and nil for no chart.
  let week: UsageWindow?
  let fetchedAt: Date?
  let now: Date
  /// Said when there are no windows to list.
  let empty: String
  /// How old the figures are, in the header's trailing corner.
  @ViewBuilder let status: () -> Status

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored

  var body: some View {
    let profile = PaceProfile(storedDays: storedWeights, storedHours: storedHours)
    Section {
      if rows.isEmpty {
        Text(empty).foregroundStyle(.secondary)
      } else {
        ForEach(rows) { row in
          WindowRow(row: row, profile: profile, fetchedAt: fetchedAt, now: now)
        }
        if week?.resetsAt != nil {
          WeeklyChart(
            accountID: accountID, window: week, profile: profile, fetchedAt: fetchedAt,
            now: now)
        }
      }
    } header: {
      HStack(alignment: .firstTextBaseline) {
        Text("Usage")
        Spacer(minLength: 8)
        status()
      }
    }
  }
}

/// The age of a Codex home's figures, laid out as `StalenessBadge(style: .inline)` is.
///
/// Its own view rather than that badge, because what dates these figures is a turn, not a
/// cache or a probe, and the words should say so. Codex states its limits only inside a
/// `token_count` event, so the newest figures are exactly as old as the last turn anyone
/// ran, and on a Mac where Codex ran at 07:00 the 5-hour window they describe is gone by
/// lunch. `WindowRow` already says "window has since reset" for that case.
struct CodexLastTurn: View {
  let observedAt: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text("last turn").font(.caption2).foregroundStyle(.tertiary)
      Text(observedAt, format: .clockRelative(presentation: .named))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .help(
      "Codex only reports its limits inside a session log, so these figures are as old as the last turn it ran."
    )
  }
}

/// Start a session on this account, from one control.
///
/// **This used to list the six folders the account ran in last**, one click each, above a
/// folder picker and the supervisor button. The list took the top of the pane for
/// something the terminal already does as fast, so it made way for the account's usage; a
/// folder's own sessions still offer "New Session in <project>" on their right-click, and
/// the Projects pane starts one in any saved project.
///
/// A pull-down rather than two buttons, because both start the same thing and differ only
/// in where. Codex has no supervisor, and a menu of one item is a button with an extra
/// click, so it gets the button.
struct NewSessionSection: View {
  let agent: NewSession.Agent
  /// Where the folder picker opens: the folder this account ran in last.
  let suggestion: URL?

  @State private var launcher = NewSessionLauncher.shared
  @State private var mcp = MCPServerController.shared

  var body: some View {
    Section {
      // Claude only: the supervisor is a Claude Code session, and the home folder because it
      // belongs to no one project. Settings ▸ Supervisor offers a folder picker.
      if case .claude(let folder) = agent {
        Menu("New Session") {
          Button("From Folder…") { chooseFolder() }
          Button("Supervisor Session") {
            launcher.startSupervisor(
              on: folder, in: FileManager.default.homeDirectoryForCurrentUser)
          }
          .disabled(mcp.runningPort == nil)
        }
        .fixedSize()
      } else {
        Button("New Session…") { chooseFolder() }
      }
    } footer: {
      // Names the terminal, because that is a setting somebody chose once and will not
      // remember, and it is the whole of what this control does that is not obvious.
      Text(footer)
    }
  }

  private func chooseFolder() {
    launcher.chooseFolder(for: agent, near: suggestion)
  }

  private var footer: String {
    var text =
      launcher.opensInVSCode(agent)
      ? "Opens a \(agent.vendorName) tab in that folder's \(VSCodeLaunch.name) window, or a new window on this account."
      : "Opens \(launcher.terminal.name) with \(agent.commandName) running in that folder, on this account."
    // Here rather than as the item's tooltip, which a disabled menu item never shows.
    if case .claude = agent, mcp.runningPort == nil {
      text += " A supervisor session needs the MCP server, in Settings ▸ Supervisor."
    }
    return text
  }
}

/// What a set of sessions is doing, in one block: the detail pane's for a selection of
/// several. An account's own sessions are counted above its list, by `SessionListBar`.
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
