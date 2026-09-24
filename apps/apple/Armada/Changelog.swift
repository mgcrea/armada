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

  /// The most recent 5 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = [v1_7_0, v1_6_0, v1_5_0, v1_4_0, v1_3_0]

  // swift-format-ignore
  private static let v1_7_0: Release = Release(
    version: "1.7.0",
    date: "2026-09-24",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "See when a session's prompt cache goes cold.",
            body: [
              "A stopped Claude Code session's context panel now says how long its prompt cache stays warm, and once it has lapsed, how much the next turn writes back. In the sessions list, a timer appears beside the token count in the last quarter of the cache's life and a snowflake once it has expired. Nothing shows while the cache is comfortably warm or the session is working. Codex and Grok Build are left out, since their logs never say how long their caches last.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Get warned before a prompt cache expires.",
            body: [
              "Warn before a prompt cache expires, in Settings ▸ General, sends one notification per cache in the last quarter of its life, either for sessions waiting on a prompt or for any session between turns, and only for prompts over a size you pick (100k by default). Clicking it brings the session forward. It is off until you turn it on.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Continue on another account without a terminal.",
            body: [
              "A new toggle in Settings ▸ General makes Continue on Another Account copy the conversation and stop there, for anyone who switches an editor window's account by hand. The action then reads Copy to Another Account, and its note says to close this session before opening the copy from Claude Code's past conversations, since it keeps the same session id.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "A conversation handed to another account can come back.",
            body: [
              "Carrying it back to the account it started on used to report a different conversation under the same id, because closing the session there appends a few bookkeeping lines the earlier copy never had. Those are now set aside before comparing. An original that gained a real message is still left alone.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_6_0: Release = Release(
    version: "1.6.0",
    date: "2026-09-23",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Close a session from Armada.",
            body: [
              "Close Session, last in a Claude Code session's details, its right-click menu and the menu bar popover, ends the session the way quitting it in its terminal would. An idle session or one waiting on you closes straight away, since the conversation stays on disk and can be picked up again. One that is working or running a tool asks first, because closing it stops the turn part-way. Closing several rows is that many clicks, with no wait in between.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Pick up a session that has ended.",
            body: [
              "Recently ended, under Live sessions in a project's details, lists the last eight Claude Code sessions that ran in that project and are no longer open, however they stopped. Click one to read its transcript, or press Resume to continue it in a terminal on the account it ran on. A session still open elsewhere is not listed, so one conversation never gets two writers.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Copy a transcript.",
            body: [
              "Copy Transcript, in a Claude Code session's right-click menu and in the Recently ended list, puts the whole conversation on the clipboard as plain text, each turn labelled and timed. Copy, in the transcript window's footer, does the same for what the Thinking and Tools checkboxes are showing. Either way every entry is copied at full length, including the long tool results the window cuts short.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Copy a session's id.",
            body: [
              "Copy Session ID, in the right-click menu of a Claude Code, Codex or Grok Build session, copies exactly the id `claude --resume` or `codex resume` takes, with nothing around it.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 4,
            headline: "A burst early in the week now shows the overrun chevron.",
            body: [
              "For the first tenth of a weekly window there is too little history to project from, so usage far ahead of pace drew a calm bar. Until the projection is ready, the chevron now comes up once usage runs 5 points ahead of pace.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_5_0: Release = Release(
    version: "1.5.0",
    date: "2026-09-21",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Continue a Claude Code session on another account.",
            body: [
              "A session stopped at one account's limit had no way onto the other. \"Continue on\" followed by the account's name, next to Fork Session in a session's details, in its right-click menu and in the menu bar popover, copies the conversation to that account and opens it there in a terminal. With more than two accounts it is a menu of them, and with one account it is not shown at all. The session you started from keeps running, untouched: the copy gets a session id of its own and arrives under the other account as a separate row. Earlier turns stay counted against the account that spent them. This is the one write Armada makes into Claude Code's own folders. It copies that session's transcript and nothing else, and it refuses rather than overwrite a different conversation already there. Claude Code sessions only, and only one that has been prompted at least once.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_4_0: Release = Release(
    version: "1.4.0",
    date: "2026-09-18",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Read a session's conversation in a window of its own.",
            body: [
              "\"Read Transcript\", on a session's details or its right-click menu, opens what that session has been saying and doing — the turns, the thinking, the tool calls — in a window sized to read in, rather than in the sidebar's detail column, which wraps a conversation into a strip two or three words wide. Thinking and Tools are checkboxes in the footer, so a long session can be read as just the conversation, and the footer counts what the filters are hiding. A long tool result or a screenshot is cut short in the window and kept whole on disk. Claude Code sessions only: Codex and Grok Build write a transcript in a different format, and a session that has never been prompted has no transcript to read.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Follow a session as it works.",
            body: [
              "Follow, in the transcript window's footer, re-reads the file as it grows and keeps you at the newest turn — read a session beside the editor it is working in and watch the turns land. It is on by default and remembered for the next window. Expanding a row or changing a filter no longer yanks you to the bottom, so you can stop and read something while the session keeps going.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Choose what the transcript window is made of.",
            body: [
              "Settings ▸ General ▸ Transcript picks between Solid, Frosted, Desktop through and Glass. Solid is the default and stays the most readable: it is the only one whose contrast does not depend on the wallpaper behind it. The picker says what each one costs rather than what it looks like, because the other three get harder to read the busier the desktop is.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Start sessions in Ghostty.",
            body: [
              "Ghostty joins Terminal and iTerm in the terminal picker, and is offered only if you have it. It was left out on the belief that it could not run a session's startup script; measured against the call Armada actually makes, it runs it, starts in the right folder, and closes the surface when the session ends. One wart, and it is Ghostty's: launching it cold opens its own default window beside the session's.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 4,
            headline: "Armada no longer quits while you resize a window.",
            body: [
              "Remembering a window's size wrote it out from inside the window's own layout pass, and that write could land back in the layout pass that was still running — which macOS refuses to re-enter, taking the app down with it. Resizing the main window or Settings could end the app outright. Sizes are still remembered, and one saved by an earlier version is still restored.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_3_0: Release = Release(
    version: "1.3.0",
    date: "2026-09-18",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Back and Forward as one mouse trigger.",
            body: [
              "A binding can take both thumb buttons rather than one: pressed together, or one held while the other is clicked. Hold Back and click Forward again and again to walk the fleet without letting go. The three are listed under \"Both thumb buttons\" in the trigger picker. A combo has to wait to tell itself apart from a plain press, so with no modifier set the row says what that costs: Back and Forward reach other apps 70 ms late for a together binding, and only on release for a held one. Give the combo a modifier and nothing is delayed — a bare Back is never held back, and a button no combo could claim is never touched at all.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Send a key with the modifier you choose.",
            body: [
              "A keystroke used to arrive with whatever you were holding on the button. The action menu now has a \"Sent with\" section: leave it \"As held\", or name one modifier, or none. A bare thumb button can then still send ⌘F16. The action still reads as the chord that will actually arrive, which is the one to bind in the other app.",
            ]),
          Entry(
            ordinal: 2,
            headline: "A held trigger holds its modifier down.",
            body: [
              "While the button that sent a key is still down, Armada holds the modifier down as a real key, the way a hand holds ⌘ through ⌘Tab, and lets go when you do. VS Code's window picker wants exactly that: ⌥F15 opens it, each further press walks it, and releasing ⌥ picks. It used to stay open until you pressed Return.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "A sent F-key now reaches apps that took it as a global shortcut.",
            body: [
              "F13–F20 went out without the fn flag a real keyboard sets, and a Carbon hot key — how most menu bar apps register a global shortcut — does not match one without it. A sent F17 went straight past the app waiting for it and landed on the front one as a key nobody handles, which is a beep.",
            ]),
          Entry(
            ordinal: 4,
            headline: "An agent's opening message is sent while another app is in front.",
            body: [
              "Starting a Claude Code session in VS Code typed the message into the tab, then waited for VS Code to be the frontmost application before pressing Return. A session that opened while anything else held the front never got it: the message sat in the tab for fifteen seconds and was given up on. Armada no longer waits for the front, and focuses the tab's input itself rather than trusting that the new tab kept focus.",
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
