import Foundation

/// The folder a new account gets, apart from the sheet that asks for it — so `make unit` can
/// check it.
///
/// **Armada never signs anyone in.** Adding an account is a name turned into a folder beside
/// the agent's default one, then the agent's own unmodified CLI started in a terminal with its
/// home variable set to it; the agent runs its own onboarding and its vendor's own sign-in
/// there. That is the line `docs/limits-accounts-and-terms.md` draws for Claude Code: a
/// third-party app may not offer Claude.ai login or touch its credentials. Armada reads none
/// and writes none, for every vendor alike.
///
/// What each CLI leaves on disk at its first launch decides the rest, measured 2026-09-17 in
/// throwaway folders:
///
/// | | creates its folder | at launch, before any question |
/// | --- | --- | --- |
/// | Claude Code 2.1.274 | yes | `sessions/` |
/// | Grok Build 1.0.34 | yes | `sessions/`, `version.json` |
/// | Codex 0.154 | **no**: "CODEX_HOME points to … but that path does not exist" | `version.json`, and `sessions/` only once a session runs |
///
/// So Armada creates a Codex folder and nothing else, and a Codex home it added counts once
/// it has `version.json` (`CodexHome.discoverAll`).
nonisolated enum NewAccount {
  /// The agents an account can be added for.
  enum Vendor: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case grok

    var id: String { rawValue }

    var name: String {
      switch self {
      case .claude: "Claude Code"
      case .codex: "Codex"
      case .grok: "Grok Build"
      }
    }

    /// Whose sign-in the person meets in the terminal.
    var signInOwner: String {
      switch self {
      case .claude: "Anthropic"
      case .codex: "OpenAI"
      case .grok: "xAI"
      }
    }

    /// `claude` for `~/.claude-<name>`: the documented convention for Claude Code, and the same
    /// shape for the two that document none, so the folders read alike in Finder.
    var folderStem: String {
      switch self {
      case .claude: "claude"
      case .codex: "codex"
      case .grok: "grok"
      }
    }

    /// Codex refuses a home that does not exist; the other two make their own.
    var needsFolderCreated: Bool { self == .codex }
  }

  enum Check: Equatable {
    /// Nothing typed yet. Not an error, so the sheet says nothing about it.
    case empty
    case refused(String)
    /// The folder's own name, `.claude-work`, ready to be created.
    case ready(folderName: String)
  }

  /// The longest name accepted. A folder name, not a sentence.
  static let maximumLength = 40

  /// What `typed` would create in `home` for `vendor`, or why it cannot.
  ///
  /// **Letters, digits, `-`, `_` and `.`, starting with a letter or a digit.** The name
  /// becomes a path component and, through the home variable, part of a script. The script
  /// quotes it, but a name that needs quoting is one nobody will type correctly at a shell
  /// later, and a leading `.` or `-` reads as `..` or as a flag.
  ///
  /// The prefix is forgiven: someone who has seen `~/.claude-<name>` types `claude-work` or
  /// `.claude-work`, and meant `work`.
  ///
  /// **An existing folder is refused, whatever is in it.** One the agent uses is already an
  /// account; one it does not is something else of the person's, and starting the agent on it
  /// would make it one.
  static func check(
    _ typed: String, for vendor: Vendor, home: URL, exists: (URL) -> Bool
  ) -> Check {
    let stem = vendor.folderStem
    var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in [".\(stem)-", "\(stem)-"] where name.hasPrefix(prefix) {
      name.removeFirst(prefix.count)
      break
    }
    guard !name.isEmpty else {
      return typed.trimmingCharacters(in: .whitespaces).isEmpty
        ? .empty : .refused("Type a name after \(stem)-.")
    }
    guard name.count <= maximumLength else {
      return .refused("Use at most \(maximumLength) characters.")
    }
    guard let first = name.unicodeScalars.first, isAlphanumeric(first),
      name.unicodeScalars.allSatisfy({ isAlphanumeric($0) || "-_.".unicodeScalars.contains($0) })
    else {
      return .refused("Use letters, digits, - _ and ., starting with a letter or a digit.")
    }
    let folderName = ".\(stem)-\(name)"
    guard !exists(base(folderName: folderName, home: home)) else {
      return .refused("~/\(folderName) already exists.")
    }
    return .ready(folderName: folderName)
  }

  static func base(folderName: String, home: URL) -> URL {
    home.appending(path: folderName, directoryHint: .isDirectory)
  }

  /// ASCII only. `CharacterSet.alphanumerics` also takes `é` and every other script's
  /// letters, which is fine in a folder name and a trap in a shell variable somebody retypes.
  private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9": true
    default: false
    }
  }
}

/// The Codex and Grok Build homes somebody added through Armada, remembered because nothing
/// else would find them.
///
/// **A list rather than a scan, and that is the point.** `CodexHome.discoverAll` explains why
/// Armada does not scan for `~/.codex-*`: Codex names no convention, and inventing one turns a
/// backup folder into an account. A home here was named by the person, so it carries none of
/// that risk. And a GUI launch inherits no `CODEX_HOME` or `GROK_HOME`, so without this a home
/// added a minute ago would vanish at the next launch.
///
/// Claude Code needs no entry: `ClaudeConfigFolder.discoverAll` scans the convention its docs
/// give. Paths are stored without a trailing slash, as `CodexHome.path` spells them.
nonisolated enum AddedHomes {
  static func defaultsKey(for vendor: NewAccount.Vendor) -> String {
    "armada.addedHomes.\(vendor.rawValue)"
  }

  static func paths(for vendor: NewAccount.Vendor, in defaults: UserDefaults = .standard)
    -> [String]
  {
    defaults.stringArray(forKey: defaultsKey(for: vendor)) ?? []
  }

  static func add(
    _ path: String, for vendor: NewAccount.Vendor, in defaults: UserDefaults = .standard
  ) {
    let existing = paths(for: vendor, in: defaults)
    guard !existing.contains(path) else { return }
    defaults.set(existing + [path], forKey: defaultsKey(for: vendor))
  }

  static func remove(
    _ path: String, for vendor: NewAccount.Vendor, in defaults: UserDefaults = .standard
  ) {
    defaults.set(
      paths(for: vendor, in: defaults).filter { $0 != path }, forKey: defaultsKey(for: vendor))
  }
}
