import SwiftUI

/// What the sidebar can be showing.
///
/// The selection used to be an account id and is now a choice between the overview
/// and one account, which is the whole cost of adding a second sidebar section.
///
/// Round-trips through one defaults string because that is what `@AppStorage`
/// stores. Claude account ids are absolute paths — `Account.id` guarantees it — so
/// they always begin with a slash and can never be mistaken for the overview's
/// token. Codex ids are absolute paths too, which is exactly why they carry a
/// prefix: `~/.claude` and `~/.codex` are different rows and the stored string has
/// to say which.
enum SidebarItem: Hashable {
  case usage
  case account(String)
  case codex(String)
  case grok(String)
  /// Every saved project, in one pane of its own. The project selected in it is that
  /// pane's to keep, as a session is an account pane's.
  case projects
  /// Every scheduled task on this Mac, read-only. Listed while there is a Codex home or the
  /// Claude app has scheduled tasks.
  case schedules
  /// The voice conversation's questions and replies. Listed only while voice is on.
  case voice

  /// Where the window's selection is stored, and the one thing the menu bar panel
  /// has to write to steer the sidebar. The key keeps its original name so an
  /// existing selection survives the upgrade to a stored `SidebarItem`.
  static let defaultsKey = "armada.selectedAccount"

  private static let usageToken = "usage"
  private static let projectsToken = "projects"
  private static let schedulesToken = "schedules"
  private static let voiceToken = "voice"
  private static let codexPrefix = "codex:"
  private static let grokPrefix = "grok:"

  var stored: String {
    switch self {
    case .usage: Self.usageToken
    case .account(let id): id
    case .codex(let id): Self.codexPrefix + id
    case .grok(let id): Self.grokPrefix + id
    case .projects: Self.projectsToken
    case .schedules: Self.schedulesToken
    case .voice: Self.voiceToken
    }
  }

  init?(stored: String) {
    if stored == Self.usageToken {
      self = .usage
    } else if stored == Self.projectsToken {
      self = .projects
    } else if stored == Self.schedulesToken {
      self = .schedules
    } else if stored == Self.voiceToken {
      self = .voice
    } else if stored.hasPrefix(Self.codexPrefix) {
      self = .codex(String(stored.dropFirst(Self.codexPrefix.count)))
    } else if stored.hasPrefix(Self.grokPrefix) {
      self = .grok(String(stored.dropFirst(Self.grokPrefix.count)))
    } else if stored.hasPrefix("/") {
      self = .account(stored)
    } else {
      return nil
    }
  }
}

struct MainWindowView: View {
  @State private var accounts = Accounts.shared
  @State private var codex = CodexAccounts.shared
  @State private var grok = GrokAccounts.shared
  @State private var projects = ProjectStore.shared
  @State private var schedules = SchedulesModel.shared
  @State private var monitor = EntitlementMonitor.shared
  /// The agent an account is being added for, while the sheet is up.
  @State private var addingAccount: NewAccount.Vendor?

  /// What the sidebar had selected last time.
  ///
  /// A path rather than an index, so the window reopens on the same account even
  /// if a folder appeared or went away in between; `selection` below falls back
  /// to the first account when the stored one is gone.
  ///
  /// `MainWindowRoute` writes this same key to steer the sidebar from the menu bar
  /// panel, which is why it is a named constant rather than a literal here.
  @AppStorage(SidebarItem.defaultsKey) private var storedAccount: String = ""
  @AppStorage(VoiceController.enabledKey) private var voiceEnabled = false

  /// Whether the sidebar is showing.
  ///
  /// `@State`, not `@AppStorage`, so a hidden sidebar comes back on the next launch. The
  /// split view writes this binding itself, from inside a layout pass, when the window is
  /// narrowed past what both columns need, and a defaults write there is the abort that
  /// `HostedWindow.show()` writes up. The window is kept when it closes, so the choice
  /// still lasts until Armada quits.
  @State private var columns = NavigationSplitViewVisibility.all

  var body: some View {
    // Asked once, across the top of the window, and gone for good once answered
    // either way. A card rather than a dialog: see `UpdateConsentCard`.
    //
    // A sibling above the split view, not a `safeAreaInset` on it. The split view's
    // columns are AppKit-hosted and do not honour an inset from outside, so as one
    // the card floated over the sidebar and the usage strip instead of pushing them
    // down — the same trap `AccountPaneView` writes up for its header.
    VStack(spacing: 0) {
      UpdateConsentCard()
      splitView
    }
    .sheet(item: $addingAccount) { AddAccountSheet(vendor: $0) }
    // Once per showing, for the sidebar row and its badge; the pane reads again while it is up.
    .task { await schedules.load() }
    .screenshotSubject()
    #if DEBUG
      // Every store a capture draws from is seeded before this window exists, so the
      // body running is the content existing. See `DemoSeed.signalReady(from:)`.
      .task { DemoSeed.signalReady(from: .main) }
    #endif
  }

  private var splitView: some View {
    NavigationSplitView(columnVisibility: $columns) {
      List(selection: selection) {
        Section("Overview") {
          Label("Usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
            .tag(SidebarItem.usage)
          // One row rather than a section listing every project: a project spans the
          // accounts below, so it is not one more of them, and the list with its details
          // beside it needs the pane's width, not the sidebar's.
          //
          // The badge counts saved projects, not live sessions as the account rows' do:
          // live work already shows on each project's own row in the pane.
          Label("Projects", systemImage: "folder")
            .badge(projects.projects.count)
            .tag(SidebarItem.projects)
          if showsSchedules {
            Label("Schedules", systemImage: "calendar.badge.clock")
              .badge(schedules.activeCount)
              .tag(SidebarItem.schedules)
          }
          if voiceEnabled {
            Label("Voice", systemImage: "waveform")
              .tag(SidebarItem.voice)
          }
        }
        Section("Claude Code") {
          ForEach(accounts.all) { account in
            AccountSidebarRow(account: account)
              .tag(SidebarItem.account(account.id))
              .contextMenu { PanelVisibilityToggle(accountID: account.id) }
          }
        }
        // Omitted entirely when there is no Codex home, rather than shown empty:
        // an app that watches agents should not tell someone who does not use
        // Codex that they are missing something.
        if !codex.isEmpty {
          Section("Codex") {
            ForEach(codex.all) { account in
              CodexSidebarRow(account: account)
                .tag(SidebarItem.codex(account.id))
                .contextMenu { PanelVisibilityToggle(accountID: account.id) }
            }
          }
        }
        if !grok.isEmpty {
          Section("Grok Build") {
            ForEach(grok.all) { account in
              GrokSidebarRow(account: account)
                .tag(SidebarItem.grok(account.id))
                .contextMenu { PanelVisibilityToggle(accountID: account.id) }
            }
          }
        }
      }
      // 240 ideal for the usage lines under each account: every column of `CompactUsage` but
      // the bar is fixed, so the sidebar's width past about 150pt of content is the bar's
      // alone, and at 210 it was a 45pt bar. The floor stays where it was.
      .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 280)
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 4) {
          LicenceStatusLine()
          Text("Armada \(AppInfo.shortVersion)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
    } detail: {
      // The gate. Refused, the watchers hold nothing, so every pane below would
      // be the empty state — which says "no agents found", and that is not true.
      if !monitor.current.isEntitled {
        LockedCard(compact: false)
      } else {
        switch resolved {
        case .usage:
          UsagePaneView()
        case .account(let id):
          if let account = accounts.account(id: id) {
            AccountPaneView(account: account)
              // Rebuild the pane when the account changes, so the session selection
              // inside it does not carry across to a different folder's list.
              .id(account.id)
          }
        case .codex(let id):
          if let account = codex.account(id: id) {
            CodexPaneView(account: account)
              .id(account.id)
          }
        case .grok(let id):
          if let account = grok.account(id: id) {
            GrokPaneView(account: account)
              .id(account.id)
          }
        case .projects:
          ProjectsPaneView()
        case .schedules:
          SchedulesPaneView()
        case .voice:
          VoiceConversationView()
        case nil:
          ContentUnavailableView {
            Label("No agents found", systemImage: "folder.badge.questionmark")
          } description: {
            Text(
              "Armada looks for ~/.claude and any ~/.claude-<name> beside it, for ~/.codex, and for ~/.grok. None of them has a sessions folder yet."
            )
          }
        }
      }
    }
    .toolbar {
      // Drawn here, because the split view does not add its own: this window is a hosted
      // `NSWindow`, not a `WindowGroup`, and it gets no sidebar button and no View menu to
      // hold ⌃⌘S — Armada is `LSUIElement`, so it has no menu bar. The shortcut rides on
      // the button instead, and works while the window is key.
      ToolbarItem(placement: .navigation) {
        let shown = columns != .detailOnly
        Button {
          withAnimation { columns = shown ? .detailOnly : .all }
        } label: {
          Label(shown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
        }
        .help(shown ? "Hide the sidebar" : "Show the sidebar")
        .keyboardShortcut("s", modifiers: [.control, .command])
      }
      // In the toolbar rather than pinned under the sidebar, where it lived first: it adds
      // to any section, including a Codex or Grok Build one that is not drawn until it has
      // a home, and under the sidebar it went away with the sidebar.
      //
      // Leading, beside the toggle: both are about the sidebar, and there it holds still,
      // where at the trailing edge it moved a slot whenever a pane added or dropped its
      // own items. Not the `plus`: that is New Session's (`NewSessionToolbarItem`), the
      // one used every day.
      ToolbarItem(placement: .navigation) {
        AddAccountMenu(adding: $addingAccount) {
          Label("Add Account", systemImage: "person.crop.circle.badge.plus")
        }
        .help("Add a Claude Code, Codex or Grok Build account")
        .disabled(!monitor.current.isEntitled)
      }
    }
  }

  /// Codex homes are what Armada changes schedules in; the Claude app's are only shown, so
  /// its tasks alone earn the row only once they are known to exist.
  private var showsSchedules: Bool { !codex.isEmpty || schedules.hasClaudeTasks }

  /// The stored selection if it still resolves, otherwise the first account.
  ///
  /// An account that has gone away falls back rather than showing an empty pane;
  /// the overview always resolves, because it does not depend on a folder existing.
  private var resolved: SidebarItem? {
    switch SidebarItem(stored: stored) {
    case .usage: .usage
    case .account(let id) where accounts.account(id: id) != nil: .account(id)
    case .codex(let id) where codex.account(id: id) != nil: .codex(id)
    case .grok(let id) where grok.account(id: id) != nil: .grok(id)
    case .projects: .projects
    case .schedules where showsSchedules: .schedules
    case .voice where voiceEnabled: .voice
    // A Codex home is a real fallback, not a consolation prize: someone may run
    // Codex and no Claude Code at all, and the window should open on their work.
    default:
      accounts.all.first.map { .account($0.id) } ?? codex.all.first.map { .codex($0.id) }
        ?? grok.all.first.map { .grok($0.id) }
    }
  }

  /// The stored selection, or the one a recorded take's `stage` cue moved to. The stored
  /// one cannot move during a take: `DemoSeed` pins it in the argument domain.
  private var stored: String {
    #if DEBUG
      if let item = DemoCues.shared.sidebar { return item.stored }
    #endif
    return storedAccount
  }

  /// Reading resolves to a real row; writing drops the `nil` that `List`
  /// hands back on its way up, before the tagged rows have registered — folding
  /// that into a real value overwrites the selection a frame later.
  private var selection: Binding<SidebarItem?> {
    Binding(
      get: { resolved },
      set: { newValue in
        guard let newValue else { return }
        storedAccount = newValue.stored
      })
  }
}

/// One account in the sidebar: the Claude icon, the organization, its plan, and
/// how many sessions it has.
struct AccountSidebarRow: View {
  let account: Account

  var body: some View {
    let count = account.sessions.sessions.count
    SidebarAccountRow(
      accountID: account.id, name: account.displayName, plan: account.planLabel,
      path: account.displayPath, count: count,
      countHelp: count == 1 ? "1 session" : "\(count) sessions",
      working: account.sessions.sessions.count { $0.state != .idle },
      workingTint: SessionState.working.tint, usage: SidebarUsage(account: account)
    ) {
      ClaudeIconView(size: 18)
    }
  }
}

/// One Codex home in the sidebar.
///
/// The same `SidebarAccountRow` as `AccountSidebarRow`, with one difference that is not
/// cosmetic: **the count counts live sessions, not rows.** The Codex pane lists recent
/// sessions as well as live ones, and a "14" beside a home where nothing is running
/// would be the most prominent wrong number in the window.
struct CodexSidebarRow: View {
  let account: CodexAccount

  var body: some View {
    let live = account.sessions.liveSessions.count
    SidebarAccountRow(
      accountID: account.id, name: account.displayName, plan: account.planLabel,
      path: account.displayPath, count: live,
      countHelp: live == 1 ? "1 live session" : "\(live) live sessions",
      working: account.sessions.workingCount, workingTint: CodexSessionState.working.tint,
      usage: SidebarUsage(account: account)
    ) {
      CodexIconView(size: 18)
    }
  }
}
