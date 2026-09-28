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
      SessionRowFigures(session: session, now: now)
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

/// A row's trailing column: its age, and the context in use with where its prompt
/// cache stands.
///
/// **Its own view so it reads the row's selection itself.** Read from `SessionRow`, the
/// selected highlight never reached the colours: only the badge, which read it for
/// itself, turned white.
///
/// **Everything in it turns white on a selected row, muted figures included.** Orange,
/// blue and red all but vanish on the accent-coloured highlight, and the muted styles
/// are too faint there to read at a glance.
private struct SessionRowFigures: View {
  let session: Session
  let now: Date
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    let selected = prominence == .increased
    // Stacked rather than set side by side: two monospaced numbers on one line read
    // as one number in two parts. This also costs the row no height — the trailing
    // column is now as tall as the title and subtitle beside it.
    VStack(alignment: .trailing, spacing: 2) {
      if let started = session.registry.startedAtDate {
        Text(SessionRow.elapsed(from: started, to: now))
          .font(.caption.monospacedDigit())
          .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
          .help("Started this long ago")
      }
      if let tokens = session.context?.total {
        tokenLine(tokens, selected: selected)
      }
    }
  }

  private func tokenLine(_ tokens: Int, selected: Bool) -> some View {
    let badge = PromptCacheBadge(session: session, now: now, selected: selected)
    // Tinted with the badge: the count is what the next turn reads, or re-writes.
    let tint = badge.style
    return HStack(spacing: 3) {
      if let expiresAt = badge.expiresAt {
        HStack(spacing: 2) {
          Image(systemName: "clock")
            .imageScale(.small)
            .accessibilityHidden(true)
          Text(SessionRow.elapsed(from: now, to: expiresAt))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(tint)
        .padding(.trailing, 4)
        .help("Prompt cache stays warm this much longer")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "Prompt cache warm for \(SessionRow.elapsed(from: now, to: expiresAt))")
      }
      Text(TokenCount.short(tokens))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(tint)
        .help(
          "\(TokenCount.short(tokens)) tokens of context in use. Not what this session has cost — the figure falls when it compacts."
        )
      badge
    }
  }
}

/// A mark after the token count saying where the prompt cache stands.
///
/// **Always the same width, drawn or not**, so the counts line up down the list. A
/// session whose cache lifetime is unknown (Codex, Grok Build, a Claude session before
/// its first cache write) leaves the slot empty rather than guessing.
///
/// The count and countdown beside it take its colour. A warm cache is drawn like the
/// session's age above it, unless the prompt is heavy enough that losing it would hurt.
/// The exact times are in the context panel.
struct PromptCacheBadge: View {
  enum Mark {
    /// Mid-turn: every request resets the clock.
    case active
    /// Idle, with more than a quarter of its lifetime to go.
    case warm(PromptCache)
    case expiring(PromptCache)
    case expired(PromptCache)

    /// An idle session's cache, as of `now`.
    init(cache: PromptCache, now: Date) {
      self =
        cache.isExpiringSoon(at: now)
        ? .expiring(cache) : cache.isWarm(at: now) ? .warm(cache) : .expired(cache)
    }

    var systemImage: String {
      switch self {
      case .active, .warm: "flame"
      case .expiring: "timer"
      case .expired: "snowflake"
      }
    }

    /// The mark's colour, or nil for the secondary style. Shared with the context panel,
    /// so a session reads the same in the list and in its details.
    func color(heavy: Bool) -> Color? {
      switch self {
      case .active, .warm: heavy ? .red : nil
      case .expiring: .orange
      case .expired: .blue
      }
    }
  }

  /// A prompt this large costs enough to re-write that a warm cache is worth flagging.
  static let heavyTokens = 500_000

  let mark: Mark?
  /// At or past `heavyTokens`.
  let heavy: Bool
  /// On the accent-coloured highlight of a selected row, where it draws in white.
  let selected: Bool

  init(session: Session, now: Date, selected: Bool) {
    self.selected = selected
    heavy = (session.context?.total ?? 0) >= Self.heavyTokens
    if session.cacheTTL == nil {
      mark = nil
    } else if session.state.isBusy {
      mark = .active
    } else if let cache = session.promptCache {
      mark = Mark(cache: cache, now: now)
    } else {
      mark = nil
    }
  }

  /// When an idle, still-warm cache lapses. Nil mid-turn, where the clock keeps
  /// resetting, and once it has lapsed, where the snowflake already says so.
  var expiresAt: Date? {
    switch mark {
    case .warm(let cache), .expiring(let cache): cache.expiresAt
    case .active, .expired, nil: nil
    }
  }

  /// The badge's colour, and the count's beside it. Nil for the secondary style.
  var color: Color? { mark?.color(heavy: heavy) }

  /// What the badge, and the figures beside it, are drawn in. White on a selected row;
  /// muted where there is no cache state to tell.
  var style: AnyShapeStyle {
    if selected { return AnyShapeStyle(.white) }
    if mark == nil { return AnyShapeStyle(.tertiary) }
    return color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary)
  }

  var body: some View {
    Group {
      if let mark {
        Image(systemName: mark.systemImage)
          .help(Self.help(mark))
          .accessibilityLabel(Self.accessibilityLabel(mark))
      } else {
        Color.clear
      }
    }
    .foregroundStyle(style)
    .imageScale(.small)
    .frame(width: 12)
  }

  private static func help(_ mark: Mark) -> String {
    switch mark {
    case .active:
      "Prompt cache in use. Each request this turn makes keeps it warm."
    case .warm(let cache):
      "Prompt cache warm until ~\(cache.expiresAt.formatted(.clockRelative(presentation: .named))). "
        + "The next turn reads the \(TokenCount.short(cache.tokens)) prompt from the cache."
    case .expiring(let cache):
      "Prompt cache expires ~\(cache.expiresAt.formatted(.clockRelative(presentation: .named))). "
        + "Reply before then and the next turn reads the \(TokenCount.short(cache.tokens)) "
        + "prompt from the cache, instead of writing it back at full cost."
    case .expired(let cache):
      "Prompt cache expired ~\(cache.expiresAt.formatted(.clockRelative(presentation: .named))). "
        + "The next turn writes the \(TokenCount.short(cache.tokens)) prompt back into the "
        + "cache, which costs more than reading it and counts against your limits."
    }
  }

  private static func accessibilityLabel(_ mark: Mark) -> String {
    switch mark {
    case .active: "Prompt cache in use"
    case .warm: "Prompt cache warm"
    case .expiring: "Prompt cache expiring soon"
    case .expired: "Prompt cache expired"
    }
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
        // Focus and Read Transcript are in the window's toolbar (`SessionToolbarItems`);
        // what stays here is why Focus cannot reach the window, where there is room to say it.
        FocusNote(host: host, didLookUp: didLookUpHost)
        ForkButton(availability: .claude(session, in: account))
        HandoverButton(availability: .claude(session, in: account))
        CloseSessionButton(session: session, account: account)
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

/// Why Focus in the toolbar cannot reach this session's window, or what would let it.
///
/// Only here, in the session's details: this is where someone looks when the button
/// disappoints them, so it is the one place worth spending three lines on what would fix
/// it. The toolbar's tooltip points here, and the popover's right-click says nothing.
struct FocusNote: View {
  let host: SessionHost?
  let didLookUp: Bool

  @State private var trust = AccessibilityTrust.shared

  var body: some View {
    if let host {
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
