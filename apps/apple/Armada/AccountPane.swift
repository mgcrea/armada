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

  @State private var route = MainWindowRoute.shared

  /// A row the panel asked for, waiting for the list to scroll to it. Separate from
  /// `selection` so that an ordinary click — which selects a row that is already on
  /// screen — never scrolls under the reader's cursor.
  @State private var scrollTarget: String?

  /// Each row's Focus glyph, by session id. Absent for a session with no host.
  @State private var focusMarkers: [String: FocusMarker] = [:]

  /// Bumped when Armada comes back to the front, to re-ask what Focus reaches: that is
  /// the moment someone has been opening and closing tabs somewhere else.
  @State private var focusEpoch = 0

  // Shared with `CodexPaneView`, deliberately: this is one preference — how I like my
  // sessions listed — and two keys would mean parameterising `SessionSortMenu` and
  // letting the two panes drift. The defaults come from the enums rather than being
  // typed out, so a fresh install cannot show one order with a checkmark on another.
  @AppStorage(SessionSort.defaultsKey) private var storedSort = SessionSort.fallback.stored
  @AppStorage(SessionGrouping.defaultsKey)
  private var storedGrouping = SessionGrouping.fallback.stored

  private var sort: SessionSort { SessionSort(stored: storedSort) }
  private var grouping: SessionGrouping { SessionGrouping(stored: storedGrouping) }

  var body: some View {
    // A split view rather than an `.inspector`. The inspector is a system-owned
    // column sized for a few labels, and the context panel is the opposite of that:
    // a bar, a headline, two captions and a table, which at 280pt wrapped into an
    // unreadable stack. `HSplitView` makes the detail a first-class half of the
    // pane, with a divider the reader can move, and it cannot be collapsed away by
    // something outside this view.
    //
    // **`OpeningResizeGuard` is what makes this safe** — `HostedWindow` already
    // pins the window's frame for 750ms against SwiftUI resizing a hosted
    // `NavigationSplitView` on its own. Without it, changing the pane's internal
    // layout moves SwiftUI's idea of the fitting size and the window jumps on open.
    //
    // **Each pane sits in a `GeometryReader`, and that is what holds the divider
    // still.** Without one, a pane whose root view changes branch collapses for a
    // layout pass, and `NSSplitView` clamps it back to its `minWidth` and hands every
    // other point to the far side. Measured 2026-09-14 on a 1728pt window: 973/755
    // before selecting a row, then 100, 0, and 1427/300 once the detail had swapped
    // `AccountOverview` for `SessionDetail`. A list left at its 320pt floor beside a
    // 1,200pt form is the mirror image. A `GeometryReader` takes whatever width it is
    // offered and never reports its content's, so a swap inside it does not reach
    // the split.
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
    // When the rows change and when Armada is activated, never on the clock: every
    // answer is Accessibility IPC with the windows the sessions sit in.
    .task(id: account.sessions.sessions.map(\.id) + ["\(focusEpoch)"]) {
      let sessions = account.sessions.sessions
      let resolved = await FocusSession.resolve(sessions)
      var markers: [String: FocusMarker] = [:]
      for session in sessions {
        guard let host = resolved.hosts[session.registry.pid] ?? nil,
          let reach = resolved.reaches[session.id]
        else { continue }
        markers[session.id] = FocusMarker(reach: reach, hostName: host.name)
      }
      focusMarkers = markers
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      focusEpoch += 1
    }
    // A session ending should not leave the detail on a row that is gone.
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
    // Both, because either can be the one that runs. Clicking a row in the panel for
    // the account already on screen changes nothing about this view's identity, so
    // only `onChange` fires; clicking one for a different account rebuilds the pane
    // — `MainWindowView` keys it on the account id — so only `onAppear` does.
    .onAppear { applyRoute() }
    .onChange(of: route.token) { applyRoute() }
  }

  /// Take the session the menu bar panel asked for, if it asked for one here.
  private func applyRoute() {
    guard let id = route.takeSession(in: .account(account.id)) else { return }
    selection = id
    scrollTarget = id
  }

  /// The left half: the usage strip and the session list.
  private var sessions: some View {
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
        // The `ScrollViewReader` is for the panel's sake: it can select a row a long
        // way down the list, and a selection nobody can see is no better than none.
        ScrollViewReader { proxy in
          // A builder `List` rather than `List(_:selection:)`, because a grouped list
          // is `Section`s and the data-driven initializer takes one flat collection.
          // The selection binding, its type, and therefore the context menu below are
          // all unchanged by that swap.
          List(selection: $selection) {
            if grouping == .none {
              ForEach(SessionOrder.sorted(account.sessions.sessions, by: sort), content: row)
            } else {
              ForEach(
                SessionOrder.arrange(account.sessions.sessions, sort: sort, grouping: grouping)
              ) { group in
                Section {
                  ForEach(group.items, content: row)
                } header: {
                  SessionGroupHeader(group: group)
                }
              }
            }
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
            if let session = session(for: ids) {
              if let host = SessionHostLookup.host(for: session.registry) {
                Button("Focus in \(host.name)") {
                  FocusSession.focus(host, cwd: session.registry.cwd, session: session)
                }
              }
              if let transcript = session.transcript {
                Button("Read Transcript") {
                  TranscriptWindow.shared.show(
                    url: transcript, name: session.displayName)
                }
              }
              // The fastest route to the thing people actually want a second window
              // for: another session on the same account, in the same project. No
              // folder to pick, because the row already names it.
              Button("New Session in \(session.registry.projectName)") {
                NewSessionLauncher.shared.start(
                  .claude(account.folder),
                  in: URL(filePath: session.registry.cwd, directoryHint: .isDirectory))
              }
              // Below "New Session" because it is the rarer of the two and the one
              // that needs the row: a fresh session only wants the folder, while this
              // wants this session in particular.
              if let target = ForkAvailability.claude(session, in: account).target {
                Button("Fork Session") {
                  NewSessionLauncher.shared.start(
                    target.agent, in: target.project, start: target.start)
                }
              }
              Divider()
              ProjectContextButton(
                path: session.registry.cwd, agent: .claude(accountID: account.id))
            }
          }
          .onChange(of: scrollTarget) { _, target in
            guard let target else { return }
            scrollTarget = nil
            // `.center`, not the default. With grouping on, the target can land under
            // a section header, and a row the panel selected but nobody can see is no
            // better than one it never scrolled to.
            proxy.scrollTo(target, anchor: .center)
          }
        }
      }
    }
  }

  /// One row, built the same way in both branches above so the two cannot drift.
  ///
  /// **`.tag` and `.id` are not the same thing and both are needed.** `.tag` is what
  /// the `List`'s selection and `.contextMenu(forSelectionType: String.self)` read,
  /// and its type has to match that `String` exactly. `.id` is what
  /// `ScrollViewReader.scrollTo` matches — the `List(_:selection:)` this replaced
  /// supplied it out of `Identifiable` for free. An explicit `ForEach` does too, but
  /// stating it means the panel's scroll cannot be broken later by someone giving the
  /// `ForEach` an `id:` of its own or wrapping the row in something.
  private func row(_ session: Session) -> some View {
    SessionRow(session: session, now: now, focus: focusMarkers[session.id])
      .tag(session.id)
      .id(session.id)
  }

  /// **No fallback to the first row.** The pane used to open on whichever session
  /// happened to sort first, which is a choice nobody made and left the account itself
  /// with nowhere to be described. Nil is now a state with a view of its own — see
  /// `AccountOverview` — reached at launch, by clicking empty space in the list, and by
  /// ⌘-clicking the selected row.
  private var selected: Session? {
    account.sessions.sessions.first { $0.id == selection }
  }

  /// The right half: one session, or the account it belongs to.
  @ViewBuilder private var detail: some View {
    if let selected {
      SessionDetail(session: selected, account: account, now: now)
    } else {
      AccountOverview(account: account)
    }
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
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored

  var body: some View {
    UsageStrip {
      if let usage = account.usage, !usage.isEmpty {
        // See `UsageSnapshot.window(_:correctedBy:now:)`: a refusal newer than the
        // cache overrules it, and nothing else does.
        let five = usage.window(.fiveHour, correctedBy: account.quotaHit, now: now)
        let seven = usage.window(.sevenDay, correctedBy: account.quotaHit, now: now)
        CompactMeter(
          title: "Session", subtitle: "5 hours", window: five,
          forecast: forecast(five, .fiveHour, usage.fetchedAt), now: now,
          menuBarLimit: MenuBarLimit(accountID: account.id, length: .fiveHour))
        CompactMeter(
          title: "Weekly", subtitle: "7 days", window: seven,
          forecast: forecast(seven, .sevenDay, usage.fetchedAt), now: now,
          menuBarLimit: MenuBarLimit(accountID: account.id, length: .sevenDay))
      } else {
        Label(
          account.didReadUsage ? "No usage data yet" : "Reading usage…",
          systemImage: "gauge.with.dots.needle.bottom.50percent"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    } status: {
      if let usage = account.usage, !usage.isEmpty {
        StalenessBadge(
          fetchedAt: usage.fetchedAt, now: now, source: usage.source, style: .inline)
      }
    }
  }

  private func forecast(
    _ window: UsageWindow?, _ length: UsageWindowLength, _ fetchedAt: Date?
  ) -> UsageForecast? {
    // Nothing to project from a window a refusal has already closed.
    guard let window, window.rejectedAt == nil else { return nil }
    return UsageForecast(
      window: window, length: length,
      profile: PaceProfile(storedDays: storedWeights, storedHours: storedHours),
      asOf: fetchedAt, now: now)
  }
}

/// The layout both panes' usage headers share: the meters on the left, and two
/// things pinned to the strip's trailing corners — how old the figures are at the
/// top, the list's sort menu at the bottom.
///
/// **The corners hold wherever the meters go.** The column on the right stretches to
/// the height of the row, so when a narrow pane stacks the meters and the strip grows
/// taller, the sort menu moves down with it and stays directly above the list it
/// sorts. The stretch is `.frame(maxHeight: .infinity)` on that column, and it only
/// works together with `.fixedSize(vertical:)` on the stack: a stack places its
/// children at its own final height, which is what hands the column the meters'
/// height, but a stretchy child alone would make the whole strip stretchy and set it
/// competing with the `List` below for the pane's height.
///
/// **Only the meters change shape.** Everything on one row spilled out of both sides
/// of a list dragged down to its 320pt floor, and its texts with no line limit wrapped
/// a character per line. So `ViewThatFits` keeps the meters side by side while they
/// fit beside the corner column, and stacks them when they do not. At the floor with
/// a long age, the age line truncates rather than wrapping.
///
/// Not a toolbar — both windows are hosted `NSWindow`s with no `NSToolbar`, see
/// `HostedWindow` — and no row of its own, because a new row adds height to a pane
/// whose fitting size `OpeningResizeGuard` exists to defend. The sort menu sits
/// outside `meters`, so a pane still reading its usage figures has it too.
struct UsageStrip<Meters: View, Status: View>: View {
  private let meters: Meters
  private let status: Status

  init(@ViewBuilder meters: () -> Meters, @ViewBuilder status: () -> Status) {
    self.meters = meters()
    self.status = status()
  }

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        row { HStack(alignment: .top, spacing: 24) { meters } }
        row { VStack(alignment: .leading, spacing: 10) { meters } }
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
    }
    .background(.bar)
  }

  /// The meters in whichever shape, beside the corner column.
  private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(alignment: .top, spacing: 0) {
      content()
      Spacer(minLength: 16)
      VStack(alignment: .trailing, spacing: 6) {
        status
        Spacer(minLength: 0)
        SessionSortMenu()
      }
      .frame(maxHeight: .infinity)
    }
  }
}

/// A meter sized for the header strip.
struct CompactMeter: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let window: UsageWindow?
  var forecast: UsageForecast?
  let now: Date
  /// Nil for a window with no length to name it by — see `CodexWindow.length`.
  var menuBarLimit: MenuBarLimit?

  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      // Held to one line, both of these. Squeezed, a `Text` with no limit wraps a
      // character per line, and that is what once made the header strip hundreds of
      // points tall in a narrow pane.
      HStack(spacing: 6) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
        if let menuBarLimit {
          MenuBarStar(limit: menuBarLimit, rowHovered: hovering)
        }
      }
      .lineLimit(1)
      if let window {
        HStack(spacing: 8) {
          UsageFigure(window: window, now: now, font: .title3)
            .fixedSize()
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
    .contentShape(.rect)
    .onHover { hovering = $0 }
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

  /// `.compact` is the popover's. The two-line stack below is sized for the end of a
  /// row with a `Spacer` in front of it and does not belong in a 320pt panel, but
  /// the panel is exactly where the age was missing — it was the one surface showing
  /// a percentage with nothing to say how old it was. One tertiary line, and the
  /// same thresholds, so the two surfaces cannot disagree about what "stale" means.
  ///
  /// `.inline` is the session list's header: the words of `.full` on one line, so it
  /// fits `UsageStrip`'s top corner above the sort menu without taking a second
  /// line's height out of the column beside the meters.
  enum Style { case full, inline, compact }

  private static let fresh: TimeInterval = 5 * 60
  private static let stale: TimeInterval = 60 * 60

  /// A live reading only goes doubtful once the probe has been failing long enough
  /// that something is wrong — `claude` moved, or every attempt has timed out.
  /// Comfortably past `Accounts.probeInterval`, so an ordinary gap never trips it.
  private static let liveStale: TimeInterval = 15 * 60

  private var staleAfter: TimeInterval {
    switch source {
    case .live: Self.liveStale
    case .cache: Self.stale
    // Never. A Codex figure does not decay — it was true when its turn wrote it, and
    // the only thing that can invalidate it is its window rolling over, which the
    // figure itself already renders as "—". A warning triangle here would be
    // pointing at a number that is still right.
    case .sessionLog: .infinity
    }
  }

  var body: some View {
    if let fetchedAt {
      let age = now.timeIntervalSince(fetchedAt)
      HStack(spacing: 5) {
        if age > staleAfter {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(triangleFont)
        }
        switch style {
        case .full:
          VStack(alignment: .trailing, spacing: 2) {
            Text("as of").font(.caption2).foregroundStyle(.tertiary)
            relative(fetchedAt, age: age)
          }
        case .inline:
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("as of").font(.caption2).foregroundStyle(.tertiary)
            relative(fetchedAt, age: age)
          }
          .lineLimit(1)
        case .compact:
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

  /// Sized to the line it sits on: the two-line stack can take a full-size glyph, the
  /// single lines cannot.
  private var triangleFont: Font? {
    switch style {
    case .full: nil
    case .inline: .caption
    case .compact: .caption2
    }
  }

  /// The age itself, as `.full` and `.inline` both write it.
  private func relative(_ fetchedAt: Date, age: TimeInterval) -> some View {
    Text(fetchedAt, format: .relative(presentation: .named))
      .font(.caption)
      .foregroundStyle(age > Self.fresh ? .secondary : .primary)
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
    case (.sessionLog, _):
      "Codex reports its limits only inside a session log, so these are the figures from its last turn."
    }
  }
}
