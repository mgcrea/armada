import Combine
import SwiftUI

/// One account: what its plan limits look like, and what its sessions are doing.
///
/// Usage sits above the list rather than in a pane of its own. Two numbers do not
/// justify a second row in the sidebar, and they are the context you want *while*
/// reading the session list — "nineteen sessions" and "69% of the weekly window"
/// are the same sentence.
struct AccountPaneView: View {
  let account: Account

  @State private var selection: String?
  @State private var now = Date()
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    // The header is a sibling above the list, not a `safeAreaInset` on it. As an
    // inset it floats and the list scrolls under — which looks right at rest and
    // clips the first row on arrival, because the list starts at the container's
    // top rather than below the strip.
    VStack(spacing: 0) {
      UsageHeader(account: account, now: now)
      if account.sessions.sessions.isEmpty {
        ContentUnavailableView {
          Label("No sessions", systemImage: "sailboat")
        } description: {
          Text(
            "Nothing is running in \(account.displayName). Start Claude Code and it appears here within a moment."
          )
        }
      } else {
        List(account.sessions.sessions, selection: $selection) { session in
          SessionRow(session: session, now: now)
            .tag(session.id)
        }
        // On the `List`, not on `SessionRow`. A row-level `.contextMenu` does not
        // move the List's selection, so right-clicking an unselected row opens a
        // menu that acts on whatever was selected before — which here would focus
        // the wrong session. This form hands over the right-clicked item instead.
        //
        // The type has to match the row's `tag` exactly. Rows tag `session.id`, a
        // `String`; a mismatch compiles and the menu silently never appears.
        //
        // No `primaryAction:`: double-clicking a row stays plain selection.
        .contextMenu(forSelectionType: String.self) { ids in
          // Built on demand, so this is one cached lookup per right-click.
          if let session = session(for: ids),
            let host = SessionHostLookup.host(for: session.registry)
          {
            Button("Focus in \(host.name)") { FocusSession.focus(host) }
          }
        }
      }
    }
    .inspector(isPresented: .constant(true)) {
      SessionDetail(session: selected, account: account)
        .inspectorColumnWidth(min: 240, ideal: 280)
    }
    .navigationTitle(account.displayName)
    .navigationSubtitle(subtitle)
    .onReceive(clock) { now = $0 }
    // A session ending should not leave the inspector on a row that is gone.
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
  }

  private var selected: Session? {
    account.sessions.sessions.first { $0.id == selection } ?? account.sessions.sessions.first
  }

  /// The one session a context menu is about. Selection here is single, so a set of
  /// anything but one row is a click on empty space and has no session behind it.
  private func session(for ids: Set<String>) -> Session? {
    guard let id = ids.first, ids.count == 1 else { return nil }
    return account.sessions.sessions.first { $0.id == id }
  }

  private var subtitle: String {
    let count = account.sessions.sessions.count
    let sessions = count == 1 ? "1 session" : "\(count) sessions"
    guard let plan = account.planLabel else { return sessions }
    return "\(plan) · \(sessions)"
  }
}

/// The two plan windows, as a strip above the session list.
struct UsageHeader: View {
  let account: Account
  let now: Date

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 24) {
        if let usage = account.usage, !usage.isEmpty {
          // See `UsageSnapshot.window(_:correctedBy:now:)`: a refusal newer than the
          // cache overrules it, and nothing else does.
          let five = usage.window(.fiveHour, correctedBy: account.quotaHit, now: now)
          let seven = usage.window(.sevenDay, correctedBy: account.quotaHit, now: now)
          CompactMeter(
            title: "Session", subtitle: "5 hours", window: five,
            forecast: forecast(five, .fiveHour, usage.fetchedAt), now: now)
          CompactMeter(
            title: "Weekly", subtitle: "7 days", window: seven,
            forecast: forecast(seven, .sevenDay, usage.fetchedAt), now: now)
          Spacer(minLength: 0)
          StalenessBadge(fetchedAt: usage.fetchedAt, now: now, source: usage.source)
        } else {
          Label(
            account.didReadUsage ? "No usage data yet" : "Reading usage…",
            systemImage: "gauge.with.dots.needle.bottom.50percent"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
    }
    .background(.bar)
  }

  private func forecast(
    _ window: UsageWindow?, _ length: UsageWindowLength, _ fetchedAt: Date?
  ) -> UsageForecast? {
    // Nothing to project from a window a refusal has already closed.
    guard let window, window.rejectedAt == nil else { return nil }
    return UsageForecast(
      window: window, length: length, weights: DayWeights(stored: storedWeights),
      asOf: fetchedAt, now: now)
  }
}

/// A meter sized for the header strip.
struct CompactMeter: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let window: UsageWindow?
  var forecast: UsageForecast?
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
      }
      if let window {
        HStack(spacing: 8) {
          UsageFigure(window: window, now: now, font: .title3)
          // 9pt rather than the 6pt default, which is the size this strip has always
          // rendered at: the pace tick used to inflate the track it sat in by 3pt,
          // and the number here was tuned by eye against a bar that was already
          // taller than it said. The tick no longer resizes anything, so the height
          // has to say what it meant.
          UsageBar(
            percent: window.utilization, forecast: forecast, height: 9,
            voided: window.hasRolled(asOf: now)
          )
          .frame(width: 110)
        }
        UsageFootnote(window: window, forecast: forecast, now: now)
      } else {
        Text("—").foregroundStyle(.secondary)
      }
    }
  }
}

enum UsageTint {
  static func `for`(_ percent: Int) -> Color {
    switch percent {
    case ..<70: .green
    case ..<90: .orange
    default: .red
    }
  }
}

/// How old these figures are, and whether their age is even a worry.
///
/// **Both sources date their readings, and the date means opposite things.** A
/// `.live` figure was asked for and answered — its age is how long ago Armada last
/// asked, and a few minutes of it is nothing. A `.cache` figure is a copy Claude
/// Code left behind whenever it last felt like it, measured at 95 minutes old on
/// 2026-09-11 while sessions were running in the same folder, and its age is the
/// warning. So the wording and the threshold both turn on the source: silence about
/// a stale cache is the one way this can actively mislead, and a warning triangle
/// over a two-minute-old live reading is the way it cries wolf.
struct StalenessBadge: View {
  let fetchedAt: Date?
  let now: Date
  var source: UsageSnapshot.Source = .cache
  var style: Style = .full

  /// `.compact` is the popover's. The two-line stack below is sized for a header
  /// strip with a `Spacer` in front of it and does not belong in a 320pt panel, but
  /// the panel is exactly where the age was missing — it was the one surface showing
  /// a percentage with nothing to say how old it was. One tertiary line, and the
  /// same thresholds, so the two surfaces cannot disagree about what "stale" means.
  enum Style { case full, compact }

  private static let fresh: TimeInterval = 5 * 60
  private static let stale: TimeInterval = 60 * 60

  /// A live reading only goes doubtful once the probe has been failing long enough
  /// that something is wrong — `claude` moved, or every attempt has timed out.
  /// Comfortably past `Accounts.probeInterval`, so an ordinary gap never trips it.
  private static let liveStale: TimeInterval = 15 * 60

  private var staleAfter: TimeInterval { source == .live ? Self.liveStale : Self.stale }

  var body: some View {
    if let fetchedAt {
      let age = now.timeIntervalSince(fetchedAt)
      HStack(spacing: 5) {
        if age > staleAfter {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(style == .full ? nil : .caption2)
        }
        if style == .full {
          VStack(alignment: .trailing, spacing: 2) {
            Text("as of").font(.caption2).foregroundStyle(.tertiary)
            Text(fetchedAt, format: .relative(presentation: .named))
              .font(.caption)
              .foregroundStyle(age > Self.fresh ? .secondary : .primary)
          }
        } else {
          Text(
            "\(source == .live ? "checked" : "figures from") \(fetchedAt, format: .relative(presentation: .named))"
          )
          .font(.caption2)
          .foregroundStyle(
            age > staleAfter ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
          )
          .lineLimit(1)
        }
      }
      .help(help(age: age))
    }
  }

  private func help(age: TimeInterval) -> String {
    switch (source, age > staleAfter) {
    case (.live, false):
      "Asked your account directly, through Claude Code."
    case (.live, true):
      "Armada has not been able to reach Claude Code for a while, so these figures may be behind."
    case (.cache, false):
      "Read from Claude Code's usage cache."
    case (.cache, true):
      "Claude Code refreshes this cache when it next talks to the API, so these figures may be behind."
    }
  }
}
