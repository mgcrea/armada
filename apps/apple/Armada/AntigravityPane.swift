import Combine
import SwiftUI

/// The Antigravity CLI home: what its conversations have been doing.
///
/// `GrokPaneView`'s layout without what `agy` does not have or Armada does not do for it yet:
/// no fork and no headless runs. An ended conversation resumes in place (`agy --conversation=<id>`):
/// no process holds it, so there is no second writer to fear.
struct AntigravityPaneView: View {
  let account: AntigravityAccount

  @State private var selection: String?
  /// The row a route asked for, until the list has scrolled to it.
  @State private var scrollTarget: String?
  @State private var now = AppClock.now
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  @State private var route = MainWindowRoute.shared

  var body: some View {
    HSplitView {
      GeometryReader { _ in sessions }
        .frame(minWidth: 320, idealWidth: 420)
      GeometryReader { _ in detail }
        .frame(minWidth: 300, idealWidth: 340)
    }
    .navigationTitle(account.displayName)
    .navigationSubtitle(subtitle)
    .toolbar {
      NewSessionToolbarItem(
        agent: .antigravity(account.home), suggestion: account.recentProjects.first?.url)
    }
    .onReceive(clock) { _ in now = AppClock.now }
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
    .onAppear { applyRoute() }
    .onChange(of: route.token) { applyRoute() }
  }

  /// Take the session the menu bar panel asked for, if it asked for one here.
  private func applyRoute() {
    guard let id = route.takeSession(in: .antigravity(account.id)) else { return }
    selection = id
    scrollTarget = id
  }

  @ViewBuilder private var sessions: some View {
    if account.sessions.sessions.isEmpty {
      ContentUnavailableView {
        Label(
          account.sessions.didScan ? "No recent sessions" : "Reading sessions…",
          systemImage: "sailboat")
      } description: {
        Text(
          "Nothing has run in \(account.displayName) in the last 12 hours. Start a conversation with agy and it appears here within a moment."
        )
      }
    } else {
      // Scrolled to as well as selected, as in `GrokPaneView`: the panel lists live sessions
      // only, so the row it sends here can be anywhere in the day's list.
      ScrollViewReader { proxy in
        List(account.sessions.sessions, selection: $selection) { session in
          AntigravitySessionRow(session: session, now: now)
            .tag(session.id)
        }
        // Ordered as in `GrokPaneView`, with Resume where Fork is there.
        .contextMenu(forSelectionType: String.self) { ids in
          if let id = ids.first, ids.count == 1,
            let session = account.sessions.sessions.first(where: { $0.id == id })
          {
            if !session.cwd.isEmpty {
              let folder = URL(filePath: session.cwd, directoryHint: .isDirectory)
              Button("New Session in \(session.projectName)") {
                NewSessionLauncher.shared.start(.antigravity(account.home), in: folder)
              }
              if !session.state.isLive {
                Button("Resume Session") {
                  NewSessionLauncher.shared.start(
                    .antigravity(account.home), in: folder, start: .resume(sessionID: session.id))
                }
              }
              Divider()
            }
            CopySessionIDButton(id: session.id)
            ProjectContextButton(path: session.cwd, agent: .antigravity(homeID: account.id))
          }
        }
        .onChange(of: scrollTarget) { _, target in
          guard let target else { return }
          scrollTarget = nil
          proxy.scrollTo(target, anchor: .center)
        }
        // A route that arrived while there was no list yet, before the first scan.
        .onAppear {
          guard let target = scrollTarget else { return }
          scrollTarget = nil
          proxy.scrollTo(target, anchor: .center)
        }
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let selected = account.sessions.sessions.first(where: { $0.id == selection }) {
      AntigravitySessionDetail(session: selected, now: now)
    } else {
      AntigravityOverview(account: account, now: now)
    }
  }

  private var subtitle: String {
    let live = account.sessions.liveSessions.count
    let total = account.sessions.sessions.count
    let recent = total == 1 ? "1 recent session" : "\(total) recent sessions"
    let head = account.planLabel.map { "\($0) · " } ?? ""
    return live == 0 ? "\(head)\(recent)" : "\(head)\(live) live · \(recent)"
  }
}

/// The Antigravity CLI home's block in the menu bar popover: live sessions and peak quotas.
struct AntigravitySummary: View {
  let account: AntigravityAccount
  let showsName: Bool
  let now: Date

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored

  private static let visibleSessions = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      PanelRow(help: "Show \(account.displayName) in Armada") {
        MenuBarPanel.dismiss()
        MainWindowRoute.shared.open(.antigravity(account.id))
      } label: {
        if showsName {
          HStack(spacing: 6) {
            AntigravityIconView(size: 14)
            Text(account.displayName)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            Text("• \(summary)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
            if let plan = account.planLabel {
              Text(plan)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Text(summary)
            .font(.callout)
            .foregroundStyle(live.isEmpty ? .secondary : .primary)
        }
      }

      ForEach(live.prefix(Self.visibleSessions)) { session in
        PanelRow(help: "Show \(session.displayName) in Armada") {
          MenuBarPanel.dismiss()
          MainWindowRoute.shared.open(.antigravity(account.id), session: session.id)
        } label: {
          HStack(spacing: 6) {
            AntigravityStateDot(state: session.state)
            Text(session.displayName)
              .font(.caption)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
        }
      }
      if live.count > Self.visibleSessions {
        Text("and \(live.count - Self.visibleSessions) more")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let usage = account.usage, !usage.isEmpty {
        let five = usage.peakWindow(.fiveHour, at: now)
        let seven = usage.peakWindow(.sevenDay, at: now)
        let fiveHour = forecast(five, .fiveHour, usage.observedAt)
        let sevenDay = forecast(seven, .sevenDay, usage.observedAt)
        if five != nil || seven != nil {
          VStack(alignment: .leading, spacing: 3) {
            if let five {
              CompactUsage(label: "5h", window: five, forecast: fiveHour, now: now)
            }
            if let seven {
              CompactUsage(label: "7d", window: seven, forecast: sevenDay, now: now)
            }
          }
          .padding(.top, 2)
          StalenessBadge(
            fetchedAt: usage.observedAt, now: now, source: .antigravity, style: .compact)
          if let sevenDay, sevenDay.isNoteworthy {
            UsageVerdictLine(forecast: sevenDay)
          }
        }
      }
    }
  }

  private var live: [AntigravitySession] { account.sessions.liveSessions }

  private func forecast(
    _ window: UsageWindow?, _ length: UsageWindowLength, _ observedAt: Date
  ) -> UsageForecast? {
    guard let window else { return nil }
    return UsageForecast(
      window: window, length: length,
      profile: PaceProfile(storedDays: storedWeights, storedHours: storedHours),
      asOf: observedAt, now: now)
  }

  private var summary: String {
    let recent = account.sessions.sessions.count
    if live.isEmpty {
      return recent == 0 ? "No recent sessions" : "Nothing running, \(recent) today"
    }
    return live.count == 1 ? "1 session open" : "\(live.count) sessions open"
  }
}

struct AntigravitySessionRow: View {
  let session: AntigravitySession
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      AntigravityStateDot(state: session.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(session.projectName)
          if let model = session.model {
            Text("·")
            Text(model)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        if let last = session.lastActivity {
          Text(SessionRow.elapsed(from: last, to: now))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help(session.state.isLive ? "Age of the last event" : "Ended this long ago")
        }
        // The lifetime total: `agy`'s transcript gives no context window to measure against.
        if session.totalTokens > 0 {
          Text(TokenCount.short(session.totalTokens))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help("Tokens this session")
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct AntigravitySessionDetail: View {
  let session: AntigravitySession
  let now: Date

  var body: some View {
    Form {
      Section {
        LabeledContent("State") {
          HStack(spacing: 4) {
            AntigravityStateDot(state: session.state)
            Text(session.state.label)
          }
        }
        LabeledContent("Folder", value: session.cwd.isEmpty ? session.projectName : session.cwd)
        if let model = session.model {
          LabeledContent("Model", value: model)
        }
        if let pid = session.pid {
          LabeledContent("Process", value: String(pid))
        }
        if let last = session.lastActivity {
          LabeledContent("Last activity") {
            Text(last, format: .clockRelative(presentation: .named))
          }
        }
      } header: {
        Text(session.displayName)
      }
      Section("This session") {
        LabeledContent("Tokens", value: TokenCount.short(session.totalTokens))
      }
      Section {
        LabeledContent("Session ID") {
          Text(session.id).textSelection(.enabled).font(.caption.monospaced())
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// The home itself, with nothing selected.
struct AntigravityOverview: View {
  let account: AntigravityAccount
  let now: Date

  var body: some View {
    Form {
      let rows = account.usage.map { account.windowRows(for: $0) } ?? []
      OverviewUsageSection(
        accountID: account.id,
        rows: rows,
        week: account.usage?.primaryWindow(.sevenDay),
        fetchedAt: account.usage?.observedAt, now: now,
        empty: "Reading usage…"
      ) {
        if let usage = account.usage {
          StalenessBadge(
            fetchedAt: usage.observedAt, now: now, source: .antigravity, style: .inline)
        }
      }
      Section {
        LabeledContent("Folder", value: account.displayPath)
        LabeledContent("Live sessions", value: String(account.sessions.liveSessions.count))
        LabeledContent("Working", value: String(account.sessions.workingCount))
      }
      if let plan = account.planLabel {
        Section {
          LabeledContent("Plan", value: plan)
        }
      }
    }
    .formStyle(.grouped)
  }
}

struct AntigravityStateDot: View {
  let state: AntigravitySessionState

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: 8, height: 8)
      .frame(width: 14, height: 14)
      .help(state.label)
      .accessibilityLabel(state.label)
  }
}

/// The Antigravity CLI home in the sidebar. The count counts live sessions, as `GrokSidebarRow`'s
/// does.
struct AntigravitySidebarRow: View {
  let account: AntigravityAccount

  var body: some View {
    let live = account.sessions.liveSessions.count
    SidebarAccountRow(
      accountID: account.id, name: account.displayName, plan: account.planLabel,
      path: account.displayPath, count: live,
      countHelp: live == 1 ? "1 live session" : "\(live) live sessions",
      working: account.sessions.workingCount, workingTint: AntigravitySessionState.working.tint,
      usage: SidebarUsage(account: account)
    ) {
      AntigravityIconView(size: 18)
    }
  }
}

/// A system symbol rather than bundled artwork: `agy` is a terminal program with no app bundle
/// for `VendorIcon` to ask, and Armada ships no third-party artwork it does not have to.
struct AntigravityIconView: View {
  var size: CGFloat = 16

  var body: some View {
    Image(systemName: "atom")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
  }
}
