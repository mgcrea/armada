import SwiftUI

/// Every skill, custom command and plugin skill used on this Mac: the list on the left, the
/// selected one on the right, across every project.
///
/// The same split as `ProjectsPaneView`, `GeometryReader`s included and for the reason given
/// there. Built-ins like `/compact` are left out, as in the project pane.
///
/// **The window is the Projects pane's.** One `StatsWindow` under `StatsWindow.defaultsKey`,
/// so moving between the two panes never changes what the figures cover.
struct SkillsPaneView: View {
  @State private var index = UsageIndex.shared
  @State private var store = ProjectStore.shared
  @State private var route = MainWindowRoute.shared

  /// A skill's name, kept across visits for the reason `ProjectsPaneView` keeps its project.
  ///
  /// **Kept when the skill leaves the list**, in another window or because its files were
  /// deleted and it now reads as a built-in: the detail then says it has no uses here, rather
  /// than keeping the last figures or falling back to nothing selected.
  @AppStorage("armada.selectedSkill") private var storedSelection = ""

  @AppStorage(StatsWindow.defaultsKey) private var storedWindow = StatsWindow.week.rawValue

  private var window: StatsWindow { StatsWindow(rawValue: storedWindow) ?? .week }

  var body: some View {
    let tallies = index.projectSkills(store: store)
    let summaries = SkillStats.summaries(tallies, window: window)
    HSplitView {
      GeometryReader { _ in list(summaries) }
        .frame(minWidth: 260, idealWidth: 320)
      GeometryReader { _ in detail(tallies, summaries) }
        .frame(minWidth: 380, idealWidth: 520)
    }
    .navigationTitle("Skills")
    .navigationSubtitle(
      summaries.count == 1 ? "1 skill" : "\(summaries.count.formatted()) skills"
    )
    // Both, for the reason `AccountPaneView` gives.
    .onAppear { applyRoute() }
    .onChange(of: route.token) { applyRoute() }
  }

  /// Take the skill a project pane's row asked for. The route parks a row to select, which in
  /// this pane is a skill's name.
  private func applyRoute() {
    guard let name = route.takeSession(in: .skills) else { return }
    storedSelection = name
  }

  /// Drops the `nil` a `List` writes back, as the sidebar's selection does: one written when
  /// the selected row leaves the list would turn "no uses in this window" into "no skill
  /// selected".
  private var selection: Binding<String?> {
    Binding(
      get: { storedSelection.isEmpty ? nil : storedSelection },
      set: { newValue in
        guard let newValue else { return }
        storedSelection = newValue
      })
  }

  // MARK: Left

  private func list(_ summaries: [SkillSummary]) -> some View {
    VStack(spacing: 0) {
      Picker("Window", selection: $storedWindow) {
        ForEach(StatsWindow.allCases, id: \.self) { window in
          Text(window.title).tag(window.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(8)
      Divider()
      if summaries.isEmpty {
        ContentUnavailableView {
          Label("No skills in this window", systemImage: "wand.and.sparkles")
        }
        .frame(maxHeight: .infinity)
      } else {
        List(selection: selection) {
          ForEach(summaries) { summary in
            SkillRow(summary: summary)
              .tag(summary.skill)
          }
        }
      }
      Divider()
      Text(index.ledger.skillsFooter)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
  }

  // MARK: Right

  @ViewBuilder private func detail(_ tallies: [SkillTally], _ summaries: [SkillSummary])
    -> some View
  {
    if storedSelection.isEmpty {
      ContentUnavailableView {
        Label("No skill selected", systemImage: "wand.and.sparkles")
      } description: {
        Text("Select a skill to see where it's used.")
      }
    } else if let summary = summaries.first(where: { $0.skill == storedSelection }) {
      SkillDetail(
        summary: summary, window: window,
        byProject: SkillStats.byProject(tallies, skill: summary.skill, window: window),
        byAccount: SkillStats.byAccount(tallies, skill: summary.skill, window: window)
      )
      // Rebuilt per skill, so one skill's recent uses never show under another's name.
      .id(summary.skill)
    } else {
      ContentUnavailableView {
        Label(storedSelection, systemImage: "wand.and.sparkles")
      } description: {
        Text("No uses in this window.")
      }
    }
  }
}

/// One skill in the list: what it is, its name, and its uses in the window.
private struct SkillRow: View {
  let summary: SkillSummary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: summary.source.symbol)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityLabel(summary.source.label)
      Text(summary.skill)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(skillCount(total: summary.total, slash: summary.slash))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

/// A skill: its totals, where and on which account it was used, and its last uses.
private struct SkillDetail: View {
  let summary: SkillSummary
  let window: StatsWindow
  let byProject: [SkillShare]
  let byAccount: [SkillShare]

  @State private var index = UsageIndex.shared
  @State private var store = ProjectStore.shared
  @State private var recent: [SkillUseRecord] = []

  /// What the recent uses were read for. The generation is in it so a commit that counted a
  /// new use reads them again.
  private struct RecentKey: Hashable {
    let skill: String
    let window: StatsWindow
    let generation: Int
  }

  var body: some View {
    Form {
      Section("Totals") {
        LabeledContent("Total", value: summary.total.formatted())
        LabeledContent("Loaded by Claude", value: summary.auto.formatted())
        LabeledContent("Typed", value: summary.slash.formatted())
        LabeledContent("Last used") {
          Text(summary.lastAt, format: .clockRelative(presentation: .named))
        }
      }

      Section("By project") {
        ForEach(byProject, id: \.key) { share in
          if let id = share.key {
            let name = store.project(id: id)?.displayName ?? id
            Button {
              MainWindowRoute.shared.open(project: id)
            } label: {
              LabeledContent(name, value: skillCount(total: share.total, slash: share.slash))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(name) in Projects")
          } else {
            LabeledContent(
              "Outside saved projects", value: skillCount(total: share.total, slash: share.slash))
          }
        }
      }

      // One account is the common case, and a section repeating the total says nothing.
      if byAccount.count > 1 {
        Section("By account") {
          ForEach(byAccount, id: \.key) { share in
            // Skills are counted for Claude Code only, so every key is a Claude account's.
            LabeledContent(
              usageAccountName(share.key ?? "", vendor: .claude),
              value: skillCount(total: share.total, slash: share.slash))
          }
        }
      }

      if !recent.isEmpty {
        Section("Recent uses") {
          ForEach(recent) { use in
            RecentUseRow(use: use, place: place(of: use))
          }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: RecentKey(skill: summary.skill, window: window, generation: index.ledger.generation))
    {
      let uses = await index.recentSkillUses(skill: summary.skill, window: window)
      // The read runs detached and cannot be cancelled, so a slow one for the window or
      // generation before still comes back here: only the current request's may land.
      guard !Task.isCancelled else { return }
      recent = uses
    }
  }

  /// The project a use happened in, or its folder outside every saved project.
  private func place(of use: SkillUseRecord) -> String {
    if let id = ProjectPath.deepest(for: use.cwd, in: store.candidates),
      let project = store.project(id: id)
    {
      return project.displayName
    }
    // The ledger stores every scratchpad as this one folder (`UsageIndexer.storedFolder`).
    if use.cwd == "~tmp" { return "a temporary folder" }
    return (use.cwd as NSString).abbreviatingWithTildeInPath
  }
}

/// One recent use: when, how and where, then what the skill was asked and what came next.
///
/// **Two lines each, the rest on hover.** Args and replies are kept up to 500 characters and
/// may run over several lines, which would make one use the height of the list.
private struct RecentUseRow: View {
  let use: SkillUseRecord
  let place: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(
        "\(use.at.formatted(when)) · \(use.kind == .slash ? "typed" : "loaded") · \(place)"
      )
      .lineLimit(1)
      .truncationMode(.middle)
      if let args = use.args {
        Text(args)
          .font(.callout)
          .lineLimit(2)
          .help(args)
      }
      if let reply = use.reply {
        let next = "Next: \(reply)"
        Text(next)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .help(next)
      }
    }
    .padding(.vertical, 2)
  }

  /// Day, month and time, and the year too for a use in another year.
  private var when: Date.FormatStyle {
    let style = Date.FormatStyle.dateTime.day().month().hour().minute()
    return Calendar.current.isDate(use.at, equalTo: AppClock.now, toGranularity: .year)
      ? style : style.year()
  }
}

/// "12", or "12 (3 typed)" when some were typed as `/name`: the format of every skill count,
/// here and in the project pane's skill rows.
func skillCount(total: Int, slash: Int) -> String {
  slash > 0 ? "\(total.formatted()) (\(slash.formatted()) typed)" : total.formatted()
}

extension SkillSource {
  /// The list row's icon. A built-in is never listed, so its symbol is only a fallback.
  fileprivate var symbol: String {
    switch self {
    case .skill: "wand.and.sparkles"
    case .command: "terminal"
    case .plugin: "puzzlepiece.extension"
    case .builtin: "command"
    }
  }

  /// What VoiceOver reads for the icon.
  fileprivate var label: String {
    switch self {
    case .skill: "Skill"
    case .command: "Custom command"
    case .plugin: "Plugin skill"
    case .builtin: "Built-in command"
    }
  }
}
