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

  var body: some View {
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
        List(account.sessions.sessions, selection: $selection) { session in
          CodexSessionRow(session: session, now: now)
            .tag(session.id)
        }
      }
    }
    .inspector(isPresented: .constant(true)) {
      CodexSessionDetail(session: selected, account: account)
        .inspectorColumnWidth(min: 240, ideal: 280)
    }
    .navigationTitle(account.displayName)
    .navigationSubtitle(subtitle)
    .onReceive(clock) { now = $0 }
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
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

  /// Not read anywhere below, and not dead. The relative times here — "last turn
  /// 2 hours ago", and the reset lines inside the meters — are rendered against
  /// `Date.now` at draw time, so something has to make the view redraw as the
  /// clock moves. Taking the pane's tick as a property is what does that.
  let now: Date

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
  /// No forecast. `UsageForecast` projects a rate from how far into a window the
  /// figures were taken, which needs a reading that tracks the window; Codex only
  /// produces one when a turn happens to run. Passing it anyway would put a
  /// confident "at this rate" under a number nobody has updated since breakfast.
  @ViewBuilder
  private func meter(_ window: CodexWindow?) -> some View {
    if let window {
      CompactMeter(
        title: LocalizedStringKey(window.title),
        subtitle: LocalizedStringKey(window.subtitle),
        window: window.usage,
        forecast: nil,
        now: now)
    }
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
      } else {
        Text(summary)
          .font(.callout)
          .foregroundStyle(live.isEmpty ? .secondary : .primary)
      }

      ForEach(live.prefix(Self.visibleSessions)) { session in
        HStack(spacing: 6) {
          CodexStateDot(state: session.state)
          Text(session.displayName)
            .font(.caption)
            .lineLimit(1)
          Spacer(minLength: 0)
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
      if let last = session.lastEventAt ?? session.meta.startedAt {
        Text(SessionRow.elapsed(from: last, to: now))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .help(session.state.isLive ? "Age of the last event" : "Ended this long ago")
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

struct CodexSessionDetail: View {
  let session: CodexSession?
  let account: CodexAccount

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
            LabeledContent("Tokens", value: tokens.formatted(.number))
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
