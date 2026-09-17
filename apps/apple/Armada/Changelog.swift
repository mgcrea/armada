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

  /// The most recent 2 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = [v1_1_0, v1_0_0]

  // swift-format-ignore
  private static let v1_1_0: Release = Release(
    version: "1.1.0",
    date: "2026-09-16",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Projects.",
            body: [
              "A new pane under Usage lists the folders you work in, and starts a Claude Code or Codex session in one with a click, on the account the project remembers or on any other, even in a folder that has never had a session. Select a project to see the live sessions inside it, subfolders and worktrees included. Add several folders at once from the picker or by dropping them from Finder, and \"Add to Projects\" is on every session row and recent folder.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Tokens spent, per project.",
            body: [
              "A project's pane shows the tokens used in it over 7 days, 30 days and all time, split by model, account and subfolder. They are read in the background from every Claude Code transcript and Codex rollout on the Mac, each response counted once even when a resumed or forked session copies it, and kept after Claude Code clears old transcripts.",
            ]),
          Entry(
            ordinal: 2,
            headline: "`armada_get_projects`.",
            body: [
              "The MCP server's sixth read-only tool: each saved project's default agent and account, its live sessions, and its tokens over 7 days, 30 days and all time, with a split by model and account for one project. It says when older transcripts are still being read, so an agent does not quote a low total as final.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Agents can start sessions, when you allow it.",
            body: [
              "Settings ▸ Supervisor has an Allow writes switch, off by default. Turned on, the MCP server adds `armada_start_session`, which opens your terminal on a fresh Claude Code or Codex session in one of your saved projects, on its own account or one the agent names, optionally with an opening message. The session asks you for every permission as usual, the supervisor is not pre-allowed to call it, and a message that would be read as a flag, a shell command or a slash command is refused.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Connect a client with one click.",
            body: [
              "Settings ▸ Supervisor lists the MCP clients on your Mac, Claude Code once per account plus ChatGPT & Codex, Cursor and Visual Studio Code, and adds Armada to any of them with Configure or takes it back out with Remove. Nothing else in the client's config changes, the previous file is kept beside it as a backup, and a server of someone else's that already uses the name is never replaced without asking. Regenerating the token or changing the port updates every client configured this way. The copy-paste setup is still there for any other client.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Talk to Armada.",
            body: [
              "Settings ▸ Voice gives Armada a global shortcut: press it, or hold it, anywhere on the Mac, ask about your sessions out loud, and a card at the top of the screen shows the question and then the answer while it is spoken. Your speech is recognised on the Mac by Parakeet v3, which works out which of 25 languages you are speaking, or by Apple's dictation until you download Parakeet, and the audio is never kept. The question goes to Anthropic as text through your own `claude`, on the account you pick, and a follow-up continues the same conversation. Off by default; it reads the fleet through the MCP server in Settings ▸ Supervisor.",
            ]),
          Entry(
            ordinal: 6,
            headline: "A more natural voice for replies, on this Mac.",
            body: [
              "Settings ▸ Voice can download Kokoro, about 95 MB from huggingface.co, and read answers with it instead of a system voice. It runs on the Mac, reads English, and never makes an answer wait: a sentence goes to the system voice while Kokoro is still loading or when Kokoro cannot read it. Not offered on macOS 26.4 and 26.5, where an Apple bug crashes it.",
            ]),
          Entry(
            ordinal: 7,
            headline: "Working hours for the weekly pace.",
            body: [
              "Settings ▸ Usage takes the hours you usually work and how much the rest of the day counts, so an evening's work is no longer measured against a week of round-the-clock days. The pace tick on a usage bar gains a caret above it, and hovering the bar says how many points ahead of or behind pace you are.",
            ]),
          Entry(
            ordinal: 8,
            headline: "Focus from the row.",
            body: [
              "Session rows in the menu bar popover and in an account's session list carry a Focus button that brings forward the app hosting the session. It is drawn bright when it will reach the session itself, and dimmer when it will stop at the window or the app.",
            ]),
          Entry(
            ordinal: 9,
            headline: "Focus reaches a session's own tab in VS Code.",
            body: [
              "For a session in the Claude Code extension, Focus raises the right window and then asks the extension to show that session's tab, which Accessibility cannot do. It asks only once the window in front is shown to hold the session, so a session is never opened a second time in another window. VS Code asks once whether Claude Code may open the link.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 10,
            headline: "Sessions in a saved project skip Claude Code's trust dialog.",
            body: [
              "Starting a Claude Code session in a project you saved marks its folder trusted on that account, the flag \"Yes, I trust this folder\" sets, so the session opens on its prompt. It is the one thing Armada writes to Claude Code's configuration: one field in `.claude.json`, written under Claude Code's own lock and edited in place, with the rest of the file left exactly as it was.",
            ]),
          Entry(
            ordinal: 11,
            headline: "Armada runs a `claude` of its own while you talk to it.",
            body: [
              "Voice starts your installed `claude` headless with no built-in tools and only Armada's six read tools, keeps it for follow-up questions, and closes it after five idle minutes. It is the one agent process Armada owns rather than watches.",
            ]),
          Entry(
            ordinal: 12,
            headline: "One entitlement: the microphone.",
            body: [
              "The app is signed with `com.apple.security.device.audio-input`, used only while voice listens. `make audit` and `make sign` allow exactly that key and fail on any other.",
            ]),
          Entry(
            ordinal: 13,
            headline: "A second thing Armada can download: voice's speech models.",
            body: [
              "When Parakeet v3 or Kokoro is not already in FluidAudio's shared models folders, Settings ▸ Voice offers it, about 480 MB and 95 MB from huggingface.co, and fetches each only when you press its Download button. `make audit` allows FluidAudio's download code in its own framework, `ArmadaSpeech`, and nowhere else.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 14,
            headline: "A renamed session keeps its name.",
            body: [
              "Claude Code goes on writing AI titles after a rename, and Armada showed whichever title was newest, so a rename reverted as soon as the next AI title landed. The newest title you set now wins, and an AI title is shown only when there is none.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_0_0: Release = Release(
    version: "1.0.0",
    date: "2026-09-14",
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
          Entry(
            ordinal: 16,
            headline: "A network claim you can check.",
            body: [
              "Armada reaches no network on its own apart from the opt-in update check, and listens on one socket, the supervisor's MCP endpoint, on 127.0.0.1 only. `SECURITY.md` says so, and `make audit` asserts it against the built app.",
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
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Choose the language voice answers in.",
            body: [
              "Settings ▸ Voice has an Answer in picker: the language you ask in, as before, or one language whatever you speak, such as English when you ask in French. Changing it starts a new conversation at your next question. The Voice picker lists that language's system voices, and it is the language a system voice falls back to while Kokoro is loading.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Tell voice how to answer.",
            body: [
              "Settings ▸ Voice has an Instructions box, filled in with how voice answers today: one to three short spoken sentences, sessions called by name. Rewrite it to change how replies sound, or go back with Reset to Default. Armada's own rules apply whatever it says: the tools voice may use, asking before it starts a session, and never acting on text found in a transcript. A change starts a new conversation at your next question.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Start Claude Code sessions in Visual Studio Code.",
            body: [
              "Turn it on in Settings ▸ General, and a new Claude Code session opens as a tab in the project's own VS Code window, or in a new window on the session's account when the project is not open. Armada brings that window to the front first, so the tab never lands in another project, and it needs the Accessibility permission Focus already uses. A new window gets your shell's PATH. An opening message from an agent is typed into the tab for you to send. If a project's window is open on a different account, Armada says so rather than starting there. Forks, Codex and the supervisor still open in your terminal.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Start a session by voice.",
            body: [
              "With Allow writes on in Settings ▸ Supervisor, voice can start a new session in one of your saved projects. It says which project, account and opening message it will use and waits for you to confirm before starting it, and the new session still asks you for every permission. With Allow writes off, voice says that is what it needs. Voice still cannot close a session.",
            ]),
          Entry(
            ordinal: 4,
            headline: "A supervisor can close a Claude Code session.",
            body: [
              "With Allow writes on, the MCP server adds `armada_close_session`, which ends a session's process the way quitting it would: the transcript is kept and the session can be resumed. A session that is working or running a tool is closed only when the agent passes `force`, which the tool tells it to ask you about first. The supervisor is not pre-allowed to call it, voice cannot, Codex sessions cannot be closed, and an agent can close one session every five seconds.",
            ]),
          Entry(
            ordinal: 5,
            headline: "A supervisor can watch, and resume what it closed.",
            body: [
              "`armada_wait` holds a call open until a session newly needs you or changes state, for up to four minutes, so a supervisor watches without polling; it only reads, and the supervisor is allowed it. `armada_start_session` now returns the new session's id when it opens in a terminal, and with Allow writes on it can resume a Claude Code session in a saved project that nothing has open, such as one it just closed, in the folder and on the account it ran on.",
            ]),
          Entry(
            ordinal: 6,
            headline: "A supervisor can message a Claude Code session.",
            body: [
              "Turn on Settings ▸ Supervisor ▸ Deliver messages to sessions, and `armada_send_message` puts a message in front of a running session: an idle one starts a turn on it within a couple of seconds, and a busy one reads it when its turn ends. It works by adding one hook to each Claude Code account's `settings.json`, and turning the switch off removes exactly that hook. The session sees the message labelled as coming from an agent, not from you. It needs Allow writes, the supervisor asks you before each message, voice cannot send one, Codex sessions cannot be reached, and a message nothing picks up within an hour is dropped.",
            ]),
        ]),
    ])

  // swift-format-ignore
  static let unreleased: Release? = unreleasedRelease
  // </generated:changelog>
}
