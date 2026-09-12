import AppKit
import Combine
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
/// working, and ringed by a halo while the condition in Settings holds.
///
/// All four are template assets, so AppKit tints them for light, dark and the
/// highlighted menu bar — which is why none carries a colour of its own and why
/// nothing here sets one.
///
/// **Four whole assets rather than a halo overlaid in SwiftUI**, and that is not
/// tidiness. SwiftUI renders a `MenuBarExtra` label as a single template image;
/// cupertino measured an overlay on one — a 5pt dot — never being drawn at all,
/// and its `MenuBarLabel` carries the measurement. A different *file* survives
/// template rendering where a composed overlay does not, so the halo ships as
/// geometry in the asset, and the four files share the rig to the decimal so
/// nothing shifts when a state flips.
///
/// The fill and the halo are independent on purpose. The fill has meant "something
/// is working" since before the halo existed and still does; the halo means
/// whatever `MenuBarHalo` has been set to, which is a wider question and, on the
/// two outer rungs, a guessed one. All four combinations are reachable — including
/// filled-without-halo, because the fill counts `.runningTool` and the default
/// halo does not.
private struct MenuBarLabel: View {
  @State private var accounts = Accounts.shared
  @State private var codex = CodexAccounts.shared
  @AppStorage(MenuBarHalo.defaultsKey) private var halo = MenuBarHalo.working

  var body: some View {
    Image(assetName)
      .accessibilityLabel(accessibilityLabel)
  }

  /// Across every account and every vendor: the menu bar answers "is anything of
  /// mine moving", which is neither a per-organization nor a per-vendor question.
  private var isWorking: Bool {
    accounts.workingSessionCount > 0 || codex.workingCount > 0
  }

  private var isHaloLit: Bool {
    halo.isLit(
      claudeWorking: accounts.writingSessionCount,
      claudeBlocked: accounts.blockedSessionCount,
      codexWorking: codex.workingCount,
      codexAwaitingInput: codex.awaitingInputCount)
  }

  private var assetName: String {
    switch (isWorking, isHaloLit) {
    case (true, true): "MenuBarIconActiveHalo"
    case (true, false): "MenuBarIconActive"
    case (false, true): "MenuBarIconHalo"
    case (false, false): "MenuBarIcon"
    }
  }

  /// The halo is the louder fact, so it leads when it is lit — someone reaching
  /// for VoiceOver here wants to know whether anything is asking for them before
  /// they are told how many sessions are mid-turn.
  private var accessibilityLabel: String {
    switch (isWorking, isHaloLit) {
    case (true, true): "Armada — a session is working and wants you"
    case (true, false): "Armada — a session is working"
    case (false, true): "Armada — a session is waiting on you"
    case (false, false): "Armada — all sessions idle"
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
    // "settings-panes", not "settings": cupertino renamed away from the bare
    // name as a deliberate one-time frame reset and bastion followed, so this is
    // the fleet's name. Free to adopt here — Armada has never shipped, so there
    // is no remembered frame to reset.
    autosaveName: "settings-panes",
    contentSize: NSSize(width: 700, height: 460)
  ) { SettingsWindowView() }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.shared = self
    Accounts.shared.start()
    CodexAccounts.shared.start()
    DockPresence.observe()
    SessionHostLookup.observeHostTermination()
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
  @State private var codex = CodexAccounts.shared

  /// The panel's clock, and the fix for the bug this panel had the longest: every
  /// reset time, every forecast and the staleness line below are relative to *now*,
  /// and nothing else here moves. The two windows both push state in from a pane
  /// that owns a tick; the popover owns nothing, so a body evaluated at 12:58 still
  /// said "resets in 2m" at half past two. Same one-second `Timer.publish` the three
  /// panes use, rather than a second mechanism that would drift from them.
  ///
  /// One second is finer than anything on this panel needs — the shortest thing it
  /// renders is "in 4h" — and unlike a pane's clock this one may well go on ticking
  /// while the panel is closed, since SwiftUI keeps `MenuBarExtra` content alive. It
  /// is kept anyway: the work per tick is assigning a `Date`, and matching what the
  /// panes do is worth more than shaving that. `TimelineView(.periodic:)` would pause
  /// itself while hidden and is the tidier answer if this ever shows up in a profile.
  @State private var now = Date()
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

      if accounts.all.isEmpty && codex.isEmpty {
        Divider()
        Text("No Claude Code or Codex folder found")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        // Once there are two vendors on the panel every block needs its name, or
        // the second one reads as more rows of the first.
        let showsNames = accounts.all.count + codex.all.count > 1
        ForEach(accounts.all) { account in
          Divider()
          AccountSummary(account: account, showsName: showsNames, now: now)
        }
        ForEach(codex.all) { account in
          Divider()
          CodexSummary(account: account, showsName: showsNames, now: now)
        }
      }

      Divider()

      // One row, as Bastion and Cupertino have it, and the same rule decides
      // which side each thing lands on: what OPENS something sits left, what you
      // GO TO sits right. "Open Armada" is the one being recommended, so it is
      // the only tinted button; a gear is a route, not advice.
      //
      // Settings is a glyph rather than a word, and as of the widening to 320pt
      // that rests on one reason rather than two. The width argument is gone: this
      // panel used to be 280pt and the note here was that 320pt — where the other
      // two apps measured "Open Cupertino" truncating — was wider than it. It is
      // now exactly that width, though "Open Armada" is the shorter word. What
      // stands is the other reason: a third text button is the panel's own summary
      // claim spent on chrome. A gear is the one glyph nobody needs taught, and its
      // tooltip and ⌘, carry the name.
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
    .frame(width: 320)
    .onReceive(clock) { now = $0 }
    // Belt and braces beside the tick above. The tick keeps the *rendering* honest;
    // this asks for a fresh *reading* the moment the panel is opened, rather than
    // waiting out the rest of a poll in front of someone who just clicked to find
    // out. The file re-reads and the Codex scan are nearly free; `probeAll` is not,
    // which is why it throttles itself — opening the panel twice in a row is one
    // process, not two.
    .onAppear {
      accounts.refreshAll()
      accounts.probeAll()
      codex.refreshAll()
    }
  }
}

/// One account's block in the popover.
struct AccountSummary: View {
  let account: Account
  let showsName: Bool
  let now: Date

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored

  /// Three, not five. The popover has to fit two of these plus the buttons, and
  /// the list in the window is one click away.
  private static let visibleSessions = 3

  /// Hosts for the visible rows only, resolved once when the panel opens.
  ///
  /// The inner optional is load-bearing: a present key with a nil value is a session
  /// that was looked up and has no host, which is what lets a row render as plain
  /// text rather than as a button that would do nothing. A missing key is a lookup
  /// that has not happened yet.
  @State private var hosts: [pid_t: SessionHost?] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if showsName {
        // The header is the block's own row: it opens the account's pane, with
        // nothing selected in it. Same treatment as the session rows below, because
        // it is the same promise — everything in this block, at full size.
        PanelRow(help: "Show \(account.displayName) in Armada") {
          MenuBarPanel.dismiss()
          MainWindowRoute.shared.open(.account(account.id))
        } label: {
          HStack(spacing: 6) {
            ClaudeIconView(size: 14)
            Text(account.displayName)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            // The count rides the name's line rather than taking one of its own. It is
            // a clause about the account, not a heading, and at `.callout` on its own
            // row it was the largest text in the block and read as the block's title —
            // with the name it actually belongs to sitting above it in a smaller font.
            // A line saved here is a line the session list and meters get back, which
            // is what a panel holding three accounts is short of.
            Text("• \(summary)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
            if let plan = account.planLabel {
              Text(plan)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      } else {
        // Nothing to hang it off: one account draws no name row, so the count is the
        // block's opening line and keeps the weight to match. It still opens the
        // pane — with one account it is the only header the block has.
        PanelRow(help: "Show \(account.displayName) in Armada") {
          MenuBarPanel.dismiss()
          MainWindowRoute.shared.open(.account(account.id))
        } label: {
          Text(summary)
            .font(.callout)
            .foregroundStyle(sessions.isEmpty ? .secondary : .primary)
        }
      }

      ForEach(sessions.prefix(Self.visibleSessions)) { session in
        SummaryRow(
          session: session, accountID: account.id, host: hosts[session.registry.pid] ?? nil)
      }
      if sessions.count > Self.visibleSessions {
        Text("and \(sessions.count - Self.visibleSessions) more")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let usage = account.usage, !usage.isEmpty {
        // Corrected before anything is drawn from them, so the figure, the bar, the
        // reset and the forecast all describe the same window.
        let five = usage.window(.fiveHour, correctedBy: account.quotaHit, now: now)
        let seven = usage.window(.sevenDay, correctedBy: account.quotaHit, now: now)
        let fiveHour = forecast(five, .fiveHour, usage.fetchedAt)
        let sevenDay = forecast(seven, .sevenDay, usage.fetchedAt)
        VStack(alignment: .leading, spacing: 3) {
          CompactUsage(label: "5h", window: five, forecast: fiveHour, now: now)
          CompactUsage(label: "7d", window: seven, forecast: sevenDay, now: now)
        }
        .padding(.top, 2)
        // The panel was the one surface showing a percentage with nothing to say how
        // old it was, which is exactly where a stale figure does the most damage: it
        // is the surface people check *instead of* opening the window.
        StalenessBadge(
          fetchedAt: usage.fetchedAt, now: now, source: usage.source, style: .compact)
        // Only when there is something to act on. "On pace" in a menu is a line of
        // chrome in a 320pt panel whose job is the session list above it, and the
        // weekly window is the one worth interrupting someone about.
        if let sevenDay, sevenDay.isNoteworthy {
          UsageVerdictLine(forecast: sevenDay)
        }
      }
    }
    // Bounded to the rows that are drawn, and keyed on them so a session ending
    // while the panel is open re-resolves rather than leaving a stale row. The
    // lookup caches, so reopening the panel costs one syscall per row.
    .task(id: sessions.prefix(Self.visibleSessions).map(\.id)) {
      var resolved: [pid_t: SessionHost?] = [:]
      for session in sessions.prefix(Self.visibleSessions) {
        resolved[session.registry.pid] = SessionHostLookup.host(for: session.registry)
      }
      hosts = resolved
    }
  }

  private var sessions: [Session] { account.sessions.sessions }

  private func forecast(
    _ window: UsageWindow?, _ length: UsageWindowLength, _ fetchedAt: Date?
  ) -> UsageForecast? {
    // A window known to be exhausted has nothing left to project: "at this rate,
    // 100% in 20 minutes" under a meter that is already at 100% is a forecast of
    // the past. The reset line beside it is the whole story there.
    guard let window, window.rejectedAt == nil else { return nil }
    return UsageForecast(
      window: window, length: length, weights: DayWeights(stored: storedWeights),
      asOf: fetchedAt, now: now)
  }

  private var summary: String {
    let working = sessions.count { $0.state != .idle }
    let total = sessions.count
    if total == 0 { return "No sessions running" }
    let label = total == 1 ? "1 session" : "\(total) sessions"
    return working == 0 ? "\(label), all idle" : "\(label), \(working) active"
  }
}

/// Close the menu bar panel.
///
/// **SwiftUI offers no way to ask for this.** `MenuBarExtra` takes `isInserted` —
/// whether the item is in the menu bar at all — and nothing for whether its panel is
/// open. Checked against the macOS 26.5 SwiftUI interface: there is no `isPresented`
/// initializer, on any of the overloads. So the panel has to be closed as the window
/// it is.
///
/// The predicate is the one `DockPresence` already leans on, inverted. A real window
/// can become main and this panel cannot, which is what identifies it without naming
/// a private class — and the `canBecomeMain` guard is what makes it safe, because the
/// one thing that must never happen here is closing the main window.
///
/// Why this exists at all: the panel is dismissed by the app resigning active, and
/// when the session's app is *already* frontmost, focusing it changes nothing and
/// nothing resigns. Without this the click is invisible — which is exactly how it
/// was reported.
@MainActor
enum MenuBarPanel {
  static func dismiss() {
    let panel =
      NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && !$0.canBecomeMain }
    guard let panel, !panel.canBecomeMain else { return }
    panel.close()
  }
}

/// A row in the menu bar panel that goes somewhere.
///
/// Two affordances rather than one, because **`pointerStyle(.link)` does not show
/// over a row in this panel** — the cursor stays an arrow, which is how the first
/// clickable rows here shipped looking dead: the only feedback was the `.plain`
/// press flash, after the click. The hover fill is what a menu row is expected to
/// have anyway, and unlike a pointer style it is visible before committing. The
/// pointer stays because it costs nothing where it does work.
///
/// `contentShape` is the other half: `Spacer` does not hit-test, so without it most
/// of a row's width is dead to both the click and the hover.
struct PanelRow<Label: View>: View {
  let help: String
  let action: () -> Void
  @ViewBuilder var label: Label

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      label.contentShape(.rect)
    }
    .buttonStyle(.plain)
    .pointerStyle(.link)
    .help(help)
    .onHover { hovering = $0 }
    .background(
      hovering ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear),
      in: .rect(cornerRadius: 4)
    )
  }
}

/// One session in the popover: a click opens it in the window.
///
/// **This used to focus the session's terminal, and that was the wrong default.**
/// The panel is 320pt of summary; everything it has to leave out — the transcript
/// context, the folder, the model, the rest of the account's sessions — is in the
/// pane behind this row, and sending the one click Armada gets to another
/// application made its own detail view the harder thing to reach. Focusing the
/// host is a right-click away instead, which is where a second intent belongs, and
/// it is the rarer of the two: someone who wants to type at the session was going
/// to switch to their terminal anyway.
///
/// A session with no host still gets a row that does something now, which is the
/// other thing that changed: the destination is Armada's own pane, and that exists
/// whether or not the lookup found an application to raise.
///
/// The panel is dismissed explicitly, always, and **before the window is opened**.
/// `MenuBarExtra(.window)` closes itself when Armada resigns active, and opening one
/// of Armada's own windows is the one destination that never makes it resign — so
/// unlike the old focus click, this one would leave the panel hanging over the
/// window it just opened. The order is load-bearing on top of that: `MenuBarPanel`
/// finds the panel as the key window that cannot become main, and once the main
/// window is key it is the main window that answers, so the dismissal correctly
/// refuses to close anything.
struct SummaryRow: View {
  let session: Session
  let accountID: String
  let host: SessionHost?

  var body: some View {
    PanelRow(help: "Show \(session.displayName) in Armada") {
      MenuBarPanel.dismiss()
      MainWindowRoute.shared.open(.account(accountID), session: session.id)
    } label: {
      HStack(spacing: 6) {
        StateDot(state: session.state)
        Text(session.displayName)
          .font(.caption)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
    }
    // Only when there is somewhere to go: an unconditional `contextMenu` with no
    // buttons in it opens an empty menu on right-click, which is worse than none.
    .modifier(FocusHostMenu(host: host))
  }
}

/// "Focus in Ghostty", on the right-click, when the session has a host to focus.
struct FocusHostMenu: ViewModifier {
  let host: SessionHost?

  func body(content: Content) -> some View {
    if let host {
      content.contextMenu {
        Button("Focus in \(host.name)") {
          FocusSession.focus(host)
          // For the same reason the row itself dismisses: the panel is closed by
          // Armada resigning active, and when the host is *already* frontmost
          // nothing resigns and the click reads as dead.
          MenuBarPanel.dismiss()
        }
      }
    } else {
      content
    }
  }
}

/// One window in the popover: label, figure, bar and reset, on one full-width row.
///
/// **A row per window rather than the two side by side.** Side by side across the
/// 256pt of content the panel had before it was widened, each window got about 110pt
/// — enough for a figure and a 52pt bar and nothing else, which is why the reset kept
/// having to go somewhere odd. Stacked, each window has the full width, the reset
/// sits at the end of its own row where it needs no label to say which window it
/// belongs to, and the bars line up under each other for comparison.
///
/// The fixed label, figure and reset widths are what make that alignment hold: the
/// figure is trailing-aligned so "5%" and "100%" put their last digit in the same
/// place, and the bar is the one flexible thing on the row, so it takes whatever the
/// fixed columns leave and every row's bar starts and ends on the same two points.
///
/// **Everything fixed on the row is sized to its own longest string, and the bar gets
/// the rest.** A bar with a width of its own was how this drifted: 88pt was set when
/// the panel was 256pt wide and never revisited when it grew to 320, which left the
/// widest surface in the app showing the narrowest meter with 60pt of dead air beside
/// it. The figure is the other half of that — at `.callout` it was the largest text
/// in a row of `.caption2`, sized for a pane rather than for a 320pt panel, and
/// reading it never needed that much weight next to the bar it annotates.
struct CompactUsage: View {
  let label: String
  let window: UsageWindow?
  var forecast: UsageForecast?
  let now: Date

  /// Fits "100%" at `.caption` with a point to spare.
  private static let figureWidth: CGFloat = 30

  /// Fits the longest reset this renders — a clock glyph and "in 19h" — with enough
  /// slack that it stays one line rather than truncating. Fixed rather than hugging
  /// its text so a row whose window has no reset leaves the column empty instead of
  /// handing the space to its bar and making that one row's meter longer than the
  /// others.
  private static let resetWidth: CGFloat = 52

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .leading)
      if let window {
        UsageFigure(window: window, now: now, font: .caption)
          .frame(width: Self.figureWidth, alignment: .trailing)
        UsageBar(
          percent: window.utilization, forecast: forecast, height: 5,
          voided: window.hasRolled(asOf: now)
        )
        .frame(maxWidth: .infinity)
        UsageResetLine(window: window, now: now, style: .compact)
          .frame(width: Self.resetWidth, alignment: .trailing)
      } else {
        Text("—")
          .font(.caption.monospacedDigit())
          .frame(width: Self.figureWidth, alignment: .trailing)
        Spacer(minLength: 0)
      }
    }
  }
}
