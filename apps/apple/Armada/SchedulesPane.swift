import AppKit
import ArmadaMCP
import SwiftUI

/// Every scheduled task on this Mac, as `armada_list_schedules` sees it.
///
/// **The tool's rows, not a reader of its own.** `ScheduleStoreBridge.rows` is what the MCP
/// tool answers with, so the pane and the tool cannot disagree about a schedule. Nothing here
/// writes: Claude Code changes schedules through the MCP server, and the Codex app runs them.
@MainActor
@Observable
final class SchedulesModel {
  static let shared = SchedulesModel()

  private(set) var rows: [ScheduleRow] = []
  private(set) var loaded = false

  private init() {}

  var activeCount: Int { rows.count(where: { $0.status == "active" }) }

  /// True when the Claude app has scheduled tasks. Codex homes are known without a read.
  var hasClaudeTasks: Bool { rows.contains { $0.vendor == "claude" } }

  /// A handful of small files and one read-only query per Codex home, off the main actor.
  func load() async {
    // The rows carry the person's prompts, which a capture must never show.
    guard !ScreenshotMode.isEnabled else { return }
    // As `armada_list_schedules`: nothing is read without a licence.
    guard EntitlementMonitor.shared.current.isEntitled else { return }
    let homes = CodexAccounts.shared.all.map(\.home)
    let fresh = await Self.read(homes)
    guard !Task.isCancelled else { return }
    rows = fresh
    loaded = true
  }

  @concurrent
  private nonisolated static func read(_ homes: [CodexHome]) async -> [ScheduleRow] {
    ScheduleStoreBridge.rows(homes: homes, claudeRoot: ClaudeDesktopSchedules.defaultRoot)
  }
}

/// The schedules: the list on the left, the selected one on the right. Read-only.
///
/// The same split as `ProjectsPaneView`, `GeometryReader`s included, for the reason given there.
struct SchedulesPaneView: View {
  @State private var model = SchedulesModel.shared
  @AppStorage("armada.selectedSchedule") private var storedSelection = ""

  /// How often the list is read again while the pane is up: a run moves its next and last
  /// times, and Claude Code may have changed a schedule over MCP.
  private static let refresh: Duration = .seconds(30)

  var body: some View {
    Group {
      if model.loaded && model.rows.isEmpty {
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
    .navigationTitle("Schedules")
    .navigationSubtitle(subtitle)
    .task {
      while !Task.isCancelled {
        await model.load()
        try? await Task.sleep(for: Self.refresh)
      }
    }
  }

  private var selection: Binding<String?> {
    Binding(
      get: { selected?.paneKey },
      set: { storedSelection = $0 ?? "" })
  }

  private var selected: ScheduleRow? { model.rows.first { $0.paneKey == storedSelection } }

  /// One section per Codex home, in the accounts' order, then the Claude app's.
  private var sections: [(title: String, rows: [ScheduleRow])] {
    var out: [(title: String, rows: [ScheduleRow])] = []
    var seen: [String: Int] = [:]
    for row in model.rows {
      let title = row.vendor == "claude" ? "Claude app" : "Codex · \(row.account)"
      if let at = seen[title] {
        out[at].rows.append(row)
      } else {
        seen[title] = out.count
        out.append((title, [row]))
      }
    }
    return out.map {
      ($0.title, $0.rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
  }

  // MARK: Left

  private var empty: some View {
    ContentUnavailableView {
      Label("No schedules", systemImage: "calendar.badge.clock")
    } description: {
      Text(
        "Codex automations and the Claude app's scheduled tasks show here. Ask Claude Code to set one up: with Allow writes on, it creates Codex automations through Armada's MCP server."
      )
    }
  }

  private var list: some View {
    List(selection: selection) {
      ForEach(sections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.rows, id: \.paneKey) { row in
            ScheduleListRow(row: row)
              .tag(row.paneKey)
          }
        }
      }
    }
  }

  // MARK: Right

  @ViewBuilder private var detail: some View {
    if let selected {
      ScheduleDetail(row: selected)
    } else {
      ContentUnavailableView {
        Label("No schedule selected", systemImage: "calendar.badge.clock")
      } description: {
        Text("Select a schedule to see its prompt, when it runs next and where.")
      }
    }
  }

  private var subtitle: String {
    let count = model.rows.count
    let schedules = count == 1 ? "1 schedule" : "\(count) schedules"
    let active = model.activeCount
    return active == 0 ? schedules : "\(schedules) · \(active) active"
  }
}

/// One schedule in the list: its name, when it runs, and when next or that it is paused.
struct ScheduleListRow: View {
  let row: ScheduleRow

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: row.editable ? "calendar.badge.clock" : "lock")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .help(row.readOnlyReason ?? "")
        .accessibilityLabel("Read-only")
        .accessibilityHidden(row.editable)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .lineLimit(1)
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      ScheduleStatusText(row: row)
        .font(.caption)
    }
    .padding(.vertical, 2)
    .opacity(row.status == "active" ? 1 : 0.6)
  }

  private var caption: String {
    guard let cwd = row.cwd else { return row.summary }
    return "\(row.summary) · \(URL(filePath: cwd).lastPathComponent)"
  }
}

/// "in 9 hours", "Paused" or "Unknown": the one thing a glance at the list is for.
struct ScheduleStatusText: View {
  let row: ScheduleRow

  var body: some View {
    switch row.status {
    case "active":
      if let next = row.nextRunAt {
        Text(next, format: .relative(presentation: .named))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .help("Next run \(next.formatted(date: .abbreviated, time: .shortened))")
      } else {
        Text("Active").foregroundStyle(.secondary)
      }
    case "paused":
      Text("Paused").foregroundStyle(.tertiary)
    default:
      Text("Unknown").foregroundStyle(.tertiary)
    }
  }
}

/// A schedule: its prompt, when it runs, and where. Nothing on it changes the schedule.
struct ScheduleDetail: View {
  let row: ScheduleRow

  var body: some View {
    Form {
      Section {
        LabeledContent("Status") { ScheduleStatusText(row: row) }
        LabeledContent("Runs", value: row.summary)
        if let rule = row.rrule ?? row.cronExpression {
          LabeledContent("Rule") {
            Text(rule).textSelection(.enabled).font(.callout.monospaced())
          }
        }
        if let next = row.nextRunAt {
          LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
        }
        if let last = row.lastRunAt {
          LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .shortened))
        }
      }
      Section {
        LabeledContent("Vendor", value: row.vendor == "claude" ? "Claude app" : "Codex")
        LabeledContent("Account", value: row.account)
        if let cwd = row.cwd {
          LabeledContent("Folder") {
            Text(cwd).textSelection(.enabled).lineLimit(1).truncationMode(.head)
          }
        }
        if let model = row.model {
          LabeledContent(
            "Model", value: row.reasoningEffort.map { "\(model), \($0) effort" } ?? model)
        }
        LabeledContent("Id") { Text(row.id).textSelection(.enabled) }
      }
      if let prompt = row.prompt {
        Section("Prompt") {
          ScrollView {
            Text(prompt)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(minHeight: 120, maxHeight: 320)
        }
      }
      Section {
        if let reason = row.readOnlyReason {
          Label(reason, systemImage: "lock")
            .foregroundStyle(.secondary)
        }
        Text(
          "Ask Claude Code to change a schedule: it does so through Armada's MCP server, with Allow writes on."
        )
        .foregroundStyle(.secondary)
        if let folder {
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  /// The automation's own folder, for a Codex row whose home is still watched.
  private var folder: URL? {
    guard row.vendor == "codex", let home = CodexAccounts.shared.account(id: row.accountID)?.home
    else { return nil }
    return CodexAutomations(home: home).directory.appending(
      path: row.id, directoryHint: .isDirectory)
  }
}

extension ScheduleRow {
  /// Unique across homes and vendors: two Codex homes can each hold a `daily-report`.
  fileprivate var paneKey: String { "\(vendor):\(accountID):\(id)" }
}
