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
/// Four sections, one more than Bastion and Cupertino have. The first is what
/// Armada watches and does: General, Supervisor, Usage.
///
/// Mouse and Voice are the second, and they are Armada's one extra split: both are
/// ways of driving it from outside its windows, a button press or a shortcut and a
/// question, and both hang off a system grant, Accessibility or the microphone.
///
/// The third is the fleet's two pairs. What's New and Updates are the version
/// pair: what did this build change, and is there a newer one. About and Help are
/// the identity pair, because both are where somebody goes when something is wrong
/// rather than when they are tuning something. Help is a pane rather than rows on
/// About because Armada is `LSUIElement`, so a Help menu would only exist while a
/// window happens to be open.
///
/// Licence is last and alone: somebody opens it because of a refusal or a
/// receipt, never to tune something.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case supervisor
  case usage
  case mouse
  case voice
  case whatsNew
  case updates
  case about
  case help
  case licence

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .supervisor: "Supervisor"
    case .usage: "Usage"
    case .mouse: "Mouse"
    case .voice: "Voice"
    case .whatsNew: "What's New"
    case .updates: "Updates"
    case .about: "About"
    case .help: "Help"
    case .licence: "Licence"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .supervisor: "binoculars"
    case .usage: "gauge.with.dots.needle.bottom.50percent"
    case .mouse: "computermouse"
    case .voice: "waveform"
    case .whatsNew: "sparkles"
    case .updates: "arrow.down.circle"
    case .about: "info.circle"
    case .help: "questionmark.circle"
    case .licence: "checkmark.seal"
    }
  }

  var group: SettingsPaneGroup {
    switch self {
    case .general, .supervisor, .usage: .configuration
    case .mouse, .voice: .input
    case .whatsNew, .updates, .about, .help: .information
    case .licence: .entitlement
    }
  }

  /// The unread-release count on What's New, and nothing anywhere else. Read on
  /// every sidebar draw, so it clears the moment the pane marks the notes seen.
  var badge: Int {
    self == .whatsNew && Changelog.hasUnseen ? Changelog.unseen.count : 0
  }

  static var defaultPane: SettingsPane { .general }
}

/// Armada's two sections between the package's pair. Sections draw in ascending
/// `order`, and `.entitlement` sits at 1_000 to leave room for exactly this.
extension SettingsPaneGroup {
  nonisolated static let input = SettingsPaneGroup(order: 100)
  nonisolated static let information = SettingsPaneGroup(order: 500)
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
      case .supervisor: SupervisorPane()
      case .usage: UsageSettingsPane()
      case .mouse: MousePane()
      case .voice: VoicePane()
      case .whatsNew: WhatsNewPane()
      case .updates: UpdatesPane()
      case .about:
        // `includesSupport: false` — the support rows have their own pane now,
        // and the package would otherwise draw them in both.
        AboutSettingsPane(
          app: Support.app,
          showsIdentifier: true,
          includesSupport: false,
          preferIssueTracker: Support.preferIssueTracker)
      case .help:
        HelpSettingsPane(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      case .licence: LicensePane()
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
  @State private var codex = CodexAccounts.shared
  @State private var grok = GrokAccounts.shared
  @AppStorage(PanelVisibility.defaultsKey) private var storedHidden = ""
  @State private var monitor = EntitlementMonitor.shared
  @State private var addingAccount: NewAccount.Vendor?
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var loginError: String?
  @State private var trust = AccessibilityTrust.shared
  @AppStorage(MenuBarHalo.defaultsKey) private var halo = MenuBarHalo.working
  @AppStorage(TranscriptStyle.defaultsKey)
  private var transcriptStyle = TranscriptStyle.fallback.stored
  @AppStorage(TerminalApp.defaultsKey) private var terminal = ""
  @AppStorage(VSCodeLaunch.defaultsKey) private var inVSCode = false
  @AppStorage(VSCodeLaunch.sendPromptDefaultsKey) private var sendPromptInVSCode = true
  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var handoverCopiesOnly = false
  @AppStorage(PromptCacheAlertScope.defaultsKey) private var cacheAlerts = PromptCacheAlertScope.off
  @AppStorage(PromptCacheAlertSize.defaultsKey)
  private var cacheAlertMinimum = PromptCacheAlertSize.fallback
  @State private var notifier = PromptCacheNotifier.shared

  /// Reading resolves the unset case to whichever terminal a launch would actually
  /// use; writing stores the choice. Without the mapping the picker shows blank until
  /// somebody touches it, because "" is nobody's bundle id — the same shape as
  /// `MainWindowView.selection`.
  /// Every account on the panel, in the panel's order: Claude, Codex, Grok Build.
  private var panelAccounts: [(id: String, name: String, detail: String)] {
    accounts.all.map { ($0.id, $0.displayName, "Claude Code · \($0.displayPath)") }
      + codex.all.map { ($0.id, $0.displayName, "Codex · \($0.displayPath)") }
      + grok.all.map { ($0.id, $0.displayName, "Grok Build · \($0.displayPath)") }
  }

  private func shown(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !PanelVisibility.hidden(stored: storedHidden).contains(id) },
      set: { storedHidden = PanelVisibility.setting(id, shown: $0, in: storedHidden) })
  }

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
          "Armada watches sessions whenever it is licensed or in a trial. It writes to your Claude configuration only to mark a saved project trusted when it starts a session there, and to add one hook per account if you turn on Deliver messages in Supervisor."
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
          "The sails fill whenever a session is working. The halo is separate, and the wider you set it the more it guesses: Armada cannot tell a tool that is running from one waiting for your approval, and a Codex or Grok session that is merely open counts as waiting on you. To keep one limit's figure beside the icon, star it in Usage or above an account's sessions."
        )
      }

      Section {
        Picker("Warn before a prompt cache expires", selection: $cacheAlerts) {
          ForEach(PromptCacheAlertScope.allCases, id: \.self) { option in
            Text(option.label).tag(option)
          }
        }
        .onChange(of: cacheAlerts) { _, scope in
          guard scope != .off else { return }
          Task { await notifier.requestAuthorization() }
        }
        if cacheAlerts != .off {
          Picker("Only for prompts", selection: $cacheAlertMinimum) {
            ForEach(PromptCacheAlertSize.options, id: \.self) { tokens in
              Text(tokens == 0 ? "Of any size" : "Over \(TokenCount.short(tokens))").tag(tokens)
            }
          }
          if notifier.isDenied {
            HStack(spacing: 8) {
              Text("Notifications for Armada are turned off in System Settings.")
                .font(.caption)
                .foregroundStyle(.red)
              Button("Open System Settings…") {
                let id = Bundle.main.bundleIdentifier ?? ""
                if let url = URL(
                  string:
                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
                {
                  NSWorkspace.shared.open(url)
                }
              }
              .buttonStyle(.borderless)
              .font(.caption)
            }
          }
        }
      } header: {
        Text("Notifications")
      } footer: {
        // Says what the warning buys, because "prompt cache" is a term most people have
        // never had a reason to learn, and the setting is only worth turning on once the
        // cost is clear.
        Text(
          "Claude keeps a session's prompt cached for an hour (or five minutes) after its last request. Reply while it is warm and the next turn reads the whole prompt at a tenth of the price; let it lapse and the next turn writes it all back at up to twice the price, against the same plan limits. Armada warns once, in the last quarter of that time, and clicking the notification brings the session forward. Codex and Grok do not say how long their caches last, so they are never warned about."
        )
      }
      .task { await notifier.refreshAuthorization() }

      Section {
        Picker("Window style", selection: $transcriptStyle) {
          ForEach(TranscriptStyle.allCases, id: \.stored) { option in
            Text(option.label).tag(option.stored)
          }
        }
        Text(TranscriptStyle(stored: transcriptStyle).detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Transcript")
      } footer: {
        // Says where the window comes from, because "Read Transcript" is two menus deep and
        // someone changing this setting may never have opened one.
        Text(
          "Read Transcript, on a session's details or its right-click menu, opens that session's conversation in a window of its own. Follow, in that window, re-reads the transcript as it grows and keeps you at the newest turn."
        )
      }

      if panelAccounts.count > 1 {
        Section {
          ForEach(panelAccounts, id: \.id) { entry in
            Toggle(isOn: shown(entry.id)) {
              Text(entry.name)
              Text(entry.detail)
            }
          }
        } header: {
          Text("Menu bar panel")
        } footer: {
          Text(
            "A hidden account stays in Armada's window, keeps its starred figure beside the icon, and still rings the halo when one of its sessions needs you."
          )
        }
      }

      Section {
        Picker("Open new sessions in", selection: terminalSelection) {
          ForEach(TerminalApp.installed) { terminal in
            Text(terminal.name).tag(terminal.bundleID)
          }
        }
        // Only where VS Code is installed, like the terminals above. See `VSCodeLaunch` for
        // which launches it takes and why the rest stay in the terminal.
        if VSCodeLaunch.isInstalled {
          Toggle("Start Claude Code sessions in \(VSCodeLaunch.name)", isOn: $inVSCode)
          if inVSCode {
            Toggle("Send an agent's opening message", isOn: $sendPromptInVSCode)
          }
          if inVSCode && !trust.isTrusted {
            Text("Needs Accessibility, below, to bring the project's window to the front.")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
        // See `HandoverTarget.copyOnlyDefaultsKey`: for switching an editor window's account
        // by hand, where a terminal on the other account would go unused.
        Toggle("Continue on another account without opening a terminal", isOn: $handoverCopiesOnly)
      } header: {
        Text("New sessions")
      } footer: {
        // Says what the list leaves out, because a one-row picker otherwise reads as a
        // bug on a Mac with three terminals installed. See `TerminalApp` for the rule.
        Text(
          VSCodeLaunch.isInstalled
            ? "Armada starts a session by opening a small script in your terminal, so it needs a terminal that runs a script it is handed — Terminal and iTerm do. In \(VSCodeLaunch.name), a fresh Claude Code session opens as a tab in the project's own window, or a new window on the session's account. An agent's opening message is typed into the tab and sent with Return, or left for you to send when that is off. Forks, Codex and the supervisor still start in the terminal."
            : "Armada starts a session by opening a small script in your terminal, so it needs a terminal that runs a script it is handed — Terminal and iTerm do. It asks for no Automation permission, and the session appears in the list here like any other."
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
          "Without this, Focus brings the application forward and macOS decides which of its windows you land on — whichever one you were in last. With it, Armada reads the host application's window titles and raises the one that has this session's folder open, and does the same for a project's window before starting a session in Visual Studio Code. It reads window titles, raises windows, and — once mouse buttons are switched on in Mouse — sees presses of your mouse's extra buttons. Nothing else."
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
        AddAccountMenu(adding: $addingAccount) { Text("Add Account") }
          .fixedSize()
          .disabled(!monitor.current.isEntitled)
      } header: {
        Text("Claude accounts")
      } footer: {
        // Says where the list comes from, because a folder that is missing from it
        // is the one thing a person will want to debug here — and the answer is
        // always the same: it has no sessions/ yet.
        Text(
          "Found by looking for ~/.claude and any ~/.claude-<name> beside it that has a sessions folder. Each is a separate organization with its own sessions and its own plan limits. Add Account opens Claude Code, Codex or Grok Build on a new folder so you can sign in there."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
    .sheet(item: $addingAccount) { AddAccountSheet(vendor: $0) }
  }
}

/// The pace profile, and what Armada has recorded.
///
/// Named with the `Settings` infix rather than matching `GeneralPane`, because the
/// main window's pane is `UsagePaneView` and a `UsagePane` sitting next to it would
/// be a name nobody can resolve at a glance.
struct UsageSettingsPane: View {
  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored
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
        Picker("Starts at", selection: startBinding) { hourOptions }
        Picker("Ends at", selection: endBinding) { hourOptions }
        LabeledContent("Outside those hours") {
          HStack(spacing: 10) {
            Slider(value: outsideBinding, in: 0...1, step: 0.05)
            Text("\(Int((hours.outside * 100).rounded()))%")
              .font(.caption.monospacedDigit())
              .frame(width: 40, alignment: .trailing)
              .foregroundStyle(.secondary)
          }
        }
        Button("Count every hour the same") { storedHours = WorkingHours.flatStored }
          .disabled(hours.isFlat)
      } header: {
        Text("Working hours")
      } footer: {
        // The weekly window only, and it says so, because the session meter sitting
        // unmoved beside a changed weekly one would otherwise read as a bug.
        Text(
          "Hours outside the range count for less, so an evening's work is not measured against a week of round-the-clock days. Applies to the weekly window. A range that ends before it starts runs past midnight."
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

  private var hours: WorkingHours { WorkingHours(stored: storedHours) }

  private var startBinding: Binding<Int> {
    Binding(
      get: { hours.start },
      set: { storedHours = WorkingHours(start: $0, end: hours.end, outside: hours.outside).stored })
  }

  private var endBinding: Binding<Int> {
    Binding(
      get: { hours.end },
      set: {
        storedHours = WorkingHours(start: hours.start, end: $0, outside: hours.outside).stored
      })
  }

  private var outsideBinding: Binding<Double> {
    Binding(
      get: { hours.outside },
      set: { storedHours = WorkingHours(start: hours.start, end: hours.end, outside: $0).stored })
  }

  /// Every hour of the day, labelled the way this Mac shows times: "09:00" or "9 AM".
  private var hourOptions: some View {
    ForEach(0..<24, id: \.self) { hour in
      Text(Self.hourLabel(hour)).tag(hour)
    }
  }

  /// Formatted on a fixed January day, so no clock change can drop or double an hour.
  private static func hourLabel(_ hour: Int) -> String {
    let date = Calendar.current.date(
      from: DateComponents(year: 2001, month: 1, day: 1, hour: hour))
    return date?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
  }
}
