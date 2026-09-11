import SwiftUI

struct MainWindowView: View {
  @State private var accounts = Accounts.shared

  /// The selected account's config-folder path.
  ///
  /// A path rather than an index, so the window reopens on the same account even
  /// if a folder appeared or went away in between; `selection` below falls back
  /// to the first account when the stored one is gone.
  @AppStorage("armada.selectedAccount") private var storedAccount: String = ""

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section("Accounts") {
          ForEach(accounts.all) { account in
            AccountSidebarRow(account: account)
              .tag(account.id)
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
      if let account = resolvedAccount {
        AccountPaneView(account: account)
          // Rebuild the pane when the account changes, so the session selection
          // inside it does not carry across to a different folder's list.
          .id(account.id)
      } else {
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

  /// The stored account if it still exists, otherwise the first one.
  private var resolvedAccount: Account? {
    accounts.account(id: storedAccount) ?? accounts.all.first
  }

  /// Reading resolves to a real account; writing drops the `nil` that `List`
  /// hands back on its way up, before the tagged rows have registered — folding
  /// that into a real value overwrites the selection a frame later.
  private var selection: Binding<String?> {
    Binding(
      get: { resolvedAccount?.id },
      set: { newValue in
        guard let newValue else { return }
        storedAccount = newValue
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
