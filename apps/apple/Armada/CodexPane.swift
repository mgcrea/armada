import Combine
import SwiftUI

/// One Codex home: its plan limits, and what its sessions have been doing.
///
/// Laid out like `AccountPaneView` on purpose — a strip of meters above a session
/// list, with an inspector — because the two panes answer the same question about
/// different vendors and a person should not have to relearn the window.
struct CodexPaneView: View {
  let account: CodexAccount

  @State private var selection: String?
  @State private var now = Date()
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  @State private var route = MainWindowRoute.shared
  @State private var scrollTarget: String?

  // The same two keys `AccountPaneView` reads, not a Codex-flavoured pair. The panes
  // are twinned on purpose, and "how I like my sessions listed" is one preference.
  @AppStorage(SessionSort.defaultsKey) private var storedSort = SessionSort.fallback.stored
  @AppStorage(SessionGrouping.defaultsKey)
  private var storedGrouping = SessionGrouping.fallback.stored

  private var sort: SessionSort { SessionSort(stored: storedSort) }
  private var grouping: SessionGrouping { SessionGrouping(stored: storedGrouping) }

  var body: some View {
    // `HSplitView`, matching `AccountPaneView`, and for the reason written up there:
    // the context panel is a bar, a headline, two captions and a table, which wrapped
    // into an unreadable stack inside a 280pt system inspector. This pane kept the
    // inspector until it gained the same panel, at which point it inherited the same
    // problem — the two panes are twinned, so the fix is too.
    HSplitView {
      sessions
        .frame(minWidth: 320, idealWidth: 420)
      CodexSessionDetail(session: selected, account: account, now: now)
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
    guard let id = route.takeSession(in: .codex(account.id)) else { return }
    selection = id
    scrollTarget = id
  }

  /// The left half: the usage strip and the session list.
  ///
  /// Extracted for the same reason `AccountPaneView` extracts its own — one `body`
  /// holding the strip, a branch, a `ScrollViewReader`, a grouped `List` and the
  /// detail exceeded the type checker's budget outright once the context panel was
  /// added ("unable to type-check this expression in reasonable time").
  private var sessions: some View {
    VStack(spacing: 0) {
      CodexUsageHeader(account: account, now: now)
      if account.sessions.sessions.isEmpty {
        ContentUnavailableView {
          Label(
            account.sessions.didScan ? "No recent sessions" : "Reading sessions…",
            systemImage: "sailboat")
        } description: {
          Text(
            "Nothing has run in \(account.displayName) in the last 12 hours. Start a Codex session and it appears here within a moment."
          )
        }
      } else {
        // As in `AccountPaneView`: the panel lists live sessions only, so the row it
        // sends here can be anywhere in a list that also holds the day's finished
        // ones, and it has to be scrolled to rather than merely selected.
        ScrollViewReader { proxy in
          // A builder `List` rather than `List(_:selection:)`: a grouped list is
          // `Section`s, and the data-driven initializer takes one flat collection.
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
          // As in `AccountPaneView`, on the `List` rather than the row, so that
          // right-clicking an unselected row acts on that row. There is no "Focus in"
          // twin here: a Codex rollout records no pid, so there is no process to walk
          // up to an application — see `docs/codex-sessions.md`.
          .contextMenu(forSelectionType: String.self) { ids in
            if let session = session(for: ids), !session.meta.cwd.isEmpty {
              Button("New Session in \(session.meta.projectName)") {
                NewSessionLauncher.shared.start(
                  .codex(account.home),
                  in: URL(filePath: session.meta.cwd, directoryHint: .isDirectory))
              }
            }
          }
          .onChange(of: scrollTarget) { _, target in
            guard let target else { return }
            scrollTarget = nil
            // `.center`, as in `AccountPaneView`: with grouping on, the routed row can
            // land under a section header.
            proxy.scrollTo(target, anchor: .center)
          }
        }
      }
    }
  }

  /// One row, built the same way in both branches above. `.tag` is the `List`'s
  /// selection; `.id` is what `ScrollViewReader.scrollTo` matches. See
  /// `AccountPaneView.row(_:)` for why both are written out.
  private func row(_ session: CodexSession) -> some View {
    CodexSessionRow(session: session, now: now)
      .tag(session.id)
      .id(session.id)
  }

  /// The one session a context menu is about. Single selection, so anything but one
  /// row is a click on empty space. Same rule as `AccountPaneView.session(for:)`.
  private func session(for ids: Set<String>) -> CodexSession? {
    guard let id = ids.first, ids.count == 1 else { return nil }
    return account.sessions.sessions.first { $0.id == id }
  }

  private var selected: CodexSession? {
    account.sessions.sessions.first { $0.id == selection } ?? account.sessions.sessions.first
  }

  /// Counts live and recent separately. "14 sessions" would be a lie of the kind
  /// this pane exists to avoid: thirteen of them finished hours ago.
  private var subtitle: String {
    let live = account.sessions.liveSessions.count
    let total = account.sessions.sessions.count
    let recent = total == 1 ? "1 recent session" : "\(total) recent sessions"
    let head = account.planLabel.map { "\($0) · " } ?? ""
    return live == 0 ? "\(head)\(recent)" : "\(head)\(live) live · \(recent)"
  }
}

/// Codex's two plan windows, and how much to trust them.
///
/// The age of the figures is given more room than in the Claude header, and it has
/// to be. Claude Code maintains `cachedUsageUtilization` as a document Armada can
/// read whenever it likes; Codex states its limits only inside a `token_count`
/// event, so the newest figures are exactly as old as the last turn anyone ran. On
/// a Mac where Codex ran at 07:00 and it is now lunchtime, the 5-hour window those
/// figures describe has already rolled over. Hence "last turn 2 hours ago" in the
/// corner, and the shared meter's own "window has since reset" underneath.
struct CodexUsageHeader: View {
  let account: CodexAccount

  let now: Date

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 24) {
        if let usage = account.usage, !usage.isEmpty {
          meter(usage.primary)
          meter(usage.secondary)
          Spacer(minLength: 0)
          VStack(alignment: .trailing, spacing: 2) {
            Text("last turn").font(.caption2).foregroundStyle(.tertiary)
            Text(usage.observedAt, format: .relative(presentation: .named))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .help(
            "Codex only reports its limits inside a session log, so these figures are as old as the last turn it ran."
          )
        } else {
          Label(
            account.sessions.didScan ? "No usage reported yet" : "Reading usage…",
            systemImage: "gauge.with.dots.needle.bottom.50percent"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        // Twinned with `UsageHeader`, including the order: what starts something,
        // then what reorders the list.
        NewSessionMenu(agent: .codex(account.home), projects: account.recentProjects)
        // Where `UsageHeader` puts it, for the reasons given there.
        SessionSortMenu()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
    }
    .background(.bar)
  }

  /// The same `CompactMeter` the Claude pane uses, including its footnote — which
  /// already says "window has since reset" for a `resets_at` in the past, so the
  /// case this header cares most about is handled by the shared component rather
  /// than by a second treatment invented here.
  ///
  /// The forecast is offered and `UsageForecast` decides, which is not what this
  /// did at first.
  ///
  /// It passed `nil` outright, reasoning that Codex figures are too intermittent to
  /// project from. That was the right worry and the wrong place to act on it:
  /// `UsageForecast` already refuses a reading older than 10% of its window —
  /// 30 minutes for the session window, 16.8 hours for the weekly one — and it
  /// measures the rate to `asOf` rather than to `now`, so a reading that passes the
  /// guard gives sound arithmetic however it was obtained. Refusing here as well
  /// meant the same Codex numbers showed a pace tick in the Usage pane and none in
  /// this header, which is a disagreement between two views of one fact.
  @ViewBuilder
  private func meter(_ window: CodexWindow?) -> some View {
    if let window {
      CompactMeter(
        title: LocalizedStringKey(window.title),
        subtitle: LocalizedStringKey(window.subtitle),
        window: window.usage,
        forecast: forecast(window),
        now: now)
    }
  }

  private func forecast(_ window: CodexWindow) -> UsageForecast? {
    guard let length = window.length else { return nil }
    return UsageForecast(
      window: window.usage, length: length, weights: DayWeights(stored: storedWeights),
      asOf: account.usage?.observedAt, now: now)
  }
}

/// One Codex home's block in the menu bar popover.
///
/// Lives here rather than beside `AccountSummary` in `ArmadaApp.swift` so that the
/// whole Codex spike is two files of UI and can be lifted out in one piece.
///
/// It shows **live** sessions only. The window's pane lists recent ones too,
/// because that is where you go to look at what happened; a menu is for what is
/// happening, and a popover listing this morning's finished automation runs would
/// crowd out the one session that is actually moving.
struct CodexSummary: View {
  let account: CodexAccount
  let showsName: Bool
  let now: Date

  private static let visibleSessions = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if showsName {
        PanelRow(help: "Show \(account.displayName) in Armada") {
          MenuBarPanel.dismiss()
          MainWindowRoute.shared.open(.codex(account.id))
        } label: {
          HStack(spacing: 6) {
            CodexIconView(size: 14)
            Text(account.displayName)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            // On the name's line for the reason `AccountSummary` gives, and it has to
            // stay in step with it: the two blocks sit in one panel, and a Codex header
            // shaped differently from a Claude one reads as a different kind of thing.
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
        }
      } else {
        PanelRow(help: "Show \(account.displayName) in Armada") {
          MenuBarPanel.dismiss()
          MainWindowRoute.shared.open(.codex(account.id))
        } label: {
          Text(summary)
            .font(.callout)
            .foregroundStyle(live.isEmpty ? .secondary : .primary)
        }
      }

      // Clickable here, where the Claude rows have always been, even though Codex
      // has no host to focus and never did — the destination is Armada's own pane,
      // which is exactly why these rows can do something now. See `SummaryRow`.
      ForEach(live.prefix(Self.visibleSessions)) { session in
        PanelRow(help: "Show \(session.displayName) in Armada") {
          MenuBarPanel.dismiss()
          MainWindowRoute.shared.open(.codex(account.id), session: session.id)
        } label: {
          HStack(spacing: 6) {
            CodexStateDot(state: session.state)
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

      // Laid out exactly like `AccountSummary`'s:
      // the two blocks sit in one 320pt panel, and a Codex row that spaced or
      // annotated its meters differently would read as a different kind of thing
      // rather than as the same thing for another vendor.
      if let usage = account.usage, !usage.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          CompactUsage(label: "5h", window: usage.primary?.usage, forecast: nil, now: now)
          CompactUsage(label: "7d", window: usage.secondary?.usage, forecast: nil, now: now)
        }
        .padding(.top, 2)
      }
    }
  }

  private var live: [CodexSession] { account.sessions.liveSessions }

  private var summary: String {
    let recent = account.sessions.sessions.count
    if live.isEmpty {
      return recent == 0 ? "No recent sessions" : "Nothing running, \(recent) today"
    }
    return live.count == 1 ? "1 session running" : "\(live.count) sessions running"
  }
}

/// One Codex session in a list.
struct CodexSessionRow: View {
  let session: CodexSession
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      CodexStateDot(state: session.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(session.meta.projectName)
          if let kind = session.kindLabel {
            Text("·")
            Text(kind)
          }
          if let reason = session.untitledReason {
            Text("·")
            Text(reason)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      // Laid out as `SessionRow`'s, and showing the same quantity — context in use,
      // never `session.totalTokens`. Codex is the only one of the two vendors that
      // reports lifetime spend, and a column that meant one thing here and another in
      // the Claude pane would be worse than a column that is missing from one of them.
      VStack(alignment: .trailing, spacing: 2) {
        if let last = session.lastEventAt ?? session.meta.startedAt {
          Text(SessionRow.elapsed(from: last, to: now))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help(session.state.isLive ? "Age of the last event" : "Ended this long ago")
        }
        if let tokens = session.context?.total {
          Text(TokenCount.short(tokens))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help(
              "\(TokenCount.short(tokens)) tokens of context in use. See the inspector for what this session has cost in total."
            )
        }
      }
    }
    .padding(.vertical, 2)
    // A subagent is indented rather than hidden: it is real work against the same
    // plan limits, and hiding it would make the token totals look wrong.
    .padding(.leading, session.isSubagent ? 14 : 0)
  }
}

struct CodexStateDot: View {
  let state: CodexSessionState

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: 8, height: 8)
      .overlay {
        if state.isBestEffort {
          Circle().stroke(state.tint, lineWidth: 1).frame(width: 13, height: 13)
        }
      }
      .frame(width: 14, height: 14)
      .help(state.isBestEffort ? "\(state.label) (inferred)" : state.label)
      .accessibilityLabel(state.label)
  }
}

/// What a Codex session is carrying — the Claude pane's context panel, from Codex's
/// own numbers.
///
/// The adapter half of `ContextPanel`; `ContextSection` is the other. Everything
/// visible is shared, so the two panes cannot drift, and what differs is only what the
/// vendors actually record:
///
/// - **The window size is stated, not resolved.** `model_context_window` comes in the
///   same event as the usage, so there is no `ContextWindow` here and no provenance to
///   explain — the tooltip says Codex recorded it and that is the end of it.
/// - **No compaction line.** Nothing in a rollout records one.
/// - The bands are the same two, for the same reason, and split at the same place.
struct CodexContextSection: View {
  let session: CodexSession
  let now: Date

  var body: some View {
    if let context = session.context, let limit = session.contextLimit {
      ContextPanel(
        modelLabel: session.meta.model ?? "Unknown model",
        categories: categories(context: context),
        limit: limit,
        limitHelp: "Codex records the window size in its session log, so this is measured "
          + "rather than inferred from the model.",
        // Only while the session is alive. `projectedFull` extrapolates the measured
        // rate forward from `now`, and this list holds sessions that ended hours ago —
        // one of them was adding 1.3k per request across 13 seconds yesterday, which
        // projects to "~full in 18 minutes" for a session that has no future at all.
        // The Claude pane needs no such guard because its list is live by
        // construction: a row there means a pid the kernel still answers for.
        growth: session.state.isLive ? session.growth : nil,
        now: now)
    }
  }

  /// The same split as `ContextSection.categories`, and the same fallback when the
  /// opening figure has not been read yet — here because the first `token_count` is
  /// hundreds of KB into the file and the scan for it runs in the background.
  private func categories(context: ContextReading) -> [ContextCategory] {
    guard let baseline = session.baseline?.loadedAtStart, baseline <= context.total else {
      return [
        ContextCategory(
          name: "Context used", tokens: context.total,
          color: ContextCategory.conversationColor,
          help: "The whole prompt on the newest request. The opening figure has not been "
            + "read yet, so it is not split here.")
      ]
    }
    return [
      ContextCategory(
        name: "Loaded at start", tokens: baseline, color: ContextCategory.prefixColor,
        help: "This session's first request: the system prompt, its tools and the opening "
          + "message, as one measured figure."),
      ContextCategory(
        name: "Conversation", tokens: context.total - baseline,
        color: ContextCategory.conversationColor,
        help: "Everything in the context beyond that first request — the turns themselves, "
          + "plus anything read in along the way."),
    ]
    .filter { $0.tokens > 0 }
  }
}

struct CodexSessionDetail: View {
  let session: CodexSession?
  let account: CodexAccount
  let now: Date

  var body: some View {
    Form {
      if let session {
        Section {
          LabeledContent("State") {
            HStack(spacing: 6) {
              CodexStateDot(state: session.state)
              Text(session.state.label)
            }
          }
          Text(explanation(session.state))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // Above "Session", matching `SessionDetail`: the context is the live fact
        // worth checking, and the folder and version are reference you read once.
        CodexContextSection(session: session, now: now)
        Section("Session") {
          LabeledContent("Project", value: session.meta.projectName)
          LabeledContent("Folder", value: session.meta.cwd)
            .lineLimit(3)
            .truncationMode(.head)
          if let kind = session.kindLabel {
            LabeledContent("Started by", value: kind)
          }
          if let model = session.meta.model {
            LabeledContent("Model", value: model)
          }
          if let version = session.meta.cliVersion {
            LabeledContent("Codex", value: version)
          }
          if let tokens = session.totalTokens {
            // Named for what it is, now that the Context section above shows
            // occupancy. These two numbers look alike and mean opposite things: this
            // one only ever grows, and on a long session it runs to several times the
            // window.
            LabeledContent("Tokens used", value: tokens.formatted(.number))
              .help("Every request in this session added up, not how full the window is.")
          }
        }
        if let parent = session.meta.parentThreadId {
          Section("Subagent") {
            Text("Spawned by another thread.")
              .foregroundStyle(.secondary)
            LabeledContent("Parent", value: String(parent.prefix(8)))
              .help(parent)
          }
        }
      } else {
        Text("No session selected").foregroundStyle(.secondary)
      }

      Section("Codex") {
        LabeledContent("Home", value: account.displayPath)
          .lineLimit(2)
          .truncationMode(.head)
        if let plan = account.planLabel {
          LabeledContent("Plan", value: plan)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Each state says where it came from, because they came from three different
  /// places and only one of them is a guess.
  private func explanation(_ state: CodexSessionState) -> String {
    switch state {
    case .working:
      "A Codex process holds this session's writer lock and the log's last event is not task_complete."
    case .awaitingInput:
      "A Codex process still holds this session's writer lock and its turn is finished, so the session is open and idle."
    case .ended:
      "No process holds this session's writer lock. Codex writes no session-ended record, so a crashed session that left its lock behind would still look live."
    }
  }
}
