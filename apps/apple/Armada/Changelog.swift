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
  static let releases: [Release] = [v1_15_0, v1_14_0, v1_13_0, v1_12_1, v1_12_0]

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

  // swift-format-ignore
  private static let v1_14_0: Release = Release(
    version: "1.14.0",
    date: "2026-11-24",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Build Slots.",
            body: [
              "Settings ▸ Build Slots ▸ Queue builds puts `swift` and `xcodebuild` shims in `~/.local/bin`. From then on, every `swift build`, `swift test` and `xcodebuild` build or test started in a terminal or by an agent, in any repo, waits for one of a set number of slots, two by default. A waiting build says so on its error output and names what it waits behind, so an agent can tell queued from hung. The queue rests on the system's file locks: it keeps working with Armada quit, and a build that dies frees its slot at once. A build started from inside one that holds a slot, such as a test host or a Makefile's own `swift build`, runs straight through, and `ARMADA_BUILDSLOT=off` runs any build unqueued. Xcode's own builds, `xcrun` and `swift run` don't go through the shims and don't queue. Armada never replaces a `swift` or `xcodebuild` in `~/.local/bin` that it did not write, and switching the setting off removes only its own.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Wait on memory.",
            body: [
              "The Memory setting holds a new build back while macOS reports memory pressure, as long as another build is running, so one always runs.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Building and waiting, on the session rows.",
            body: [
              "A session whose build holds a slot says `building` and for how long, on its row, in its details and in the popover; one in the queue says `waiting for a slot`. Settings ▸ Build Slots lists the queue as it stands.",
            ]),
          Entry(
            ordinal: 3,
            headline: "MCP tools: build slots.",
            body: [
              "`armada_get_build_slots` reads the queue: how many slots, the memory rule and the Mac's memory pressure, who holds each slot and who waits, and the session behind each. `armada_get_fleet` and `armada_get_session` give each session's build slot.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_13_0: Release = Release(
    version: "1.13.0",
    date: "2026-11-15",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "MCP tools: message a Codex thread.",
            body: [
              "`armada_send_message` now reaches an open Codex thread as well as a Claude Code session, through Codex's own `codex queue` command (codex-cli 0.163 or later). An idle thread starts a turn on the message at once, a busy one after its turn. Closed threads and Codex subagents are refused, because a queued message would run whenever the thread was next opened. Codex's queue is a fifth place Armada writes into an agent's folders, and the privacy page now lists it.",
            ]),
          Entry(
            ordinal: 1,
            headline: "MCP tools: pick a model.",
            body: [
              "`armada_start_session` takes `model`, the id as the CLI names it (`opus`, `gpt-6-astra`, `grok-4.6`), for a Claude Code, Codex or Grok Build session opened in a terminal.",
            ]),
          Entry(
            ordinal: 2,
            headline: "MCP tools: headless Grok Build turns.",
            body: [
              "With `headless`, `armada_start_session` runs a Grok Build turn as Armada's own process, with no terminal. With nobody there to answer a permission prompt, the turn may do only what your allow rules already permit, and everything else is denied. `armada_send_message` runs the session's next turn once the last has ended, `armada_close_session` stops a running one, and quitting Armada stops any still running.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "Ultra and Max.",
            body: [
              "Anthropic renamed Max 20x to Ultra and Max 5x to Max on 30 October 2026. Accounts on those plans now show the new names.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Codex from ChatGPT 26.1103.",
            body: [
              "ChatGPT moved the Codex CLI it bundles inside its app, so on a Mac with no other copy, Armada could not start a Codex session or add a Codex account. It finds the new location, and still the old one.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_12_1: Release = Release(
    version: "1.12.1",
    date: "2026-11-09",
    sections: [
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Less CPU with a window open.",
            body: [
              "The week's usage chart, in an account's overview and in the Usage pane, was redrawn every second from all of the week's readings, about 5,000 per account, and harder still while sessions were busy. It now draws one reading per quarter hour and redraws once a minute, or as soon as a new reading arrives. With an account window open, Armada went from around 10% CPU to under 5%.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_12_0: Release = Release(
    version: "1.12.0",
    date: "2026-11-04",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Skill usage.",
            body: [
              "Armada counts each Agent Skill and custom command used in Claude Code, whether Claude loaded it or you typed it, per project and account. History goes back as far as the transcripts on this Mac, and the transcript archive when one is set.",
            ]),
          Entry(
            ordinal: 1,
            headline: "A Skills pane.",
            body: [
              "The sidebar's new Skills row lists every skill used in the chosen window, most used first. Select one to see its totals, the projects and accounts that used it, and its last 20 uses, each with what you typed next. Each project's pane lists its own top ten, and clicking a skill there opens it in the Skills pane.",
            ]),
          Entry(
            ordinal: 2,
            headline: "MCP tools:",
            body: [
              "`armada_get_skill_usage` gives an agent the same counts, for every project or one, over 7 days, 30 days or all time.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "No empty 5h row in the menu bar panel.",
            body: [
              "Max 20x stopped reporting a five-hour limit in November 2026, but the panel still showed \"5h —\" under the account, which looked like a missing figure. It now shows only the limits an account reports, as the sidebar and the Usage pane already did.",
            ]),
        ]),
    ])

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
