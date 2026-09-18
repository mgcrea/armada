import SwiftUI

/// One session in a list: state, title, project, age.
struct SessionRow: View {
  let session: Session
  let now: Date
  /// How far Focus reaches from this row, drawn beside the project it would land in.
  /// Nil for a session with no host, and until the pane has asked.
  var focus: FocusMarker? = nil

  var body: some View {
    HStack(spacing: 10) {
      StateDot(state: session.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(session.registry.projectName)
          if let focus {
            Image(systemName: focus.reach.systemImage)
              .imageScale(.small)
              .foregroundStyle(focus.reach == .tab ? .secondary : .tertiary)
              .help(focus.reach.help(hostName: focus.hostName))
              .accessibilityLabel(focus.reach.help(hostName: focus.hostName))
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
      // Stacked rather than set side by side: two monospaced numbers on one line read
      // as one number in two parts. This also costs the row no height — the trailing
      // column is now as tall as the title and subtitle beside it.
      VStack(alignment: .trailing, spacing: 2) {
        if let started = session.registry.startedAtDate {
          Text(Self.elapsed(from: started, to: now))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Started this long ago")
        }
        if let tokens = session.context?.total {
          Text(TokenCount.short(tokens))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help(
              "\(TokenCount.short(tokens)) tokens of context in use. Not what this session has cost — the figure falls when it compacts."
            )
        }
      }
    }
    .padding(.vertical, 2)
  }

  /// Wall-clock age of the session, as `2h 14m` / `14m` / `43s`.
  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    let (hours, minutes) = (seconds / 3600, (seconds % 3600) / 60)
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
  }
}

struct StateDot: View {
  let state: SessionState

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: 8, height: 8)
      // A hollow ring for the inferred state, so "running a tool" does not claim
      // the same confidence as a state that came from an actual write.
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

/// One session, in full.
///
/// Takes a session rather than an optional one: "nothing selected" is a different
/// view now (`AccountOverview`), not an empty branch inside this one.
struct SessionDetail: View {
  let session: Session
  let account: Account
  let now: Date

  /// Resolved on a selection change rather than on every redraw — the lookup behind
  /// it reaches LaunchServices. See `SessionHostLookup`.
  @State private var host: SessionHost?
  @State private var didLookUpHost = false

  var body: some View {
    Form {
      Section {
        LabeledContent("State") {
          HStack(spacing: 6) {
            StateDot(state: session.state)
            Text(session.state.label)
          }
        }
        // What it wants, in Claude Code's own words. Shown verbatim and never
        // matched against: `SessionRegistry.waitingFor` is display text built from a
        // per-dialog table, and the set grows with every new kind of prompt.
        if let waitingFor = session.waitingFor {
          LabeledContent("Waiting for", value: waitingFor)
        }
        if session.state.isBestEffort {
          Text(
            "Inferred from an unanswered tool_use in the transcript: Claude Code reports the session as busy but writes nothing while a tool runs, so a running tool and one waiting for your approval look the same here. A session stopped at a prompt usually reports that itself, and shows as \"Waiting for you\"."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        FocusButton(
          host: host, cwd: session.registry.cwd, session: session, didLookUp: didLookUpHost)
        // Below Focus, above Fork: Focus takes you to the live session, this reads it
        // without disturbing it, and Fork is the one that starts something new.
        TranscriptButton(session: session)
        ForkButton(availability: .claude(session, in: account))
      }
      // Above "Session": the context is the live fact worth checking, while the
      // pid and the folder are reference you look up once.
      ContextSection(
        session: session, accountModelID: account.modelID,
        composition: account.compositions.composition(for: session.registry.cwd), now: now)
      Section("Session") {
        LabeledContent("Project", value: session.registry.projectName)
        LabeledContent("Folder", value: session.registry.cwd)
          .lineLimit(3)
          .truncationMode(.head)
        LabeledContent("PID", value: String(session.registry.pid))
        if let version = session.registry.version {
          LabeledContent("Claude Code", value: version)
        }
        if let entrypoint = session.registry.entrypoint {
          LabeledContent("Started from", value: entrypoint)
        }
      }
      if session.title == nil, let reason = session.untitledReason {
        Section("No title") {
          Text(reason).foregroundStyle(.secondary)
          Text(
            session.transcript == nil
              ? "A session that has never been prompted has no transcript, so there is nothing to take a title from."
              : "A resumed session gets a new id and a transcript with no title in it, and no link back to the original."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      // Which folder this row came from. Cheap to show and the thing that makes
      // two accounts legible: the same project can be open in both. Shared with
      // `AccountOverview`, which describes the same account with nothing selected.
      AccountSection(account: account)
    }
    .formStyle(.grouped)
    .task(id: session.id) {
      didLookUpHost = false
      host = nil
      host = SessionHostLookup.host(for: session.registry)
      didLookUpHost = true
      // Only the project being looked at is ever probed. A process per project in the
      // list, on a dashboard built for sixteen sessions, is exactly the cost
      // `ClaudeControl` measured and refused.
      await account.compositions.probe(cwd: session.registry.cwd)
    }
  }
}

/// "Focus in Visual Studio Code", or an explanation of why there is nothing to focus.
///
/// **The label still names the application, even now that this can reach a tab.**
/// "Go to session" would promise the tab every time, and the tab is reached only for a
/// session the VS Code extension owns, in the window whose title names its folder, when
/// that window shows a tab for it or for a session beside it; everything else lands on
/// the window, or on the app. Naming the app is also the more useful label, because it
/// tells you where you are about to be sent.
struct FocusButton: View {
  let host: SessionHost?
  let cwd: String
  let session: Session
  let didLookUp: Bool

  @State private var trust = AccessibilityTrust.shared

  var body: some View {
    if let host {
      Button {
        FocusSession.focus(host, cwd: cwd, session: session)
      } label: {
        Label("Focus in \(host.name)", systemImage: "arrow.up.forward.app")
      }
      // Only while it is missing, and only here. This is the one place someone is
      // looking at the button that disappoints them, so it is the one place worth
      // spending three lines explaining what would fix it; the popover's
      // right-click menu gets no room for a sentence and says nothing.
      if !trust.isTrusted {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            "Armada can only bring \(host.name) itself forward, so the window you were last in wins. Allowing Accessibility lets it raise the window this session's folder is open in."
          )
          Button("Allow in System Settings…") { HostWindow.openAccessibilitySettings() }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } else if didLookUp {
      Text(
        "No window to go back to. Armada follows this session's parent processes up to the app that owns them, and a session started by a daemon, inside tmux, or over ssh has no owning app to find."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
