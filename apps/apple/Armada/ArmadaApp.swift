import AppKit
import SupportKitSettings
import SupportKitUI
import SwiftUI

@main
struct ArmadaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra {
      StatusMenu()
    } label: {
      MenuBarLabel()
    }
    .menuBarExtraStyle(.window)
    .commands {
      // ⌘, has to reach a window this app owns rather than the SwiftUI `Settings`
      // scene, which an `LSUIElement` app cannot open. See `HostedWindow`.
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { AppDelegate.shared?.showSettings() }
          .keyboardShortcut(",", modifiers: .command)
      }
      SupportCommands(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
    }
  }
}

/// The menu bar glyph: outlined when everything is idle, filled when something is
/// working.
///
/// Both are template assets, so AppKit tints them for light, dark and the
/// highlighted menu bar — which is why neither carries a colour of its own and why
/// nothing here sets one.
private struct MenuBarLabel: View {
  @State private var accounts = Accounts.shared

  var body: some View {
    Image(isWorking ? "MenuBarIconActive" : "MenuBarIcon")
      .accessibilityLabel(
        isWorking ? "Armada — a session is working" : "Armada — all sessions idle")
  }

  /// Across every account: the menu bar answers "is anything of mine moving",
  /// which is not a per-organization question.
  private var isWorking: Bool {
    accounts.workingSessionCount > 0
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private(set) static var shared: AppDelegate?

  private lazy var mainWindow = HostedWindow(
    title: "Armada",
    autosaveName: "main",
    contentSize: NSSize(width: 900, height: 560)
  ) { MainWindowView() }

  private lazy var settingsWindow = HostedWindow(
    title: "Armada Settings",
    autosaveName: "settings",
    contentSize: NSSize(width: 700, height: 460)
  ) { SettingsWindowView() }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.shared = self
    Accounts.shared.start()
    DockPresence.observe()
  }

  /// A click on the Dock icon, which exists only while a window is open.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showMain()
    return true
  }

  func showMain() { mainWindow.show() }

  func showSettings() { settingsWindow.show() }

  func showSettings(_ pane: SettingsPane) {
    // Write first, then open: that is what makes a deep link work on a window
    // which is already up.
    Support.settings.select(pane)
    settingsWindow.show()
  }
}

/// The menu bar popover: what is happening, in one glance.
///
/// One block per account, because the two organizations share nothing — separate
/// sessions, separate rate limits — and a single merged total would be the wrong
/// number twice over. With one account the section header is dropped, so a person
/// who has never heard of a second config folder sees no scaffolding for it.
struct StatusMenu: View {
  @State private var accounts = Accounts.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        // The title opens the window, same as the footer button. A heading that
        // does something is worth a word: it is not a link and gets no link
        // colour, because colouring it would make the one piece of plain text in
        // the panel look like the only thing worth reading. The pointer and the
        // tooltip are the affordance instead, which is how a Finder path bar or
        // a Safari favicon says the same thing.
        //
        // No ⌘O here. The footer button already answers that chord and two
        // views claiming one shortcut is ambiguous to SwiftUI, not redundant.
        Button {
          AppDelegate.shared?.showMain()
        } label: {
          Text("Armada").font(.headline)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Open Armada")

        Spacer()

        // The version opens About, which is the pane that says what this number
        // means — build, credits, the feedback links. Same treatment as the
        // title beside it: no link colour, the pointer and the tooltip carry it.
        // A version string is already the thing people click looking for the
        // rest of the version, so this is the shortest route to the one surface
        // that answers them.
        Button {
          AppDelegate.shared?.showSettings(.about)
        } label: {
          Text(AppInfo.shortVersion)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("About Armada")
      }

      if accounts.all.isEmpty {
        Divider()
        Text("No Claude config folder found")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(accounts.all) { account in
          Divider()
          AccountSummary(account: account, showsName: accounts.all.count > 1)
        }
      }

      Divider()

      // One row, as Bastion and Cupertino have it, and the same rule decides
      // which side each thing lands on: what OPENS something sits left, what you
      // GO TO sits right. "Open Armada" is the one being recommended, so it is
      // the only tinted button; a gear is a route, not advice.
      //
      // Settings is a glyph rather than a word. Three text buttons stacked as
      // three rows was the panel's own summary claim spent on chrome, and side
      // by side they do not fit: the width the other two apps measured
      // truncating "Open Cupertino" at 320pt is wider than this panel. A gear is
      // the one glyph nobody needs taught, and its tooltip and ⌘, carry the name.
      HStack {
        Button("Open Armada") { AppDelegate.shared?.showMain() }
          .buttonStyle(.glass)
          .keyboardShortcut("o")

        Spacer()

        Button {
          AppDelegate.shared?.showSettings()
        } label: {
          Image(systemName: "gearshape")
        }
        .keyboardShortcut(",")
        .help("Settings (⌘,)")

        Button("Quit") { NSApp.terminate(nil) }
          .keyboardShortcut("q")
      }
      .controlSize(.small)
    }
    .padding(12)
    .frame(width: 280)
  }
}

/// One account's block in the popover.
struct AccountSummary: View {
  let account: Account
  let showsName: Bool

  /// Three, not five. The popover has to fit two of these plus the buttons, and
  /// the list in the window is one click away.
  private static let visibleSessions = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if showsName {
        HStack(spacing: 6) {
          ClaudeIconView(size: 14)
          Text(account.displayName)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if let plan = account.planLabel {
            Text(plan)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      Text(summary)
        .font(.callout)
        .foregroundStyle(sessions.isEmpty ? .secondary : .primary)

      ForEach(sessions.prefix(Self.visibleSessions)) { session in
        HStack(spacing: 6) {
          StateDot(state: session.state)
          Text(session.displayName)
            .font(.caption)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
      }
      if sessions.count > Self.visibleSessions {
        Text("and \(sessions.count - Self.visibleSessions) more")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let usage = account.usage, !usage.isEmpty {
        HStack(spacing: 16) {
          CompactUsage(label: "5h", window: usage.fiveHour)
          CompactUsage(label: "7d", window: usage.sevenDay)
        }
        .padding(.top, 2)
      }
    }
  }

  private var sessions: [Session] { account.sessions.sessions }

  private var summary: String {
    let working = sessions.count { $0.state != .idle }
    let total = sessions.count
    if total == 0 { return "No sessions running" }
    let label = total == 1 ? "1 session" : "\(total) sessions"
    return working == 0 ? "\(label), all idle" : "\(label), \(working) active"
  }
}

struct CompactUsage: View {
  let label: String
  let window: UsageWindow?

  var body: some View {
    HStack(spacing: 5) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(window.map { "\($0.utilization)%" } ?? "—")
        .font(.callout.monospacedDigit())
      if let window {
        ProgressView(value: Double(window.utilization), total: 100)
          .progressViewStyle(.linear)
          .tint(UsageTint.for(window.utilization))
          .frame(width: 52)
      }
    }
  }
}
