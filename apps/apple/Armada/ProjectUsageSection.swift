import SwiftUI

/// What has been spent in a project: tokens by kind over a chosen window, then the same by
/// model, by account and by subfolder.
///
/// **Tokens, never money.** Transcripts record what was used, not what it cost, and a price
/// table would be a guess that goes stale — the app's rule is to read figures, not estimate
/// them.
struct ProjectUsageSection: View {
  let project: Project

  @State private var index = UsageIndex.shared
  @State private var store = ProjectStore.shared
  @State private var accounts = Accounts.shared
  @State private var codex = CodexAccounts.shared
  @AppStorage("armada.projectStatsWindow") private var storedWindow = StatsWindow.week.rawValue

  private var window: StatsWindow { StatsWindow(rawValue: storedWindow) ?? .week }

  var body: some View {
    let usage = index.projectUsage(store: store)[project.id]
    let tokens = usage?.tokens[window] ?? TokenTally()

    Section {
      Picker("Window", selection: $storedWindow) {
        ForEach(StatsWindow.allCases, id: \.self) { window in
          Text(window.title).tag(window.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if let progress = index.progress, progress.firstPass || progress.filesTotal > 50 {
        ProgressView(
          value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1))
        ) {
          Text(
            "Reading transcripts: \(progress.filesDone.formatted()) of \(progress.filesTotal.formatted()) files"
          )
          .font(.caption)
        }
      }

      if tokens.isZero {
        Text(
          index.ledger.firstPassDone
            ? "No tokens were spent here in this window."
            : "Still reading transcripts. The newest are read first."
        )
        .foregroundStyle(.secondary)
      } else {
        LabeledContent("Tokens", value: TokenCount.short(tokens.total))
          .help(
            "Fresh input, cache writes, cache reads and output added together. Cache reads are the conversation so far, read again on every turn, which is why they dominate."
          )
        LabeledContent("Fresh input", value: TokenCount.short(tokens.fresh))
        LabeledContent("Cache writes", value: TokenCount.short(tokens.cacheWrite))
        LabeledContent("Cache reads", value: TokenCount.short(tokens.cacheRead))
        LabeledContent(
          "Output",
          value: tokens.reasoning > 0
            ? "\(TokenCount.short(tokens.output)), \(TokenCount.short(tokens.reasoning)) reasoning"
            : TokenCount.short(tokens.output))
        LabeledContent("Sessions", value: (usage?.sessions[window] ?? 0).formatted())
        if let last = usage?.lastActive {
          LabeledContent("Last active") {
            Text(last, format: .relative(presentation: .named))
          }
        }
      }
    } header: {
      Text("Usage")
    } footer: {
      Text(footer)
    }

    if let usage, !tokens.isZero {
      slices("By model", usage.byModel) { $0.key }
      slices("By account", usage.byAccount) { accountName($0) }
      if usage.byFolder.count > 1 {
        slices("Folders", Array(usage.byFolder.prefix(8))) {
          $0.key.isEmpty ? "This folder" : $0.key
        }
      }
    }
  }

  @ViewBuilder
  private func slices(
    _ title: String, _ slices: [ProjectUsage.Slice],
    label: @escaping (ProjectUsage.Slice) -> String
  ) -> some View {
    let shown = slices.filter { !($0.tokens[window]?.isZero ?? true) }
    if !shown.isEmpty {
      Section(title) {
        ForEach(shown) { slice in
          LabeledContent(label(slice), value: TokenCount.short(slice.tokens[window]?.total ?? 0))
        }
      }
    }
  }

  private func accountName(_ slice: ProjectUsage.Slice) -> String {
    let vendor = slice.vendor?.name ?? ""
    if let account = accounts.account(id: slice.key) {
      return "\(vendor) on \(account.displayName)"
    }
    if let home = codex.account(id: slice.key) { return "\(vendor) on \(home.displayName)" }
    let path = (slice.key as NSString).abbreviatingWithTildeInPath
    return "\(vendor) on \(path), not on this Mac"
  }

  private var footer: String {
    var text =
      "Read from the transcripts on this Mac, each response counted once. Claude Code removes transcripts after 30 days by default; Armada keeps what it has read."
    if let day = index.ledger.earliestDay, let date = LocalDay.date(day, calendar: .current) {
      text += " History starts \(date.formatted(date: .abbreviated, time: .omitted))."
    }
    return text
  }
}
