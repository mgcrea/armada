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

  /// Where the window's selection is stored, and the one thing the menu bar panel
  /// has to write to steer the sidebar. The key keeps its original name so an
  /// existing selection survives the upgrade to a stored `SidebarItem`.
  static let defaultsKey = "armada.selectedAccount"

  private static let usageToken = "usage"
  private static let codexPrefix = "codex:"

  var stored: String {
    switch self {
    case .usage: Self.usageToken
    case .account(let id): id
    case .codex(let id): Self.codexPrefix + id
    }
  }

  init?(stored: String) {
    if stored == Self.usageToken {
      self = .usage
    } else if stored.hasPrefix(Self.codexPrefix) {
      self = .codex(String(stored.dropFirst(Self.codexPrefix.count)))
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

  /// What the sidebar had selected last time.
  ///
  /// A path rather than an index, so the window reopens on the same account even
  /// if a folder appeared or went away in between; `selection` below falls back
  /// to the first account when the stored one is gone.
  ///
  /// `MainWindowRoute` writes this same key to steer the sidebar from the menu bar
  /// panel, which is why it is a named constant rather than a literal here.
  @AppStorage(SidebarItem.defaultsKey) private var storedAccount: String = ""

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section("Overview") {
          Label("Usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
            .tag(SidebarItem.usage)
        }
        Section("Claude Code") {
          ForEach(accounts.all) { account in
            AccountSidebarRow(account: account)
              .tag(SidebarItem.account(account.id))
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
            }
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
      .safeAreaInset(edge: .bottom) {
        Text("Armada \(AppInfo.shortVersion)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
    } detail: {
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
      case nil:
        ContentUnavailableView {
          Label("No agents found", systemImage: "folder.badge.questionmark")
        } description: {
          Text(
            "Armada looks for ~/.claude and any ~/.claude-<name> beside it, and for ~/.codex. None of them has a sessions folder yet."
          )
        }
      }
    }
  }

  /// The stored selection if it still resolves, otherwise the first account.
  ///
  /// An account that has gone away falls back rather than showing an empty pane;
  /// the overview always resolves, because it does not depend on a folder existing.
  private var resolved: SidebarItem? {
    switch SidebarItem(stored: storedAccount) {
    case .usage: .usage
    case .account(let id) where accounts.account(id: id) != nil: .account(id)
    case .codex(let id) where codex.account(id: id) != nil: .codex(id)
    // A Codex home is a real fallback, not a consolation prize: someone may run
    // Codex and no Claude Code at all, and the window should open on their work.
    default: accounts.all.first.map { .account($0.id) } ?? codex.all.first.map { .codex($0.id) }
    }
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
    HStack(spacing: 8) {
      ClaudeIconView(size: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(account.displayName)
          .lineLimit(1)
        if let plan = account.planLabel {
          Text(plan)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 4)
      // A dot rather than a second number: the count is already the badge, and
      // what you want at a glance is whether anything in there is moving.
      if workingCount > 0 {
        Circle()
          .fill(SessionState.working.tint)
          .frame(width: 6, height: 6)
          .help("\(workingCount) working")
      }
    }
    .badge(account.sessions.sessions.count)
    .help(account.displayPath)
  }

  private var workingCount: Int {
    account.sessions.sessions.count { $0.state != .idle }
  }
}

/// One Codex home in the sidebar.
///
/// Deliberately the same shape as `AccountSidebarRow` — icon, name, plan, badge,
/// working dot — with one difference that is not cosmetic: **the badge counts live
/// sessions, not rows.** The Codex pane lists recent sessions as well as live
/// ones, and a badge of "14" next to a home where nothing is running would be the
/// most prominent wrong number in the window.
struct CodexSidebarRow: View {
  let account: CodexAccount

  var body: some View {
    HStack(spacing: 8) {
      CodexIconView(size: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(account.displayName)
          .lineLimit(1)
        if let plan = account.planLabel {
          Text(plan)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 4)
      if account.sessions.workingCount > 0 {
        Circle()
          .fill(CodexSessionState.working.tint)
          .frame(width: 6, height: 6)
          .help("\(account.sessions.workingCount) working")
      }
    }
    .badge(account.sessions.liveSessions.count)
    .help(account.displayPath)
  }
}
