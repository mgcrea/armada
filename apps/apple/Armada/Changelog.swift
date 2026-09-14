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
  /// DIVERGES from bastion and cupertino, which return false under a screenshot
  /// capture. Armada has no `DemoSeed` and no capture pipeline, so there is
  /// nothing to guard. The day it gets one, this guard arrives in the same change
  /// as the four `HostedWindow`/`DockPresence` guards — see
  /// `fleet-direct-conventions`, "the five guards move together".
  static var hasUnseen: Bool {
    !unseen.isEmpty
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

  /// The most recent 0 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = []

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
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Sessions, per account.",
            body: [
              "Every live Claude Code session with its title, project, age and state, read from each config folder's registry and transcripts. Sortable by what needs you and groupable by project, with a context total per group.",
            ]),
          Entry(
            ordinal: 1,
            headline: "State read rather than inferred.",
            body: [
              "Claude Code's registry carries `status` (`busy` / `waiting` / `idle`) and names what a waiting session wants in `waitingFor`. The older write-recency and unanswered-`tool_use` inference survives only as the fallback for a folder on a build older than 2.1.269.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Context occupancy.",
            body: [
              "How full a session's window is, where it started, the rate it has grown at, a projection, and the last compaction — for both vendors, through one renderer so the two panes cannot drift.",
            ]),
          Entry(
            ordinal: 3,
            headline: "The prefix breakdown behind `/context`.",
            body: [
              "`get_context_usage`, asked of a spawned `claude`. It describes a comparable session rather than the watched one, and the pane says so.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Usage, per account.",
            body: [
              "The 5-hour and 7-day windows with reset times, asked live through the `get_usage` control request and falling back to the cache on disk, with a badge naming which answered and how old it is. Day-weighted pace forecasting, a Usage overview pane, and usage history recorded to disk.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Codex, as a spike.",
            body: [
              "A second sidebar section with its own sessions, plan limits and context, read from `~/.codex` — liveness from the writer locks, limits from `token_count` events in session logs, and a card in the global Usage pane beside the Claude accounts.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Focus.",
            body: [
              "A session row brings forward the application hosting it, resolved by walking the process tree, and raises that session's own window where Accessibility allows.",
            ]),
          Entry(
            ordinal: 7,
            headline: "New sessions.",
            body: [
              "The detail pane with nothing selected is an account overview — the folders that account ran in last, a folder picker, and a tally of what its sessions are doing. Starting one opens a terminal running `claude` or `codex` in that folder on that account: Armada writes a startup script and hands it to Terminal, never owns the process, and the new session arrives through the watchers like any other.",
            ]),
          Entry(
            ordinal: 8,
            headline: "Fork a session.",
            body: [
              "A copy of the session you are looking at, opened from where it stands, on the same account and in the same folder — from the detail pane, a row's right-click, or the menu bar popover. It is each vendor's own flag doing the work (`--resume … --fork-session` for Claude Code, `codex fork` for Codex), which is what makes it safe to offer for a session that is still running: forking mints a new id and leaves the original alone, where resuming would put two writers on one transcript. Claude Code records nothing linking the copy to its original and the pane says so; Codex writes `forked_from_id` into the new session's log.",
            ]),
          Entry(
            ordinal: 9,
            headline: "Mouse bindings.",
            body: [
              "Middle and extra mouse buttons can cycle the session list or send a keystroke, through a `CGEventTap` whose mask is two event types wide.",
            ]),
          Entry(
            ordinal: 10,
            headline: "Menu bar.",
            body: [
              "An accessory app with a per-account popover, and a template glyph that fills while anything is working and rings when a session wants attention, on a configurable ladder. Star one plan limit, in Usage or above an account's sessions, and its percentage sits beside the glyph in small type.",
            ]),
          Entry(
            ordinal: 11,
            headline: "Settings",
            body: [
              "on `swift-support-kit`'s shared scaffold, with About and Help panes.",
            ]),
          Entry(
            ordinal: 12,
            headline: "What's New",
            body: [
              ", a Settings pane generated from this file, with a dot in the menu bar popover while a release is unread.",
            ]),
          Entry(
            ordinal: 13,
            headline: "Updates, off until you say otherwise.",
            body: [
              "Sparkle reads one file, `armada.mgcrea.io/appcast.xml`, only once automatic checks are on or Check Now is pressed, and sends no identifier with it. A one-time card in the main window asks.",
            ]),
          Entry(
            ordinal: 14,
            headline: "A licence, and a 30-minute trial.",
            body: [
              "One key covers every 1.x release on every Mac you own and is verified offline, on the Mac. Without one Armada watches nothing and says so where the sessions would be; the trial runs everything, and is started by hand.",
            ]),
          Entry(
            ordinal: 15,
            headline: "A supervisor for the fleet, off until you turn it on.",
            body: [
              "Settings ▸ Supervisor runs a read-only MCP server on 127.0.0.1 and starts a Claude Code session with it attached, so you can ask one session which of the others need you, what any of them is doing or last said, and how much plan is left. Five tools, none of which can change a session, start one or write anywhere. The session runs on your own plan, and its connection details never touch your Claude configuration.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 16,
            headline: "The network claim names the one socket Armada listens on.",
            body: [
              "The supervisor's MCP endpoint binds 127.0.0.1 and nothing else, and `make audit` checks that in the listener's source beside Sparkle's allowance.",
            ]),
          Entry(
            ordinal: 17,
            headline: "The network claim names its one exception.",
            body: [
              "`SECURITY.md` and `make audit` now say Armada reaches no network on its own apart from the opt-in update check, and the audit allows Sparkle exactly the capability it was measured to use.",
            ]),
          Entry(
            ordinal: 18,
            headline: "The scope line \"v1 watches; it doesn't launch agents\" was reopened",
            body: [
              ", deliberately, when New Session landed. Armada still never owns an agent process and still holds no credentials; what changed is that it can ask a terminal to start one.",
            ]),
          Entry(
            ordinal: 19,
            headline: "The menu bar halo is three assets",
            body: [
              "rather than a composed overlay, drawn as two arcs offset from each sail.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 20,
            headline: "Codex plan limits lagged",
            body: [
              "behind what was on disk: the newest figures usually live in a rollout the session scan has no reason to open. The scan now always tails the newest rollout in the tree.",
            ]),
          Entry(
            ordinal: 21,
            headline: "A Codex writer lock spans a session, not a turn",
            body: [
              "— confirmed, which is what makes \"waiting for input\" reachable.",
            ]),
          Entry(
            ordinal: 22,
            headline: "A session adopted mid-flight showed the wrong age",
            body: [
              ", because `lastWrite` was not seeded from disk.",
            ]),
          Entry(
            ordinal: 23,
            headline: "`CLAUDE_CONFIG_DIR` carried a trailing slash",
            body: [
              ", which made a stored value silently fail to match.",
            ]),
          Entry(
            ordinal: 24,
            headline: "Selecting a session added a ghost row",
            body: [
              "for the same project, gone a second later. Armada's own `claude` probes register as sessions on 2.1.269, and the list took them for real ones. Registries whose process is Armada's child are now skipped.",
            ]),
        ]),
    ])

  // swift-format-ignore
  static let unreleased: Release? = unreleasedRelease
  // </generated:changelog>
}
