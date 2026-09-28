import SwiftUI

/// An account's plan windows at sidebar size: the menu bar panel's `CompactUsage` line for
/// each, label, figure, bar with its pace tick and projection, and the reset.
///
/// **The glance the usage strip above the session list used to be**, moved to the one place
/// that is on screen whatever the pane is showing, and for every account at once rather than
/// the one selected. The same line as the menu bar's rather than a sidebar variant, so the
/// two surfaces a person glances at read the same way. At the sidebar's 190pt floor the bar
/// is short, because every other column of the line is fixed; widening the sidebar gives the
/// width to the bar alone.
///
/// **Faded when the figures are in doubt**, at the moment `StalenessBadge` would warn about
/// them, because this row is the surface people glance at instead of opening the overview
/// that carries the badge. A window that has rolled over draws an empty track and "—", as
/// every other meter does.
struct SidebarUsage: View {
  struct Line: Identifiable {
    /// The label, "5h" or "7d", which is unique within one account.
    let id: String
    let window: UsageWindow
    /// What to pace the window against, and nil for a period with no length (Grok's
    /// monthly allowance), which gets no tick or projection.
    let length: UsageWindowLength?
  }

  let fetchedAt: Date?
  let source: UsageSnapshot.Source
  /// Asked again at each tick, so a window rolling over voids its bar with nothing else
  /// having changed.
  let lines: (Date) -> [Line]

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored

  var body: some View {
    // A minute, not the panes' second: the resets read "in 19h" and "in 2h", which move no
    // faster, and the sidebar is on screen for as long as the window is.
    TimelineView(.everyMinute) { _ in
      let now = AppClock.now
      let shown = lines(now)
      if !shown.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(shown) { line in
            CompactUsage(
              label: line.id, window: line.window, forecast: forecast(line, now: now), now: now)
          }
        }
        .padding(.top, 2)
        .opacity(StalenessBadge.isStale(fetchedAt: fetchedAt, source: source, now: now) ? 0.5 : 1)
      }
    }
  }

  /// The menu bar's forecast, guard included: nothing to project from a window a refusal has
  /// already closed.
  private func forecast(_ line: Line, now: Date) -> UsageForecast? {
    guard let length = line.length, line.window.rejectedAt == nil else { return nil }
    return UsageForecast(
      window: line.window, length: length,
      profile: PaceProfile(storedDays: storedWeights, storedHours: storedHours),
      asOf: fetchedAt, now: now)
  }
}

extension SidebarUsage {
  /// A Claude Code account's two windows, corrected by a refusal as the menu bar's are.
  init(account: Account) {
    let usage = account.usage.flatMap { $0.isEmpty ? nil : $0 }
    self.init(fetchedAt: usage?.fetchedAt, source: usage?.source ?? .cache) { now in
      guard let usage else { return [] }
      return [
        usage.window(.fiveHour, correctedBy: account.quotaHit, now: now).map {
          Line(id: "5h", window: $0, length: .fiveHour)
        },
        usage.window(.sevenDay, correctedBy: account.quotaHit, now: now).map {
          Line(id: "7d", window: $0, length: .sevenDay)
        },
      ].compactMap { $0 }
    }
  }

  /// A Codex home's two windows. Never faded: a Codex figure is as old as its turn, and only
  /// its window rolling over makes it wrong. See `StalenessBadge.staleAfter`.
  init(account: CodexAccount) {
    let snapshot = account.usage.flatMap { $0.isEmpty ? nil : $0.asSnapshot }
    self.init(fetchedAt: snapshot?.fetchedAt, source: .sessionLog) { _ in
      guard let snapshot else { return [] }
      return [
        snapshot.fiveHour.map { Line(id: "5h", window: $0, length: .fiveHour) },
        snapshot.sevenDay.map { Line(id: "7d", window: $0, length: .sevenDay) },
      ].compactMap { $0 }
    }
  }

  /// A Grok Build home's one allowance, labelled by its period. A period with no short name
  /// is left unlabelled rather than guessed at: one bar needs no label to tell it apart.
  init(account: GrokAccount) {
    let usage = account.usage
    self.init(fetchedAt: usage?.observedAt, source: .live) { _ in
      guard let usage else { return [] }
      let label =
        switch usage.period {
        case "weekly": "7d"
        case "monthly": "mo"
        default: ""
        }
      return [Line(id: label, window: usage.usage, length: usage.length)]
    }
  }
}

/// The layout every account row in the sidebar shares: the icon with the session count under
/// it, then the name and plan on one line with the eye and the working dot, then the usage bars.
///
/// **The count sits under the icon, not in the trailing badge.** A `List` badge takes a
/// column at the trailing edge of the whole row, bars included, and at the sidebar's floor
/// that column was width the bars were short of. Under the icon it uses the height the bars
/// already added to the row, and the bars run to the edge. Hidden at zero, as a badge is.
///
/// One view rather than three copies because the rows differ only in what they count and
/// how they tint the dot; see each caller for what its count means.
struct SidebarAccountRow<Icon: View>: View {
  let accountID: String
  let name: String
  let plan: String?
  let path: String
  let count: Int
  /// The count's tooltip, which is where each vendor says what it counts.
  let countHelp: String
  let working: Int
  let workingTint: Color
  let usage: SidebarUsage
  @ViewBuilder let icon: () -> Icon

  @State private var hovering = false

  /// Wide enough for the 18pt icon and a two-digit count. A third digit scales down rather
  /// than widening one row's column and pushing its name out of line with the others.
  private static var leadingWidth: CGFloat { 20 }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(spacing: 2) {
        icon()
        if count > 0 {
          Text(count, format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .help(countHelp)
            .accessibilityLabel(countHelp)
        }
      }
      .frame(width: Self.leadingWidth)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          // The plan rides the name's line, as it does in the menu bar panel's account row:
          // the bars under it already make the row taller, and a line of its own for one
          // word was the rest of that height. The name truncates first, because the plan is
          // the shorter of the two and the part that tells two accounts of one organization
          // apart.
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
              .lineLimit(1)
            if let plan {
              Text("• \(plan)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
          }
          .help(path)
          Spacer(minLength: 4)
          PanelVisibilityEye(accountID: accountID, rowHovered: hovering)
          // A dot rather than a second number: the count is already under the icon, and
          // what you want at a glance is whether anything in there is moving.
          if working > 0 {
            Circle()
              .fill(workingTint)
              .frame(width: 6, height: 6)
              .help("\(working) working")
          }
        }
        usage
      }
    }
    .onHover { hovering = $0 }
  }
}
