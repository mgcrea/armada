import SwiftUI

/// What changed, in the build you are running.
///
/// Generated from the repository's `CHANGELOG.md` by `make changelog`: a copy
/// nobody regenerates is a copy that rots, and here it would rot into the worst
/// possible shape — release notes that confidently describe a different build.
///
/// **Why generated rather than bundled.** The obvious alternative is to ship
/// `CHANGELOG.md` as a resource and parse it at launch. Baking the text in at
/// generation time means the parse happens once, in Node, where
/// `make changelog-check` can assert the result, rather than on every launch
/// where nothing can — and it keeps a markdown parser out of an app that
/// deliberately carries no dependency it does not need.
///
/// Every string below is **raw markdown**. The generator does not decide what
/// bold looks like; `markdown(_:_:)` renders it.
///
/// The list is capped — see `SHOWN` in `scripts/generate-changelog.mjs` —
/// because this is the pane you open after updating, not an archive. The full
/// history is a link away, and `CHANGELOG.md` remains the source of truth.
///
/// Cupertino's file, copied: the three direct-distribution apps share no package.
///
/// `nonisolated`, because `SettingsPane.badge` reads `hasUnseen`, and that requirement
/// belongs to SupportKit's `Sendable` protocol, which gives it no actor to run on. Nothing
/// here needs one: the members are constants, `UserDefaults` and the bundle.
nonisolated enum Changelog {
  /// One released version.
  struct Release: Identifiable, Hashable {
    /// `"1.0.0"`. Compared against the marketing version and the seen key.
    let version: String
    /// `"2026-09-14"`. Kept as the ISO string the CHANGELOG wrote rather than a
    /// `Date` literal: a `Date(timeIntervalSince1970:)` in a generated file is
    /// unreadable in a diff, and formatting at generation time would bake the
    /// generating machine's locale into every build.
    let date: String
    let sections: [Section]

    var id: String { version }
  }

  /// One `### Added` / `### Fixed` block.
  ///
  /// `name` is whatever the CHANGELOG wrote, so nothing here is an enum.
  struct Section: Identifiable, Hashable {
    let name: String
    /// The prose that can sit between the heading and the first bullet.
    /// Dropping it silently shortens the notes, which is exactly the kind of
    /// loss nothing would report.
    let lead: [String]
    let entries: [Entry]

    var id: String { name }
  }

  /// One bullet.
  struct Entry: Identifiable, Hashable {
    /// Emitted rather than derived, so `ForEach` has a stable identity without
    /// hashing prose or inventing a `UUID` that changes every render.
    ///
    /// Unique across the whole **release**, not within its section. SwiftUI
    /// flattens the section/entry `ForEach` pair inside a `Form`, so
    /// per-section numbering collides as soon as a release has two sections —
    /// and the pane then draws the first section's bullet a second time in
    /// place of the second section's.
    let ordinal: Int
    /// The leading `**…**`, asterisks removed — or nil. Not every bullet opens
    /// with one, so this is an optional by observation rather than by caution.
    let headline: String?
    /// The rest, one string per paragraph.
    let body: [String]

    var id: Int { ordinal }
  }

  /// Where the full history lives, since only the most recent releases are here.
  static let historyURL = URL(
    string: "https://github.com/mgcrea/armada/blob/main/CHANGELOG.md")!

  // MARK: - Which build this is

  /// The marketing version alone: no build number, no `-dev`.
  ///
  /// Neither `AppInfo.version` nor `AppInfo.shortVersion` will do. The first is
  /// `"1.0.0 (60)"` and the second appends `developmentSuffix` — both correct for
  /// showing a human, and both wrong for comparing against a version string
  /// written in a defaults key, where `"1.0.0-dev"` would never equal anything.
  static var marketingVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }

  /// Whether this build was compiled with `[Unreleased]` still meaning
  /// something. See `unreleased`.
  static var showsUnreleased: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  /// `a` is a later release than `b`, comparing dotted numbers.
  ///
  /// Numeric per component, so `1.10.0` is correctly newer than `1.9.0` — the
  /// comparison a lexicographic one gets backwards. Anything non-numeric compares
  /// as 0, which makes an unparseable version "not newer" rather than a crash.
  static func isVersion(_ a: String, newerThan b: String) -> Bool {
    let left = a.split(separator: ".").map { Int($0) ?? 0 }
    let right = b.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l != r { return l > r }
    }
    return false
  }

  // MARK: - Seen

  /// The last version whose notes were actually read.
  ///
  /// A marketing version string, not a bool: the question the indicator answers
  /// is "did anything ship since you last looked", which needs the comparison.
  static let seenKey = "changelogSeenVersion"

  /// Seed the seen version on a launch that has never set it.
  ///
  /// Without this, a fresh install lights every indicator on first launch — the
  /// key is absent, so everything looks unread, and Armada greets somebody who
  /// has never run it with a stack of "new" releases. The cost is that the
  /// indicator does nothing until the *next* release; the alternative costs every
  /// new user a false badge.
  static func markSeenIfUnset() {
    guard UserDefaults.standard.string(forKey: seenKey) == nil else { return }
    markSeen()
  }

  /// Record that the notes for this build have been read.
  static func markSeen() {
    UserDefaults.standard.set(marketingVersion, forKey: seenKey)
  }

  /// Releases newer than the last one whose notes were read.
  ///
  /// Empty rather than everything when the key is unset — see
  /// `markSeenIfUnset()`.
  static var unseen: [Release] {
    guard let seen = UserDefaults.standard.string(forKey: seenKey), !seen.isEmpty else { return [] }
    return releases.filter { isVersion($0.version, newerThan: seen) }
  }

  /// Whether to draw an indicator anywhere.
  ///
  /// False under a screenshot capture, as in bastion and cupertino: an indicator
  /// is news about *this* install, and a plate that carries one depends on which
  /// release the capturing Mac last read the notes for.
  ///
  /// One of the five screenshot guards, which move together — this one, and in
  /// `HostedWindow` the frame restore, the frame saver and the activation, and the
  /// activation in `DockPresence`. See `fleet-direct-conventions`.
  static var hasUnseen: Bool {
    !ScreenshotMode.isEnabled && !unseen.isEmpty
  }

  // MARK: - Rendering

  /// One markdown string as `Text` can draw it.
  ///
  /// `Text` honours `**bold**`, `_italic_` and links from an `AttributedString`
  /// on its own. It does nothing at all for `` `code` `` — the markdown parser
  /// records that as a semantic `inlinePresentationIntent` and applies no font —
  /// so the loop below is the whole of the missing half.
  ///
  /// The style is a parameter because setting `.font` on a run **overrides** the
  /// view's own `.font()` for that run: a body-sized helper used inside a
  /// caption makes one word jump a size. And the emphasis has to be reapplied,
  /// because headlines here contain code spans inside the bold — assigning a
  /// plain monospaced font would silently un-bold them.
  ///
  /// `Text("**bold**")` renders markdown only for string *literals*, through the
  /// `LocalizedStringKey` overload. Every string here is a variable, which takes
  /// the `StringProtocol` overload and draws the asterisks, so this is not an
  /// embellishment; without it the pane shows raw markdown.
  static func markdown(_ source: String, _ style: Font.TextStyle = .body) -> AttributedString {
    guard
      var text = try? AttributedString(
        markdown: source,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else {
      // Literal asterisks are ugly and honest. Nothing here is worth a crash.
      return AttributedString(source)
    }
    for run in text.runs {
      guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
      var font = Font.system(style, design: .monospaced)
      if intent.contains(.stronglyEmphasized) { font = font.bold() }
      if intent.contains(.emphasized) { font = font.italic() }
      text[run.range].font = font
    }
    return text
  }

  // MARK: - Generated

  // <generated:changelog> generated from CHANGELOG.md by `make changelog` — do not edit by hand

  /// The most recent 5 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = [v1_19_0, v1_18_0, v1_17_0, v1_16_0, v1_15_0]

  // swift-format-ignore
  private static let v1_19_0: Release = Release(
    version: "1.19.0",
    date: "2026-11-28",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "One-click MCP setup for Grok Build.",
            body: [
              "Settings ▸ MCP Server and the MCP toolbar popover list Grok Build, and Configure adds Armada to `~/.grok/config.toml`. Grok Build could already reach Armada through Claude Code's `~/.claude.json`; its own entry takes precedence, so it keeps working whichever Claude account is configured.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "Settings ▸ Supervisor is now Settings ▸ MCP Server.",
            body: [
              "Any agent on your Mac can reach the server, so the pane is named for it: Server, Access (Allow writes and message delivery), Clients, then Supervisor, which starts a Claude Code session attached to the server.",
            ]),
          Entry(
            ordinal: 2,
            headline: "New Session offers the supervisor only while the MCP server runs.",
            body: [
              "With the server off, Claude Code's New Session is a plain button, like Codex's and Grok Build's, instead of a menu holding a greyed-out item.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Agents start sessions in your terminal.",
            body: [
              "A session an agent starts through `armada_start_session` opens in your terminal even when you start your own Claude Code sessions in VS Code. A VS Code launch from an agent never reached the project's window unless Armada was the app in front, and in the terminal the agent gets the session's id. The window opens behind the app you are in, so what you are typing cannot land in its command line and stop the session starting. The \"Send an agent's opening message\" setting is gone with it.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Agents can start a whole room at once.",
            body: [
              "Instead of one session every ten seconds, agents may start up to eight a minute, enough for every seat of a room.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_18_0: Release = Release(
    version: "1.18.0",
    date: "2026-11-28",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Investigation rooms.",
            body: [
              "The MCP server can open a shared log for one investigation, with one seat per provider. Seats post notes and read the others back; a post is not delivered to anyone. A round sends each unfinished seat one fixed sentence telling it to read the room and answer, and Armada notifies you once every seat has posted done.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "Codex quota refusals.",
            body: [
              "When Codex turns down a request because a plan limit was reached, Armada marks the active limit as spent even if the last usage reading still shows room.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Antigravity quota resets.",
            body: [
              "Expired model pools no longer count toward the headline usage figure, and Armada refreshes quotas when a turn ends after a reset.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Usage countdowns.",
            body: [
              "Reset countdowns show days and hours left without rounding up to weeks.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_17_0: Release = Release(
    version: "1.17.0",
    date: "2026-11-27",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Antigravity CLI plan limits.",
            body: [
              "Armada now asks your own `agy` for live 5-hour and weekly quotas across Gemini and Partner models, along with your plan tier, using a session-only `statusLine` probe in an isolated temporary folder without touching your settings or credentials. The limits show in Usage, in the sidebar, above Antigravity sessions, in the menu bar when starred, and over MCP.",
            ]),
          Entry(
            ordinal: 1,
            headline: "One-click MCP setup for Antigravity CLI.",
            body: [
              "Settings ▸ Supervisor and the MCP toolbar popover now list Antigravity CLI alongside Claude Code, ChatGPT & Codex, Cursor and VS Code. Configure writes Armada into `~/.gemini/config/mcp_config.json` with a backup beside it, updates it when the port or token changes, and removes only Armada's entry.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_16_0: Release = Release(
    version: "1.16.0",
    date: "2026-11-27",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Antigravity CLI sessions.",
            body: [
              "Conversations you run with Google's Antigravity CLI (`agy`) now show in the sidebar and the menu bar beside your Claude Code, Codex and Grok Build sessions, each one working, waiting for input or ended, with its folder, model and tokens. A project can start a new `agy` session or resume an earlier one from Projects, and agents see these sessions through the MCP tools: in the fleet, in their transcripts, and when one is started, resumed, focused or closed. Armada reads no Antigravity limits yet, so there is no usage card for it.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "The MCP light pulses once per request.",
            body: [
              "The light on the MCP toolbar button and in the menu bar panel used to pulse for a full minute after each request. With agents calling every minute or two it never stopped, and the animation kept the window redrawing in the background. It now pulses once each time a request is served.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_15_0: Release = Release(
    version: "1.15.0",
    date: "2026-11-25",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Builds in the menu bar.",
            body: [
              "While Build Slots is on and anything is queued, the menu bar icon is followed by a filled dot for each build holding a slot and a ring for each one waiting, running builds first. Past five marks a `+` takes over, and the exact count is in the panel. With the queue empty the icon looks as it always did. VoiceOver reads the counts. Settings ▸ Build Slots ▸ Queue has a \"Show builds in the menu bar\" switch, on by default.",
            ]),
        ]),
    ])

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  // swift-format-ignore
  private static let unreleasedRelease: Release = Release(
    version: "Unreleased",
    date: "",
    sections: [
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "An account that can't report plan limits now says why.",
            body: [
              "A Claude Code account signed in with a long-lived token (`claude setup-token`) gets no plan limits from Claude Code, and Armada used to show \"No usage data yet\" forever. The Usage pane now says the account is signed in with a token, billed by API usage, or signed out, with a Sign In… button that opens `claude auth login` in your terminal for that account. The sidebar and the menu bar show a short note where the meters would be, and an old cached reading is no longer shown for it. `armada_get_usage` reports the reason as `usageUnavailable`.",
            ]),
        ]),
    ])

  // swift-format-ignore
  static let unreleased: Release? = unreleasedRelease
  // </generated:changelog>
}
