import SwiftUI

#if DEBUG

  import AppKit
  import SwiftUI

  /// Screenshot mode: the app photographed instead of the app used.
  ///
  /// Everything here is inert unless `-ScreenshotMode YES` is on the command line,
  /// which `appshot capture` passes and nothing else does. Launch arguments land in
  /// `NSArgumentDomain`, so they apply to one launch and a developer's normal runs
  /// are untouched.
  ///
  /// It exists because a screenshot of Armada is otherwise a screenshot of *this
  /// machine*, and Armada is about the worst subject there is for a naive capture:
  /// every row is a live session title somebody typed, every folder is a real
  /// project path, the account names are real organizations, and the transcript
  /// window is a verbatim conversation. None of that may reach a public image.
  ///
  /// **The rule for anything added here: a fact the screen shows must be *fixed*,
  /// never merely *plausible*.** Two runs a week apart have to produce comparable
  /// images, or `make screenshots-check` is decorative. That is why there is one
  /// clock (`now`) and every fixture date is an offset from it, and why the stores
  /// are filled in memory rather than pointed at a folder of fake files: a session
  /// is only listed while its pid is alive, and starting an account spawns the real
  /// `claude` binary.
  ///
  /// **`#if DEBUG` in its entirety**, which is a deliberate divergence from bastion
  /// and cupertino, whose `DemoSeed` compiles into Release and is photographed from
  /// a Release build. Armada has no licence branch and should not grow one — see
  /// `LicenseStore` — and the only thing that keeps a shipped binary from answering
  /// the licence question from a flag is that the flag does not exist in it. The
  /// Debug build also carries its own bundle id, `io.mgcrea.armada.debug`, so
  /// whatever SwiftUI writes to defaults during a capture lands in the debug domain
  /// and never in the real app's. `ScreenshotMode` is the always-compiled half, and
  /// in Release it is the constant `false`.
  ///
  /// **`DemoSeed` never writes.** Not `projects.json`, not `usage-history.json`,
  /// not a `settings.json` hook, not a defaults key. The one exception is the
  /// transcript fixture, written to the process's temporary directory because
  /// `TranscriptWindow` reads a file by URL — a path nothing else ever looks at.
  nonisolated enum DemoSeed {

    // MARK: - Launch arguments

    /// The names `appshot` passes. Changing one means changing the Makefile's
    /// `DEMO_ARGS` in the same commit.
    private enum Key {
      static let mode = "ScreenshotMode"
      static let stage = "ScreenshotStage"
      static let appearance = "ScreenshotAppearance"
      static let readyFile = "ScreenshotReadyFile"
      static let activation = "ScreenshotActivation"
    }

    /// The argument domain only, never `UserDefaults.standard` as a whole: one
    /// `defaults write … ScreenshotMode YES` would otherwise put every later launch
    /// of the debug build into demo mode, and `stage` traps on a missing value.
    private static func argument(_ key: String) -> String? {
      let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      switch arguments[key] {
      case let value as String: return value
      case let value as Bool: return value ? "YES" : "NO"
      case let value as NSNumber: return value.stringValue
      default: return nil
      }
    }

    static var isEnabled: Bool {
      guard let raw = argument(Key.mode)?.lowercased() else { return false }
      return ["yes", "true", "1"].contains(raw)
    }

    /// `none` under `appshot capture --no-activate`, `focused` otherwise. See
    /// `ScreenshotMode.staysInBackground`.
    static var activation: String? { argument(Key.activation) }

    // MARK: - Stages

    /// Which screen this launch is for. The staged driver reaches a screen by
    /// relaunching, so this is read once per process. The raw values are the
    /// `-ScreenshotStage` values and the capture filenames both.
    enum Stage: String, CaseIterable {
      case usage
      case account
      case transcript
      case projects
      case codex
      case menubar

      static var allNames: String { allCases.map(\.rawValue).joined(separator: ", ") }

      /// Where the main window's sidebar starts. Nil for the stage that never opens
      /// the main window.
      var sidebar: SidebarItem? {
        switch self {
        case .usage: .usage
        case .account: .account(Fixture.acme.path)
        case .projects: .projects
        case .codex: .codex(Fixture.codexHome.path)
        // Never built on these stages — see `openStagedWindow()`.
        case .transcript, .menubar: nil
        }
      }

      /// The row the pane opens with selected.
      ///
      /// The account and Codex plates select a session because the detail column
      /// is half the pane: with nothing selected it shows the overview, which is a
      /// list of folder paths and says nothing about what Armada is for.
      var selection: String? {
        switch self {
        case .account: Fixture.billingSessionID
        case .codex: Fixture.codexWorkingID
        case .projects: Fixture.projectBillingID
        case .usage, .transcript, .menubar: nil
        }
      }
    }

    /// Deliberately non-optional, with no fallback to a default screen. A stage that
    /// does not parse must be loud: the silent version is a correctly sized, good
    /// looking capture of the *wrong* screen, filed under the right name.
    static var stage: Stage {
      let raw = argument(Key.stage) ?? ""
      guard let stage = Stage(rawValue: raw) else {
        fatalError("-\(Key.stage) was '\(raw)' — expected one of \(Stage.allNames)")
      }
      return stage
    }

    // MARK: - Entry points

    /// Called from `applicationDidFinishLaunching`, instead of everything real.
    ///
    /// Order matters: the paths are checked before anything could read them, the
    /// appearance, zone and preferences are pinned before any view is built, and
    /// the stores are seeded before the window that reads them opens.
    @MainActor static func apply() {
      refuseRealFolders()
      pinAppearance()
      pinFormatting()
      maskPreferences()
      holdOffAppNap()
      seedStores()
      observeWindows()
    }

    /// The one window this launch opens.
    ///
    /// The transcript plate is the one stage that is not the main window, and the
    /// one most likely to fail silently: appshot photographs the largest ordinary
    /// window, so a main window left on screen is captured instead, at the right
    /// size, showing a real screen. Never opening it is strictly simpler than hiding
    /// it later — hiding it at activation time races appshot's two-step window
    /// lookup, and deadlocks against `--ready-file`, which is waited for *before*
    /// activation.
    @MainActor static func openStagedWindow() {
      switch stage {
      case .transcript:
        TranscriptWindow.shared.show(url: transcriptURL, name: Fixture.billingTitle)
      case .menubar:
        PanelStand.show()
      case .usage, .account, .projects, .codex:
        guard let sidebar = stage.sidebar else { return }
        MainWindowRoute.shared.stageForScreenshot(sidebar, session: stage.selection)
      }
    }

    // MARK: - Isolation

    /// Every fixture folder and working directory must be somewhere that does not
    /// exist on the capturing Mac.
    ///
    /// They all sit under `Fixture.home`, a home directory no Mac has, so this should
    /// never fire. It is here because the failure it prevents is not a bad picture but
    /// a leak: `ContextCompositions` spawns `claude` in any session folder that exists,
    /// and a fixture account folder that exists is somebody's real history.
    private static func refuseRealFolders() {
      let paths =
        [Fixture.personal.path, Fixture.acme.path, Fixture.codexHome.path]
        + Fixture.projects.map(\.path)
      for path in paths where FileManager.default.fileExists(atPath: path) {
        fatalError("screenshot fixture \(path) exists on this Mac — rename it in DemoSeed.Fixture")
      }
    }

    // MARK: - Ambient state

    /// Per launch rather than left to System Settings, which is what makes
    /// `--appearances` mean anything: appshot launches once per appearance and the
    /// *app* decides, not the Mac.
    @MainActor private static func pinAppearance() {
      switch argument(Key.appearance) {
      case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
      case "light": NSApp.appearance = NSAppearance(named: .aqua)
      default: break
      }
    }

    /// The weekly chart's axis is weekday names off `Calendar.current`, and the pace
    /// curve bends at local midnight. A fixed instant is only half of determinism:
    /// the same `now` falls on Tuesday in Paris and Monday in San Francisco, so a
    /// golden accepted here would fail one ocean over in a way that looks like a UI
    /// change. The locale is pinned from the Makefile instead, because `Locale.current`
    /// is read before any of this runs.
    private static func pinFormatting() {
      if let utc = TimeZone(identifier: "UTC") { NSTimeZone.default = utc }
    }

    /// Every preference these screens read, written into the argument domain.
    ///
    /// A flag a capture does not pass does not default to off — it falls back to
    /// whatever the capturing Mac has persisted, and the debug build's domain is the
    /// developer's own. The argument domain outranks the persisted one, so the
    /// persisted values are masked without being touched, and a flag actually passed
    /// on the command line still wins.
    ///
    /// Each value is the same expression its `@AppStorage` initializer uses, so a
    /// default changed in code changes here with it. **Add a key here in the commit
    /// that adds an `@AppStorage` these panes draw from**, or the plates start
    /// depending on the capturing Mac again.
    ///
    /// The two selections are here too, and they are the stage: `SidebarItem` and
    /// the Projects selection are `@AppStorage`, and writing them the way
    /// `MainWindowRoute.open` does would both persist them and lose to anything
    /// already sitting in this domain.
    @MainActor private static func maskPreferences() {
      var preferences: [String: Any] = [
        SidebarItem.defaultsKey: stage.sidebar?.stored ?? "",
        "armada.selectedProject": Fixture.projectBillingID,
        DayWeights.defaultsKey: DayWeights.evenStored,
        WorkingHours.defaultsKey: WorkingHours.flatStored,
        PanelVisibility.defaultsKey: "",
        SessionSort.defaultsKey: SessionSort.fallback.stored,
        SessionGrouping.defaultsKey: SessionGrouping.fallback.stored,
        StatsWindow.defaultsKey: StatsWindow.week.rawValue,
        TranscriptStyle.defaultsKey: TranscriptStyle.fallback.stored,
        "armada.transcriptFollow": true,
        MenuBarHalo.defaultsKey: MenuBarHalo.working.rawValue,
        MenuBarLimit.defaultsKey: "",
        VoiceController.enabledKey: false,
        MCPServerController.enabledKey: false,
        MessageDelivery.enabledKey: false,
        VSCodeLaunch.defaultsKey: false,
        HandoverTarget.copyOnlyDefaultsKey: false,
        TerminalApp.defaultsKey: "",
        // The consent card sits above the split view until it is answered, on every
        // plate. The updater itself never starts in a capture.
        UpdateController.choiceMade: true,
      ]
      let defaults = UserDefaults.standard
      let passed = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      preferences.merge(passed) { _, fromCommandLine in fromCommandLine }
      defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    }

    /// A backgrounded, occluded app is throttled, and a throttled app still draws —
    /// eventually. Under `--no-activate` the failure is not a blank window but a frame
    /// poll settling on a half-drawn one, which is still, plausible and wrong.
    @MainActor private static var activity: NSObjectProtocol?

    @MainActor private static func holdOffAppNap() {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Screenshot capture")
    }

    // MARK: - The clock

    /// The instant every plate is drawn at: Tuesday 2026-09-15, 14:41 UTC.
    ///
    /// A Tuesday afternoon so the weekly chart has a working week behind it and the
    /// rest ahead; 14:41 so nothing lands on an hour boundary, where "in 1 hour" and
    /// "in 59 minutes" are a coin flip away from each other. Every fixture date below
    /// is an offset from this, and `AppClock` hands it to every view.
    ///
    /// **Pick offsets away from the unit boundaries the views round at.** `ago(38)`
    /// always reads "38 minutes ago"; `ago(60)` is "1 hour ago" or "60 minutes ago"
    /// depending on which formatter drew it. Bumping this instant re-accepts every
    /// golden, deliberately.
    static let now: Date = {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      // A literal, so this cannot fail; a crash beats a silent `Date()`.
      return calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 14, minute: 41))!
    }()

    private static func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private static func ahead(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    /// Milliseconds, the unit `SessionRegistry.startedAt` is written in.
    private static func millis(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    // MARK: - Identity

    /// The version the plates claim. Pinned rather than read, so a release does not
    /// churn every golden, and so the Debug build's `-dev` suffix never shows. Bump it
    /// deliberately, in the commit that re-captures.
    static let version = "1.7.0"

    /// A licence that is rendered and never verified — `EntitlementMonitor` is handed
    /// it directly. Its email is the RFC 2606 reserved domain.
    static let license = License(
      id: "lic_demo", email: "you@example.com", major: 1, issuedAt: "2026-08-04")

    // MARK: - Fixtures

    /// Every name, path and title the plates show.
    ///
    /// `acme` is the universal fiction marker, and every folder here is checked
    /// absent by `refuseRealFolders()` before anything runs.
    enum Fixture {
      /// A home directory nobody has, and never the real one.
      ///
      /// The real home was tried first, on the theory that every path is drawn through
      /// `abbreviatingWithTildeInPath` and would read `~/Projects/acme/api` on any Mac.
      /// Not every path is: the Codex detail's Folder row and the transcript's tool
      /// calls print a path raw, and the first capture put the developer's own user name
      /// on two plates. A fixed fictional home costs the tilde and makes every path
      /// identical on every machine, which the gate needs anyway.
      private static let home = URL(filePath: "/Users/you", directoryHint: .isDirectory)

      private static func folder(_ name: String) -> ClaudeConfigFolder {
        let base = home.appending(path: name, directoryHint: .isDirectory)
        return ClaudeConfigFolder(
          base: base, usageJSON: base.appending(path: ".claude.json", directoryHint: .notDirectory))
      }

      /// `.notDirectory` so the path carries no trailing slash, which is the form
      /// `ProjectPath` normalizes a session's cwd to before matching it to a project.
      static func project(_ relative: String) -> String {
        home.appending(path: "Projects/\(relative)", directoryHint: .notDirectory)
          .path(percentEncoded: false)
      }

      /// Two organizations on one person, which is the case Armada exists for: the
      /// two carry entirely separate limits, and neither number means anything added
      /// to the other.
      static let personal = folder(".claude-personal")
      static let acme = folder(".claude-acme")
      static let codexHome = CodexHome(
        base: home.appending(path: ".codex-acme", directoryHint: .isDirectory))

      static let billingSessionID = "7c1e4a52-9b0d-4f3e-8a61-2d5c9e0b7f14"
      static let billingTitle = "Migrate billing webhooks to Stripe v2 events"
      static let codexWorkingID = "0199a3f2-6c1d-7e40-b8a5-4d2f91c0e6a7"
      static let projectBillingID = "B1A7C0DE-0000-4000-8000-000000000001"

      static let billingService = project("acme/billing-service")
      static let storefront = project("acme/storefront")
      static let api = project("acme/api")
      static let infra = project("acme/infra")
      static let harbor = project("harbor")
      static let ledger = project("ledger-cli")

      static var projects: [Project] {
        [
          Project(
            id: projectBillingID, path: billingService, name: nil,
            agent: .claude(accountID: acme.path), addedAt: ago(minutes: 21 * 24 * 60)),
          Project(
            id: "B1A7C0DE-0000-4000-8000-000000000002", path: storefront, name: nil,
            agent: .claude(accountID: acme.path), addedAt: ago(minutes: 20 * 24 * 60)),
          Project(
            id: "B1A7C0DE-0000-4000-8000-000000000003", path: api, name: "acme-api",
            agent: .claude(accountID: acme.path), addedAt: ago(minutes: 19 * 24 * 60)),
          Project(
            id: "B1A7C0DE-0000-4000-8000-000000000004", path: harbor, name: nil,
            agent: .claude(accountID: personal.path), addedAt: ago(minutes: 12 * 24 * 60)),
          Project(
            id: "B1A7C0DE-0000-4000-8000-000000000005", path: ledger, name: nil,
            agent: .codex(homeID: codexHome.path), addedAt: ago(minutes: 9 * 24 * 60)),
        ]
      }
    }

    // MARK: - Seeding

    @MainActor private static func seedStores() {
      EntitlementMonitor.shared.demoInstall(.licensed(license))

      let personal = Account(folder: Fixture.personal)
      personal.demoInstall(
        identity: identity(
          organization: "you@example.com's Organization", type: "claude_max",
          tier: "default_claude_max_20x"),
        usage: UsageSnapshot(
          fiveHour: UsageWindow(utilization: 34, resetsAt: ahead(minutes: 2 * 60 + 19)),
          sevenDay: UsageWindow(utilization: 58, resetsAt: personalWeekEnd),
          // All three windows, the way the cache carries them once it carries any: the
          // card draws its rows from `limits` when it is non-empty, and the first
          // capture, with only the Opus entry here, lost the session and weekly rows.
          limits: [
            UsageLimit(
              kind: "five_hour", group: "session", percent: 34,
              resetsAt: ahead(minutes: 2 * 60 + 19), severity: nil, isActive: false,
              scopeModelName: nil),
            UsageLimit(
              kind: "seven_day", group: "weekly", percent: 58, resetsAt: personalWeekEnd,
              severity: nil, isActive: false, scopeModelName: nil),
            UsageLimit(
              kind: "seven_day_opus", group: "weekly", percent: 41, resetsAt: personalWeekEnd,
              severity: nil, isActive: false, scopeModelName: "Opus"),
          ],
          fetchedAt: ago(minutes: 2), source: .live),
        modelID: "claude-opus-5-5",
        recentProjects: [
          RecentProject(path: Fixture.harbor, lastStartedAt: ago(minutes: 47)),
          RecentProject(path: Fixture.ledger, lastStartedAt: ago(minutes: 26 * 60 + 10)),
        ])
      personal.sessions.demoInstall(personalSessions)

      let acme = Account(folder: Fixture.acme)
      acme.demoInstall(
        identity: identity(organization: "Acme Corp", type: "claude_team", tier: nil),
        usage: UsageSnapshot(
          // The one window a forecast has something to say about: 71% with the reset
          // most of an hour away is the "at this rate, 100% in …" line in orange.
          fiveHour: UsageWindow(utilization: 71, resetsAt: ahead(minutes: 48)),
          sevenDay: UsageWindow(utilization: 44, resetsAt: acmeWeekEnd),
          limits: [],
          fetchedAt: ago(minutes: 1), source: .live),
        modelID: "claude-opus-5-5",
        recentProjects: [
          RecentProject(path: Fixture.billingService, lastStartedAt: ago(minutes: 112)),
          RecentProject(path: Fixture.storefront, lastStartedAt: ago(minutes: 38)),
          RecentProject(path: Fixture.api, lastStartedAt: ago(minutes: 192)),
          RecentProject(path: Fixture.infra, lastStartedAt: ago(minutes: 340)),
        ])
      acme.sessions.demoInstall(acmeSessions)

      Accounts.shared.demoInstall([personal, acme])
      UsageHistory.shared.demoInstall([
        personal.id: history(
          start: personalWeekEnd.addingTimeInterval(-week), final: 58, pace: 0.9),
        acme.id: history(start: acmeWeekEnd.addingTimeInterval(-week), final: 44, pace: 1.1),
      ])

      let codex = CodexAccount(home: Fixture.codexHome)
      codex.sessions.demoInstall(
        codexSessions,
        rateLimits: CodexRateLimits(
          primary: CodexWindow(
            usage: UsageWindow(utilization: 18, resetsAt: ahead(minutes: 3 * 60 + 5)),
            minutes: 300),
          secondary: CodexWindow(
            usage: UsageWindow(
              utilization: 36, resetsAt: ahead(minutes: 3 * 24 * 60 + 15 * 60 + 19)),
            minutes: 10080),
          planType: "pro",
          observedAt: ago(minutes: 6)))
      CodexAccounts.shared.demoInstall([codex])

      ProjectStore.shared.demoInstall(Fixture.projects)
      UsageIndex.shared.demoInstall(ledger)

      writeTranscript()
    }

    private static let week: TimeInterval = 7 * 24 * 60 * 60

    /// Friday 09:00 and Sunday 17:00: two weekly windows that do not line up, which
    /// is what the two organizations' limits actually do.
    private static let personalWeekEnd = ahead(minutes: (2 * 24 + 18) * 60 + 19)
    private static let acmeWeekEnd = ahead(minutes: (5 * 24 + 2) * 60 + 19)

    private static func identity(organization: String, type: String, tier: String?)
      -> AccountIdentity?
    {
      var oauth: [String: Any] = [
        "organizationName": organization,
        "organizationType": type,
        "emailAddress": "you@example.com",
      ]
      if let tier { oauth["organizationRateLimitTier"] = tier }
      return AccountIdentity(root: ["oauthAccount": oauth])
    }

    /// One reading every 20 minutes from the window's start to the last fetch.
    ///
    /// Shaped like a working week rather than a ramp: the weekly figure climbs only
    /// between 09:00 and 19:00 UTC on weekdays, which is what gives the chart its
    /// steps and the pace curve something to be ahead of or behind. `pace` bends the
    /// climb so the two accounts do not draw the same line.
    private static func history(start: Date, final: Int, pace: Double) -> [UsageSample] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      let end = ago(minutes: 2)
      let step: TimeInterval = 20 * 60
      var stamps: [Date] = []
      var cursor = start.addingTimeInterval(step)
      while cursor <= end {
        stamps.append(cursor)
        cursor = cursor.addingTimeInterval(step)
      }
      func working(_ date: Date) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        let weekday = parts.weekday ?? 1
        let hour = parts.hour ?? 0
        return (2...6).contains(weekday) && (9..<19).contains(hour)
      }
      let workingCount = max(1, stamps.count(where: working))
      var seen = 0
      return stamps.map { stamp in
        if working(stamp) { seen += 1 }
        let progress = pow(Double(seen) / Double(workingCount), pace)
        let weekly = Int((Double(final) * progress).rounded())
        // The session window resets every five hours; a sawtooth that restarts on
        // the same grid, peaking lower on quiet hours.
        let minutesIn = Int(stamp.timeIntervalSince(start) / 60) % 300
        let session = working(stamp) ? min(95, minutesIn * 70 / 300 + 4) : 0
        return UsageSample(t: stamp, h: session, w: weekly)
      }
    }

    // MARK: - Claude sessions

    /// Every state the list can draw, once: working, running a tool, waiting for
    /// permission, and two idle — one with a warm prompt cache about to go cold,
    /// which is the timer badge the row exists to show.
    @MainActor private static var acmeSessions: [Session] {
      [
        session(
          id: Fixture.billingSessionID, cwd: Fixture.billingService, pid: 48213,
          started: ago(minutes: 112), status: "busy", title: Fixture.billingTitle,
          context: 118_400, contextAt: ago(minutes: 0.5), state: .working,
          compaction: Compaction(
            trigger: "auto", preTokens: 161_200, postTokens: 38_900, at: ago(minutes: 71))),
        session(
          id: "3f9b2d71-0c4e-4a8b-9e25-6d1a7c3b5e08", cwd: Fixture.storefront, pid: 48877,
          started: ago(minutes: 38), status: "busy", title: "Fix flaky checkout e2e test on Safari",
          context: 64_300, contextAt: ago(minutes: 1.5), state: .runningTool),
        session(
          id: "a4c8e1f0-5b2d-4c7a-8f39-0e6d2b9a1c53", cwd: Fixture.api, pid: 47102,
          started: ago(minutes: 192), status: "waiting",
          waitingFor: "permission to run: pnpm prisma migrate deploy",
          title: "Add rate limiting to /v1/search", context: 91_700, contextAt: ago(minutes: 4),
          state: .waiting),
        session(
          id: "e2d7b5a9-1f3c-4e6b-a0d8-7c4f2b1e9a36", cwd: Fixture.infra, pid: 45530,
          started: ago(minutes: 340), status: "idle", title: "Upgrade Postgres 16 → 17 in staging",
          context: 142_900, contextAt: ago(minutes: 53), state: .idle, ttl: .oneHour),
        session(
          id: "5b0e9c3d-7a2f-4d81-9c6e-3f8a1d2b7e40", cwd: Fixture.billingService, pid: 44218,
          started: ago(minutes: 26 * 60 + 22), status: "idle",
          title: "Draft the Q3 incident review", context: 37_200, contextAt: ago(minutes: 19 * 60),
          state: .idle, ttl: .fiveMinutes),
      ]
    }

    @MainActor private static var personalSessions: [Session] {
      [
        session(
          id: "c6a1f8e3-2d9b-4b5c-8e07-1a3f6d9c2b58", cwd: Fixture.harbor, pid: 49011,
          started: ago(minutes: 47), status: "busy", title: "Offline sync for the iOS app",
          context: 55_800, contextAt: ago(minutes: 0.7), state: .working),
        session(
          id: "9d4b2e7a-6c1f-4a3d-b8e5-0f7c9a2d4e61", cwd: Fixture.ledger, pid: 43790,
          started: ago(minutes: 26 * 60 + 10), status: "idle",
          title: "Refactor the ledger-cli CSV parser", context: 22_400,
          contextAt: ago(minutes: 22 * 60), state: .idle, ttl: .fiveMinutes),
      ]
    }

    @MainActor private static func session(
      id: String, cwd: String, pid: Int32, started: Date, status: String,
      waitingFor: String? = nil, title: String, context total: Int, contextAt: Date,
      state: SessionState, ttl: PromptCacheTTL? = .oneHour, compaction: Compaction? = nil
    ) -> Session {
      var fields: [String: Any] = [
        "pid": pid, "sessionId": id, "cwd": cwd, "startedAt": millis(started),
        "version": "2.1.270", "entrypoint": "cli", "status": status,
        "statusUpdatedAt": millis(contextAt),
      ]
      if let waitingFor { fields["waitingFor"] = waitingFor }
      // Decoded rather than built, because `SessionRegistry` is a `Decodable` mirror
      // of Claude Code's own file and has no other initializer. A fixture that does
      // not decode is a fixture out of step with the format, and should be loud.
      let data = try! JSONSerialization.data(withJSONObject: fields)
      let registry = try! JSONDecoder().decode(SessionRegistry.self, from: data)

      let session = Session(registry: registry)
      session.title = title
      session.state = state
      session.lastWrite = contextAt
      session.sessionModelID = "claude-opus-5-5"
      session.cacheTTL = ttl
      // A realistic split rather than all of it in one bucket: nearly everything in a
      // long session is read from the prompt cache, which is the point of the cache
      // line under the bar.
      session.context = ContextReading(
        total: total, cacheRead: total * 88 / 100, cacheCreation: total * 9 / 100,
        freshInput: total * 3 / 100, output: 2_140, modelID: "claude-opus-5-5", at: contextAt,
        cacheTTL: ttl)
      session.baseline = ContextBaseline(loadedAtStart: 18_600)
      session.compaction = compaction
      if id == Fixture.billingSessionID {
        session.transcript = transcriptURL
      }
      return session
    }

    // MARK: - Codex

    @MainActor private static var codexSessions: [CodexSession] {
      [
        codexSession(
          id: Fixture.codexWorkingID, cwd: Fixture.ledger, started: ago(minutes: 29),
          title: "Port the importer to async streams", state: .working, last: ago(minutes: 0.4),
          tokens: 412_600, context: 71_300),
        codexSession(
          id: "0199a2b8-3e5f-7c12-9a04-6b8d1e3f5c29", cwd: Fixture.api, started: ago(minutes: 96),
          title: "Review the search rate limiter", state: .awaitingInput, last: ago(minutes: 7),
          tokens: 188_900, context: 48_200),
        codexSession(
          id: "01999f41-8a2c-7b63-a5e1-2c9f4d7b0e18", cwd: Fixture.storefront,
          started: ago(minutes: 5 * 60 + 12), title: "Write tests for the cart reducer",
          state: .ended, last: ago(minutes: 4 * 60 + 3), tokens: 903_100, context: 112_700),
      ]
    }

    @MainActor private static func codexSession(
      id: String, cwd: String, started: Date, title: String, state: CodexSessionState,
      last: Date, tokens: Int, context total: Int
    ) -> CodexSession {
      let session = CodexSession(
        id: id,
        meta: CodexSessionMeta(
          sessionId: id, cwd: cwd, startedAt: started, originator: "codex_cli_rs",
          cliVersion: "0.61.0", threadSource: "user", parentThreadId: nil, model: "gpt-5.2-codex"),
        // Never read: the watcher that would tail it is never started.
        rollout: URL(filePath: "/dev/null"))
      session.title = title
      session.state = state
      session.lastEventAt = last
      session.totalTokens = tokens
      session.contextLimit = 272_000
      session.context = ContextReading(
        total: total, cacheRead: total * 82 / 100, cacheCreation: 0,
        freshInput: total * 18 / 100, output: 3_310, modelID: "gpt-5.2-codex", at: last)
      return session
    }

    // MARK: - The usage ledger

    /// Thirty days of tokens per project, for the Projects pane.
    ///
    /// Weekdays only, and heavier on the project the plate selects, so the week's
    /// bar is visibly the busiest. The numbers are chosen, not measured — a day's
    /// figure is a product of the day and the project, so the plate is identical on
    /// every run.
    private static var ledger: UsageLedgerSnapshot {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      let today = LocalDay.key(now, calendar: calendar)
      let weights:
        [(cwd: String, account: String, vendor: UsageVendor, model: String, scale: Int)] =
          [
            (Fixture.billingService, Fixture.acme.path, .claude, "claude-opus-5-5", 9),
            (Fixture.storefront, Fixture.acme.path, .claude, "claude-sonnet-5", 6),
            (Fixture.api, Fixture.acme.path, .claude, "claude-opus-5-5", 5),
            (Fixture.harbor, Fixture.personal.path, .claude, "claude-opus-5-5", 4),
            (Fixture.ledger, Fixture.codexHome.path, .codex, "gpt-5.2-codex", 3),
          ]
      var rows: [UsageRow] = []
      var sessions: [UsageSessionRow] = []
      for offset in 0..<30 {
        let day = LocalDay.adding(-offset, to: today, calendar: calendar)
        guard let date = LocalDay.date(day, calendar: calendar),
          !calendar.isDateInWeekend(date)
        else { continue }
        for (index, entry) in weights.enumerated() {
          // 1…5, varying by day and project without any randomness.
          let swing = (offset * 7 + index * 3) % 5 + 1
          let fresh = entry.scale * swing * 41_000
          rows.append(
            UsageRow(
              day: day, cwd: entry.cwd, account: entry.account, vendor: entry.vendor,
              model: entry.model,
              tokens: TokenTally(
                fresh: fresh / 10, cacheWrite: fresh / 4, cacheRead: fresh * 6,
                output: fresh / 20, reasoning: entry.vendor == .codex ? fresh / 30 : 0)))
          let first = date.addingTimeInterval(TimeInterval((9 + index) * 3600))
          sessions.append(
            UsageSessionRow(
              account: entry.account, vendor: entry.vendor,
              sessionID: String(format: "demo-%02d-%d", offset, index), cwd: entry.cwd,
              firstAt: first, lastAt: first.addingTimeInterval(TimeInterval(swing * 1800)),
              isChild: false))
        }
      }
      let earliest = LocalDay.adding(-29, to: today, calendar: calendar)
      return UsageLedgerSnapshot(
        generation: 1, rows: rows, sessions: sessions, earliestDay: earliest, firstPassDone: true)
    }

    // MARK: - The transcript

    /// Where the transcript fixture is written. The temporary directory, because
    /// `TranscriptWindow` reads a file by URL and nothing else in the app looks here.
    static var transcriptURL: URL {
      URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        .appending(path: "armada-screenshot-\(Fixture.billingSessionID).jsonl")
    }

    /// The billing session's conversation, in Claude Code's own line format.
    ///
    /// Every kind of entry the window draws — a prompt, thinking, prose, three tool
    /// calls with their results — so the Thinking and Tools filters in the footer
    /// both have something to hide. The timestamps are literal ISO strings, which
    /// the window prints as `HH:mm:ss` straight out of the text with no time-zone
    /// conversion, so they need no clock at all.
    private static func writeTranscript() {
      func line(_ type: String, _ at: String, _ content: Any, uuid: String) -> [String: Any] {
        [
          "type": type, "uuid": uuid, "timestamp": "2026-09-15T\(at).000Z",
          "sessionId": Fixture.billingSessionID, "cwd": Fixture.billingService,
          "message": ["role": type, "model": "claude-opus-5-5", "content": content],
        ]
      }
      func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
      func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
      }
      func result(_ id: String, _ value: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": value]
      }

      let lines: [[String: Any]] = [
        line(
          "user", "14:02:11",
          "Stripe is retiring the v1 webhook payloads for invoice.* at the end of the quarter. Move billing-service onto the v2 thin events, keep the old handler behind a flag until we cut over, and make sure the idempotency keys still line up.",
          uuid: "u1"),
        line(
          "assistant", "14:02:19",
          [
            [
              "type": "thinking",
              "thinking":
                "v2 thin events carry only the object id, so every handler that reads fields off the payload has to fetch the invoice first. Start from the router to see how many handlers that is.",
            ]
          ], uuid: "a1"),
        line(
          "assistant", "14:02:24",
          [
            text(
              "I'll start from the webhook router to see which handlers read the payload directly."),
            tool("t1", "Read", ["file_path": Fixture.billingService + "/src/webhooks/router.ts"]),
          ], uuid: "a2"),
        line(
          "user", "14:02:25",
          [
            result(
              "t1",
              "export const handlers = {\n  'invoice.paid': onInvoicePaid,\n  'invoice.payment_failed': onPaymentFailed,\n  'invoice.finalized': onInvoiceFinalized,\n  …"
            )
          ],
          uuid: "u2"),
        line(
          "assistant", "14:03:02",
          [
            text(
              "Three handlers read `event.data.object` directly. With thin events that field is gone, so each one needs to retrieve the invoice before it does anything. I'll add a `resolveEvent` step in front of them rather than changing each handler."
            ),
            tool(
              "t2", "Edit", ["file_path": Fixture.billingService + "/src/webhooks/v2/resolve.ts"]),
          ], uuid: "a3"),
        line(
          "user", "14:03:04", [result("t2", "Created src/webhooks/v2/resolve.ts (48 lines)")],
          uuid: "u3"),
        line(
          "assistant", "14:21:47",
          [
            text(
              "Handlers are routed through the resolver now, with `STRIPE_V2_EVENTS` choosing the path. Running the suite."
            ),
            tool("t3", "Bash", ["command": "pnpm test --filter billing-service webhooks"]),
          ], uuid: "a4"),
        line(
          "user", "14:23:30",
          [
            result(
              "t3",
              "✓ webhooks/v1 (18)\n✓ webhooks/v2 (24)\n✓ idempotency (6)\n\nTest Files  3 passed (3)\n     Tests  48 passed (48)"
            )
          ],
          uuid: "u4"),
        line(
          "assistant", "14:23:41",
          [
            text(
              "All 48 pass, including the six idempotency cases: the v2 path derives its key from the event id exactly as v1 did, so a retried delivery is still recognised as a duplicate. The old handler stays behind the flag. Next I'll add the dashboard endpoint registration so the v2 destination exists before you flip it."
            )
          ], uuid: "a5"),
      ]
      let data = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        .reduce(into: Data()) {
          $0.append($1)
          $0.append(0x0A)
        }
      try? data.write(to: transcriptURL, options: .atomic)
    }

    // MARK: - Windows

    /// The size each plate is composed from, keyed by `HostedWindow`'s autosave name.
    ///
    /// The size the window is **born** with. Resizing after `show()` does not
    /// survive — SwiftUI sizes a `NavigationSplitView` window from its content on a
    /// layout pass that lands after `show()` returns — so `HostedWindow` asks this
    /// at construction instead of its own `contentSize`.
    ///
    /// 16:10, because that is the shape every consumer wants: the website's frame,
    /// the compositor's canvas, a README. Tune against the fixtures, not the numbers:
    /// the account plate's session list is the tallest thing here, and the Projects
    /// plate must not have a lake of empty under it.
    static func contentSize(for autosaveName: String) -> NSSize? {
      switch autosaveName {
      case "main": NSSize(width: 1200, height: 750)
      case "transcript": NSSize(width: 880, height: 640)
      default: nil
      }
    }

    /// Clear the first responder on every window that becomes key.
    ///
    /// Not cosmetic. A `List(selection:)` draws its selected row in the accent
    /// colour while it is first responder and muted grey when it is not, and nothing
    /// assigns that focus deliberately, so it is whatever AppKit resolved by the time
    /// the shutter fired — a gate that fails about one run in three with no code
    /// change. One runloop hop later, so SwiftUI's own assignment does not overwrite
    /// it. `didBecomeKey`, never `didUpdate`, which fires continuously and dies by
    /// recursion the moment anything orders a window from inside it.
    @MainActor private static func observeWindows() {
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { note in
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated {
          guard !window.isSheet else { return }
          DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
      }
    }

    // MARK: - The menu bar panel

    /// The menu bar panel's own view, in a window appshot can photograph.
    ///
    /// The real panel is a `MenuBarExtra` window at status-bar level, opened by a
    /// click on the status item. appshot photographs the largest *normal* window and
    /// cannot see it, and a `--no-activate` run could not click the item anyway. So
    /// this is `StatusMenu` itself — the same view, the same stores, every row the
    /// real panel draws — hosted in a borderless window shaped like the panel.
    ///
    /// **Opaque, on purpose, where the real panel is glass.** Any material that blurs
    /// what is behind the window (Liquid Glass, an `NSVisualEffectView` blending behind
    /// the window) would put whatever sits under it on the capturing Mac into the
    /// picture: somebody's desktop, somebody's mail. That is a leak before it is a
    /// flaky golden. The window background colour is what the panel reads as in dark
    /// mode at a glance, and the rounded corners stay transparent, which is what the
    /// compositor lays over its gradient.
    ///
    /// No traffic lights, so the config marks this screen `"chrome": "none"` and
    /// `--recolor-traffic-lights` skips it rather than failing it.
    @MainActor enum PanelStand {
      private static var window: NSWindow?

      /// The real panel's corner radius on macOS 26, measured by eye against a capture
      /// of it rather than read from anywhere. Change it with the plate in front of you.
      private static let cornerRadius: CGFloat = 14

      static func show() {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let hosting = NSHostingController(
          rootView: StatusMenu()
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.1)))
            .clipShape(shape)
            .screenshotSubject()
            .task { signalReady(from: .menubar) })
        hosting.sizingOptions = [.preferredContentSize]

        let created = NSWindow(contentViewController: hosting)
        created.styleMask = [.borderless]
        created.isOpaque = false
        created.backgroundColor = .clear
        // appshot captures the window's own pixels; a shadow would only be cropped or,
        // worse, not, and the compositor draws its own.
        created.hasShadow = false
        created.isReleasedWhenClosed = false
        created.setContentSize(hosting.view.fittingSize)
        created.center()
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: a borderless window
        // cannot become key, and ordering is within the app — it takes no focus.
        created.orderFrontRegardless()
        window = created
      }
    }

    // MARK: - Readiness

    /// Which view is allowed to say its screen is ready.
    ///
    /// Both the main window and the transcript window report, and only the one this
    /// stage is aimed at is honoured — so the moment anything opens both, whichever
    /// rendered first cannot report a screen the shutter is not pointed at.
    enum ReadySource {
      case main
      case transcript
      case menubar
    }

    /// Tell appshot the screen it asked for has rendered.
    ///
    /// The frame poll sees stillness, not readiness — an empty list and a pane still
    /// loading are both perfectly still. Every store is seeded synchronously in
    /// `apply()` before any window is built, so for the main window the body running
    /// *is* the content existing. The transcript is the one async screen: it reads
    /// its file on a detached task, and reports only once the entries have landed.
    @MainActor static func signalReady(from source: ReadySource) {
      let expected: ReadySource =
        switch stage {
        case .transcript: .transcript
        case .menubar: .menubar
        case .usage, .account, .projects, .codex: .main
        }
      guard isEnabled, source == expected else { return }
      guard let path = argument(Key.readyFile) else { return }
      // One runloop turn after the body, so the frame this reports has been
      // committed rather than merely queued.
      DispatchQueue.main.async {
        FileManager.default.createFile(atPath: path, contents: nil)
      }
    }
  }

#endif

extension View {
  /// Marks the root of a window a capture may photograph.
  ///
  /// Forces `controlActiveState` to `.key`, which is what a `--no-activate` capture
  /// needs: SwiftUI dims every control, label and selection off it, and an app that
  /// is never brought forward is never key. A no-op in a focused capture, so it is
  /// applied unconditionally under the demo flag rather than kept in step with a
  /// second switch. Outside a capture, and in every Release build, it does nothing.
  @ViewBuilder func screenshotSubject() -> some View {
    if ScreenshotMode.isEnabled {
      environment(\.controlActiveState, .key)
    } else {
      self
    }
  }
}
