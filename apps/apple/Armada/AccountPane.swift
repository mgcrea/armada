import Combine
import SwiftUI

/// One account: what its plan limits look like, and what its sessions are doing.
///
/// Usage used to sit in a strip above the list, as the context you want *while* reading
/// it. With a session selected that strip was the only place the figures showed, and it
/// only ever showed this account's. The glance is the sidebar row's now, beside every
/// other account's (`SidebarUsage`), and the windows in full are the overview's
/// (`OverviewUsageSection`). Above the list is what the list is doing, counted, with its sort
/// menu (`SessionListBar`).
struct AccountPaneView: View {
  let account: Account

  /// Every selected row. One is a session's detail and none the account's overview; several
  /// are `SessionSelectionDetail`, which acts on all of them at once.
  @State private var selection: Set<String> = []
  @State private var now = AppClock.now
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
    .toolbar {
      SessionToolbarItems(session: selected, account: account)
      NewSessionToolbarItem(
        agent: .claude(account.folder), suggestion: account.recentProjects.first?.url)
    }
    .newSessionFailureAlert()
    .sessionClosingAlerts()
    .sessionBatchAlerts()
    .onReceive(clock) { _ in now = AppClock.now }
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
    // A session ending should not leave the detail on a row that is gone. A batch that moved
    // or closed several leaves whatever is still here selected.
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      let kept = selection.intersection(ids)
      if kept != selection { selection = kept }
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
    selection = [id]
    scrollTarget = id
  }

  /// The left half: the list's tally and sort menu, and the session list.
  private var sessions: some View {
    // The header is a sibling above the list, not a `safeAreaInset` on it. As an
    // inset it floats and the list scrolls under — which looks right at rest and
    // clips the first row on arrival, because the list starts at the container's
    // top rather than below the strip.
    VStack(spacing: 0) {
      SessionListBar(sessions: account.sessions.sessions, tiles: SessionState.barTiles) { key in
        StateDot(state: SessionState(rawValue: key) ?? .idle)
      }
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
                  // Clicking a header selects its sessions, and ⌘-clicking adds them: with
                  // grouping by project, that is every session in one checkout, ready to move.
                  SessionGroupHeader(group: group)
                    .contentShape(Rectangle())
                    .onTapGesture { selectGroup(group.items.map(\.id)) }
                    .help("Click to select these sessions, ⌘-click to add them")
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
          //
          // Several ids are a right-click inside a selection of several rows, and get the
          // batch's items instead: see `SessionBatchContextItems`.
          .contextMenu(forSelectionType: String.self) { ids in
            // Built on demand, so this is one cached lookup per right-click.
            if ids.count > 1 {
              SessionBatchContextItems(sessions: sessions(for: ids), account: account)
            } else if let session = session(for: ids) {
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
              CopyTranscriptButton(url: session.transcript)
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
              HandoverContextItems(
                targets: HandoverAvailability.claude(session, in: account).targets)
              Divider()
              CopySessionIDButton(id: session.id)
              ProjectContextButton(
                path: session.registry.cwd, agent: .claude(accountID: account.id))
              // Last and fenced off, as the one item here that ends something.
              Divider()
              Button("Close Session") {
                SessionClosing.shared.close(session, in: account)
              }
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
    guard selection.count == 1, let id = selection.first else { return nil }
    return account.sessions.sessions.first { $0.id == id }
  }

  /// The right half: several sessions, one, or the account they belong to.
  @ViewBuilder private var detail: some View {
    let several = sessions(for: selection)
    if several.count > 1 {
      SessionSelectionDetail(sessions: several, account: account)
    } else if let selected {
      SessionDetail(session: selected, account: account, now: now)
    } else {
      AccountOverview(account: account, now: now)
    }
  }

  /// The one session a context menu is about, or nil for a set of any other size: empty is a
  /// click on empty space, and several is `SessionBatchContextItems`'s.
  private func session(for ids: Set<String>) -> Session? {
    guard let id = ids.first, ids.count == 1 else { return nil }
    return account.sessions.sessions.first { $0.id == id }
  }

  /// The sessions behind `ids`, in the order the list shows them, so a batch's detail and
  /// its report read top to bottom as the rows do.
  private func sessions(for ids: Set<String>) -> [Session] {
    guard !ids.isEmpty else { return [] }
    let shown =
      grouping == .none
      ? SessionOrder.sorted(account.sessions.sessions, by: sort)
      : SessionOrder.arrange(account.sessions.sessions, sort: sort, grouping: grouping)
        .flatMap(\.items)
    return shown.filter { ids.contains($0.id) }
  }

  /// A header's click: its sessions become the selection, or join it with ⌘ held.
  private func selectGroup(_ ids: [String]) {
    if NSEvent.modifierFlags.contains(.command) {
      selection.formUnion(ids)
    } else {
      selection = Set(ids)
    }
  }

  private var subtitle: String {
    let count = account.sessions.sessions.count
    let sessions = count == 1 ? "1 session" : "\(count) sessions"
    guard let plan = account.planLabel else { return sessions }
    return "\(plan) · \(sessions)"
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
  /// `.inline` is the account overview's Usage header: the words of `.full` on one line,
  /// so it fits beside a section title without doubling the header's height.
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

  /// Whether figures this old, from this source, are in doubt, by the badge's own
  /// thresholds. For a surface with no room to draw the badge, so that it fades the figures
  /// at the moment the badge would warn rather than at a guess of its own. See `SidebarUsage`.
  static func isStale(fetchedAt: Date?, source: UsageSnapshot.Source, now: Date) -> Bool {
    guard let fetchedAt else { return false }
    let badge = StalenessBadge(fetchedAt: fetchedAt, now: now, source: source)
    return now.timeIntervalSince(fetchedAt) > badge.staleAfter
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
            "\(source == .live ? "checked" : "figures from") \(fetchedAt, format: .clockRelative(presentation: .named))"
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
    Text(fetchedAt, format: .clockRelative(presentation: .named))
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
