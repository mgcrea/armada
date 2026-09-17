import Combine
import SwiftUI

/// One Grok Build home: what its sessions have been doing.
///
/// Laid out like `CodexPaneView`: the allowance strip and a session list, beside a detail.
struct GrokPaneView: View {
  let account: GrokAccount

  @State private var selection: String?
  @State private var now = Date()
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
    .newSessionFailureAlert()
    .onReceive(clock) { now = $0 }
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
    .onAppear { applyRoute() }
    .onChange(of: route.token) { applyRoute() }
  }

  /// Take the session the menu bar panel asked for, if it asked for one here.
  private func applyRoute() {
    guard let id = route.takeSession(in: .grok(account.id)) else { return }
    selection = id
  }

  private var sessions: some View {
    VStack(spacing: 0) {
      GrokUsageHeader(account: account, now: now)
      sessionList
    }
  }

  @ViewBuilder private var sessionList: some View {
    if account.sessions.sessions.isEmpty {
      ContentUnavailableView {
        Label(
          account.sessions.didScan ? "No recent sessions" : "Reading sessions…",
          systemImage: "sailboat")
      } description: {
        Text(
          "Nothing has run in \(account.displayName) in the last 12 hours. Start a Grok Build session and it appears here within a moment."
        )
      }
    } else {
      List(account.sessions.sessions, selection: $selection) { session in
        GrokSessionRow(session: session, now: now)
          .tag(session.id)
      }
      // Ordered as in `CodexPaneView`, so the menu a person learns is the same in every pane.
      .contextMenu(forSelectionType: String.self) { ids in
        if let id = ids.first, ids.count == 1,
          let session = account.sessions.sessions.first(where: { $0.id == id }),
          !session.summary.cwd.isEmpty
        {
          Button("New Session in \(session.summary.projectName)") {
            NewSessionLauncher.shared.start(
              .grok(account.home),
              in: URL(filePath: session.summary.cwd, directoryHint: .isDirectory))
          }
          if let target = ForkAvailability.grok(session, in: account).target {
            Button("Fork Session") {
              NewSessionLauncher.shared.start(
                target.agent, in: target.project, start: target.start)
            }
          }
          Divider()
          ProjectContextButton(path: session.summary.cwd, agent: .grok(homeID: account.id))
        }
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let selected = account.sessions.sessions.first(where: { $0.id == selection }) {
      GrokSessionDetail(session: selected, now: now)
    } else {
      GrokOverview(account: account)
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

/// One Grok Build home's block in the menu bar popover: live sessions and the allowance.
///
/// `CodexSummary`'s shape, line for line, so the blocks read as the same thing for another
/// vendor. A row opens Armada's pane rather than a host window; focusing the terminal a TUI
/// session runs in is not wired up for Grok yet.
struct GrokSummary: View {
  let account: GrokAccount
  let showsName: Bool
  let now: Date

  private static let visibleSessions = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      PanelRow(help: "Show \(account.displayName) in Armada") {
        MenuBarPanel.dismiss()
        MainWindowRoute.shared.open(.grok(account.id))
      } label: {
        if showsName {
          HStack(spacing: 6) {
            GrokIconView(size: 14)
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
          MainWindowRoute.shared.open(.grok(account.id), session: session.id)
        } label: {
          HStack(spacing: 6) {
            GrokStateDot(state: session.state)
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

      if let usage = account.usage {
        CompactUsage(
          label: usage.length == .sevenDay ? "7d" : "Plan", window: usage.usage, forecast: nil,
          now: now
        )
        .padding(.top, 2)
      }
    }
  }

  private var live: [GrokSession] { account.sessions.liveSessions }

  private var summary: String {
    let recent = account.sessions.sessions.count
    if live.isEmpty {
      return recent == 0 ? "No recent sessions" : "Nothing running, \(recent) today"
    }
    return live.count == 1 ? "1 session open" : "\(live.count) sessions open"
  }
}

/// The allowance, as `GrokControl` last read it.
///
/// One meter, because Grok has one window: a unified weekly (or, on some plans, monthly) credit
/// allowance shared by every model. It is a live answer, like the Claude probe's, so its age
/// shows in the corner the way `UsageHeader` shows one.
struct GrokUsageHeader: View {
  let account: GrokAccount
  let now: Date

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored

  var body: some View {
    UsageStrip {
      if let usage = account.usage {
        CompactMeter(
          title: usage.length == .sevenDay ? "Weekly" : "Allowance",
          subtitle: usage.length == .sevenDay ? "7 days" : LocalizedStringKey(usage.period ?? ""),
          window: usage.usage,
          forecast: usage.length.map {
            UsageForecast(
              window: usage.usage, length: $0,
              profile: PaceProfile(storedDays: storedWeights, storedHours: storedHours),
              asOf: usage.observedAt, now: now)
          } ?? nil,
          now: now,
          menuBarLimit: usage.length.map { MenuBarLimit(accountID: account.id, length: $0) })
      } else {
        Label("Reading usage…", systemImage: "gauge.with.dots.needle.bottom.50percent")
          .font(.callout)
          .foregroundStyle(.secondary)
          .help("Armada asks your own grok for the allowance every few minutes.")
      }
    } status: {
      if let usage = account.usage {
        StalenessBadge(fetchedAt: usage.observedAt, now: now, source: .live, style: .inline)
      }
    }
  }
}

struct GrokSessionRow: View {
  let session: GrokSession
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      GrokStateDot(state: session.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(session.summary.projectName)
          if session.isHeadless {
            Text("·")
            Text("Headless")
          }
          if session.isFork {
            Text("·")
            Text("Fork")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        if let last = session.lastEventAt ?? session.summary.updatedAt {
          Text(SessionRow.elapsed(from: last, to: now))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help(session.state.isLive ? "Age of the last event" : "Ended this long ago")
        }
        // Context in use, as the other panes show, never the lifetime total.
        if let context = session.context {
          Text(TokenCount.short(context.used))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct GrokSessionDetail: View {
  let session: GrokSession
  let now: Date

  var body: some View {
    Form {
      Section {
        LabeledContent("State") {
          HStack(spacing: 4) {
            GrokStateDot(state: session.state)
            Text(session.state.label)
          }
        }
        LabeledContent("Folder", value: session.summary.cwd)
        if let model = session.summary.model {
          LabeledContent("Model", value: model)
        }
        if let pid = session.pid {
          LabeledContent("Process", value: String(pid))
        }
        if let created = session.summary.createdAt {
          LabeledContent("Started") {
            Text(created, format: .relative(presentation: .named))
          }
        }
      } header: {
        Text(session.displayName)
      }
      if let context = session.context {
        Section("Context") {
          ProgressView(value: Double(min(context.used, context.window)), total: Double(context.window))
          LabeledContent(
            "In use",
            value: "\(TokenCount.short(context.used)) of \(TokenCount.short(context.window))")
        }
      }
      if let usage = session.usage {
        Section("This session") {
          LabeledContent("Turns", value: String(usage.turnCount))
          LabeledContent("Tokens", value: TokenCount.short(usage.totalTokens))
          LabeledContent("Cost", value: usage.costUSD.formatted(.currency(code: "USD")))
        }
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
struct GrokOverview: View {
  let account: GrokAccount

  var body: some View {
    Form {
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

struct GrokStateDot: View {
  let state: GrokSessionState

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: 8, height: 8)
      .frame(width: 14, height: 14)
      .help(state.label)
      .accessibilityLabel(state.label)
  }
}

/// One Grok Build home in the sidebar. The badge counts live sessions, as `CodexSidebarRow`'s does.
struct GrokSidebarRow: View {
  let account: GrokAccount
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      GrokIconView(size: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(account.displayName)
          .lineLimit(1)
        if let plan = account.planLabel {
          Text(plan)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .help(account.displayPath)
      Spacer(minLength: 4)
      PanelVisibilityEye(accountID: account.id, rowHovered: hovering)
      if account.sessions.workingCount > 0 {
        Circle()
          .fill(GrokSessionState.working.tint)
          .frame(width: 6, height: 6)
          .help("\(account.sessions.workingCount) working")
      }
    }
    .badge(account.sessions.liveSessions.count)
    .onHover { hovering = $0 }
  }
}

/// The Grok app icon, bundled in `Assets.xcassets` as `GrokIcon`.
///
/// The one exception to `VendorIcon`'s no-bundled-artwork rule. Grok Build is a terminal program
/// with no app bundle to ask for, and the Grok.app people do install is a Safari web app whose
/// bundle id is a per-install UUID under `com.apple.Safari.WebApp`, so there is nothing stable to
/// look up. The artwork is that web app's own icon, as grok.com serves it.
struct GrokIconView: View {
  var size: CGFloat = 16

  var body: some View {
    Image("GrokIcon")
      .resizable()
      .frame(width: size, height: size)
  }
}
