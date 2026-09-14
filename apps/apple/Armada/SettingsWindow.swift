import AppKit
import SupportKit
import SupportKitSettings
import SwiftUI

/// Armada's settings panes.
///
/// The protocol is qualified because this enum has the same name as it — which is
/// the fleet's convention, and the reason `references/shared-package.md` spells
/// the qualification out.
///
/// Licence is a pane, as in both siblings: a key is 240 characters that arrive by
/// paste or by drop, and it needs room and a window that survives losing focus.
///
/// Mouse is its own pane rather than a sixth section of General, and the reason is
/// shape rather than size: every other thing in General is a toggle or a picker that
/// answers on the spot, and this is a list you build. It is also the one place in
/// Settings that takes a live event while you are looking at it — see
/// `MouseBindingRow`'s Detect.
///
/// Help is a pane rather than rows on About, and last rather than beside it: it
/// keeps the About → What's New → Updates reading order the fleet settled on.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case mouse
  case usage
  case about
  case whatsNew
  case updates
  case licence
  case help

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .mouse: "Mouse"
    case .usage: "Usage"
    case .about: "About"
    case .whatsNew: "What's New"
    case .updates: "Updates"
    case .licence: "Licence"
    case .help: "Help"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .mouse: "computermouse"
    case .usage: "gauge.with.dots.needle.bottom.50percent"
    case .about: "info.circle"
    case .whatsNew: "sparkles"
    case .updates: "arrow.down.circle"
    case .licence: "checkmark.seal"
    case .help: "questionmark.circle"
    }
  }

  /// The unread-release count on What's New, and nothing anywhere else. Read on
  /// every sidebar draw, so it clears the moment the pane marks the notes seen.
  var badge: Int {
    self == .whatsNew && Changelog.hasUnseen ? Changelog.unseen.count : 0
  }

  static var defaultPane: SettingsPane { .general }
}

/// The settings window's content.
///
/// The shared `SettingsScaffold` rather than a hand-rolled `NavigationSplitView`:
/// Armada is greenfield, so it can consume the scaffold the rest of the fleet is
/// migrating onto rather than becoming an eleventh thing to migrate. The About
/// pane comes with it.
///
/// Hosted in an `NSWindow` by `HostedWindow`, not declared as a SwiftUI `Settings`
/// scene — that scene opens through `showSettingsWindow:`, routed via an app menu
/// an `LSUIElement` app does not have. Both sibling menu-bar apps found this
/// independently.
struct SettingsWindowView: View {
  var body: some View {
    SettingsScaffold(selection: Support.settings) { pane in
      switch pane {
      case .general: GeneralPane()
      case .mouse: MousePane()
      case .usage: UsageSettingsPane()
      case .about:
        // `includesSupport: false` — the support rows have their own pane now,
        // and the package would otherwise draw them in both.
        AboutSettingsPane(
          app: Support.app,
          showsIdentifier: true,
          includesSupport: false,
          preferIssueTracker: Support.preferIssueTracker)
      case .whatsNew: WhatsNewPane()
      case .updates: UpdatesPane()
      case .licence: LicensePane()
      case .help:
        HelpSettingsPane(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      }
    }
    // Sized for the content, never the window: a sidebar spends up to 240pt before
    // a pane sees any width, so a number carried over from a tabbed layout is too
    // narrow. 660 is where the fleet landed.
    .settingsWindowSize(minWidth: 660, idealWidth: 700, minHeight: 400, idealHeight: 460)
  }
}

struct GeneralPane: View {
  @State private var accounts = Accounts.shared
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var loginError: String?
  @State private var trust = AccessibilityTrust.shared
  @AppStorage(MenuBarHalo.defaultsKey) private var halo = MenuBarHalo.working
  @AppStorage(TerminalApp.defaultsKey) private var terminal = ""

  /// Reading resolves the unset case to whichever terminal a launch would actually
  /// use; writing stores the choice. Without the mapping the picker shows blank until
  /// somebody touches it, because "" is nobody's bundle id — the same shape as
  /// `MainWindowView.selection`.
  private var terminalSelection: Binding<String> {
    Binding(
      get: { TerminalApp.preferred(stored: terminal).bundleID },
      set: { terminal = $0 })
  }

  var body: some View {
    Form {
      Section {
        Toggle("Launch Armada at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, wanted in
            loginError = LoginItem.set(wanted)
            // What the service reports, not what was asked for: a registration
            // that did not take should show as unticked rather than be assumed.
            launchAtLogin = LoginItem.isEnabled
          }
        if let loginError {
          Text(loginError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } footer: {
        Text(
          "Armada watches sessions whenever it is licensed or in a trial. It never writes to your Claude configuration."
        )
      }

      Section {
        Picker("Ring the menu bar icon", selection: $halo) {
          ForEach(MenuBarHalo.allCases, id: \.self) { option in
            Text(option.label).tag(option)
          }
        }
      } header: {
        Text("Menu bar")
      } footer: {
        // Says what each rung costs rather than what it catches, because the
        // failure people will actually hit is a halo that is always on — and the
        // reason is not in the icon, it is in what the vendors do and do not
        // record. The sails fill on their own and are not part of this choice.
        Text(
          "The sails fill whenever a session is working. The halo is separate, and the wider you set it the more it guesses: Armada cannot tell a tool that is running from one waiting for your approval, and a Codex session that is merely open counts as waiting on you."
        )
      }

      Section {
        Picker("Open new sessions in", selection: terminalSelection) {
          ForEach(TerminalApp.installed) { terminal in
            Text(terminal.name).tag(terminal.bundleID)
          }
        }
      } header: {
        Text("New sessions")
      } footer: {
        // Says what the list leaves out, because a one-row picker otherwise reads as a
        // bug on a Mac with three terminals installed. See `TerminalApp` for the rule.
        Text(
          "Armada starts a session by opening a small script in your terminal, so it needs a terminal that runs a script it is handed — Terminal and iTerm do. It asks for no Automation permission, and the session appears in the list here like any other."
        )
      }

      Section {
        LabeledContent("Accessibility") {
          HStack(spacing: 8) {
            Text(trust.isTrusted ? "Allowed" : "Not allowed")
            Button("Open System Settings…") { HostWindow.openAccessibilitySettings() }
              .buttonStyle(.borderless)
          }
        }
      } header: {
        Text("Focusing sessions")
      } footer: {
        // Says what the grant changes rather than asking for it, and says what
        // Armada does with it — a permission request with no stated ceiling is the
        // kind people deny. The ceiling is real: the window, never the panel in it.
        Text(
          "Without this, Focus brings the application forward and macOS decides which of its windows you land on — whichever one you were in last. With it, Armada reads the host application's window titles and raises the one that has this session's folder open. It reads window titles, raises windows, and — once mouse buttons are switched on in Mouse — sees presses of your mouse's extra buttons. Nothing else."
        )
      }

      Section {
        ForEach(accounts.all) { account in
          LabeledContent {
            HStack(spacing: 6) {
              Text(account.displayPath)
                .truncationMode(.head)
                .lineLimit(1)
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([account.folder.base])
              } label: {
                Image(systemName: "arrow.up.forward.square")
              }
              .buttonStyle(.borderless)
              .help("Show in Finder")
            }
          } label: {
            Text(account.displayName)
            Text(
              account.planLabel.map { "\($0) · \(account.sessions.sessions.count) sessions" }
                ?? "\(account.sessions.sessions.count) sessions")
          }
        }
        if accounts.all.isEmpty {
          Text("No Claude config folder found").foregroundStyle(.secondary)
        }
      } header: {
        Text("Claude accounts")
      } footer: {
        // Says where the list comes from, because a folder that is missing from it
        // is the one thing a person will want to debug here — and the answer is
        // always the same: it has no sessions/ yet.
        Text(
          "Found by looking for ~/.claude and any ~/.claude-<name> beside it that has a sessions folder. Each is a separate organization with its own sessions and its own plan limits."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
  }
}

/// The pace profile, and what Armada has recorded.
///
/// Named with the `Settings` infix rather than matching `GeneralPane`, because the
/// main window's pane is `UsagePaneView` and a `UsagePane` sitting next to it would
/// be a name nobody can resolve at a glance.
struct UsageSettingsPane: View {
  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @State private var history = UsageHistory.shared

  var body: some View {
    Form {
      Section {
        ForEach(Array(orderedDays.enumerated()), id: \.element.index) { _, day in
          LabeledContent {
            HStack(spacing: 10) {
              Slider(
                value: binding(for: day.index), in: 0...2, step: 0.25)
              Text(percentLabel(day.index))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
            }
          } label: {
            Text(day.name)
          }
        }
        Button("Reset to an even week") { storedWeights = DayWeights.evenStored }
          .disabled(DayWeights(stored: storedWeights).isEven)
      } header: {
        Text("Expected effort per day")
      } footer: {
        // Says plainly what these are not, because a row of percentages in a
        // settings window reads as a cap until told otherwise.
        Text(
          "Relative weights, not limits — Armada cannot change your plan. They only decide where the pace marker sits, so a quiet weekend does not read as falling behind."
        )
      }

      Section {
        LabeledContent("Readings recorded") {
          Text("\(history.totalSampleCount)")
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        if let url = history.fileURL {
          LabeledContent("Stored in") {
            HStack(spacing: 6) {
              Text(
                (url.deletingLastPathComponent().path(percentEncoded: false) as NSString)
                  .abbreviatingWithTildeInPath
              )
              .truncationMode(.head)
              .lineLimit(1)
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              } label: {
                Image(systemName: "arrow.up.forward.square")
              }
              .buttonStyle(.borderless)
              .help("Show in Finder")
            }
          }
        }
        Button("Delete recorded history") { history.clear() }
          .disabled(history.totalSampleCount == 0)
      } header: {
        Text("History")
      } footer: {
        Text(
          "Armada records each new reading of your plan windows so it can draw the week rather than guess it. Readings stay on this Mac for 30 days, and nothing is ever written to your Claude configuration."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Usage")
  }

  /// Monday first for reading, `Calendar` order for storage.
  ///
  /// The two differ, and that is the point: the array index has to stay Foundation's
  /// Sunday-first numbering because that is what indexes the weekday component, while
  /// a list of days that starts on Sunday reads wrong to most of the people who will
  /// see it.
  private var orderedDays: [(index: Int, name: String)] {
    let symbols = Calendar.current.standaloneWeekdaySymbols
    return [2, 3, 4, 5, 6, 7, 1].map { (index: $0 - 1, name: symbols[$0 - 1]) }
  }

  private func binding(for index: Int) -> Binding<Double> {
    Binding(
      get: { DayWeights(stored: storedWeights).values[index] },
      set: { newValue in
        var values = DayWeights(stored: storedWeights).values
        values[index] = newValue
        storedWeights = DayWeights(values: values).stored
      })
  }

  private func percentLabel(_ index: Int) -> String {
    "\(Int((DayWeights(stored: storedWeights).values[index] * 100).rounded()))%"
  }
}
