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
      // SF Symbol for now. `design/armada-menubar.svg` replaces this with the
      // template pair once `make icon` has run.
      Image(systemName: "sailboat")
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
    SessionWatcher.shared.start()
    UsageTracker.shared.start()
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
struct StatusMenu: View {
  @State private var watcher = SessionWatcher.shared
  @State private var tracker = UsageTracker.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Armada").font(.headline)
        Spacer()
        Text(AppInfo.shortVersion)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      if watcher.sessions.isEmpty {
        Text("No sessions running")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text(summary).font(.callout)
          ForEach(watcher.sessions.prefix(5)) { session in
            HStack(spacing: 6) {
              StateDot(state: session.state)
              Text(session.displayName)
                .font(.caption)
                .lineLimit(1)
              Spacer(minLength: 0)
            }
          }
          if watcher.sessions.count > 5 {
            Text("and \(watcher.sessions.count - 5) more")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let snapshot = tracker.snapshot, !snapshot.isEmpty {
        Divider()
        HStack(spacing: 16) {
          CompactUsage(label: "5h", window: snapshot.fiveHour)
          CompactUsage(label: "7d", window: snapshot.sevenDay)
        }
      }

      Divider()

      Button("Open Armada") { AppDelegate.shared?.showMain() }
      Button("Settings…") { AppDelegate.shared?.showSettings() }
        .keyboardShortcut(",", modifiers: .command)
      Button("Quit Armada") { NSApp.terminate(nil) }
        .keyboardShortcut("q", modifiers: .command)
    }
    .buttonStyle(.plain)
    .padding(12)
    .frame(width: 260)
  }

  private var summary: String {
    let working = watcher.sessions.filter { $0.state != .idle }.count
    let total = watcher.sessions.count
    let sessions = total == 1 ? "1 session" : "\(total) sessions"
    return working == 0 ? "\(sessions), all idle" : "\(sessions), \(working) active"
  }
}

struct CompactUsage: View {
  let label: String
  let window: UsageWindow?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(window.map { "\($0.utilization)%" } ?? "—")
        .font(.callout.monospacedDigit())
    }
  }
}
