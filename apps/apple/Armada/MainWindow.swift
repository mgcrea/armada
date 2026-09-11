import SwiftUI

/// What the sidebar can be showing.
///
/// The selection used to be an account id and is now a choice between the overview
/// and one account, which is the whole cost of adding a second sidebar section.
///
/// Round-trips through one defaults string because that is what `@AppStorage`
/// stores. Account ids are absolute paths — `Account.id` guarantees it — so they
/// always begin with a slash and can never be mistaken for the overview's token.
enum SidebarItem: Hashable {
  case usage
  case account(String)

  private static let usageToken = "usage"

  var stored: String {
    switch self {
    case .usage: Self.usageToken
    case .account(let id): id
    }
  }

  init?(stored: String) {
    if stored == Self.usageToken {
      self = .usage
    } else if stored.hasPrefix("/") {
      self = .account(stored)
    } else {
      return nil
    }
  }
}

struct MainWindowView: View {
  @State private var accounts = Accounts.shared

  /// What the sidebar had selected last time.
  ///
  /// A path rather than an index, so the window reopens on the same account even
  /// if a folder appeared or went away in between; `selection` below falls back
  /// to the first account when the stored one is gone. The key keeps its old name
  /// so an existing selection survives the upgrade — a stored path still decodes.
  @AppStorage("armada.selectedAccount") private var storedAccount: String = ""

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section("Overview") {
          Label("Usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
            .tag(SidebarItem.usage)
        }
        Section("Accounts") {
          ForEach(accounts.all) { account in
            AccountSidebarRow(account: account)
              .tag(SidebarItem.account(account.id))
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
      case nil:
        ContentUnavailableView {
          Label("No Claude config folder", systemImage: "folder.badge.questionmark")
        } description: {
          Text(
            "Armada looks for ~/.claude and any ~/.claude-<name> beside it. None of them has a sessions folder yet."
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
    default: accounts.all.first.map { .account($0.id) }
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
