import Foundation

/// The name a new Claude account's config folder gets, apart from the sheet that asks for
/// it — so `make unit` can check it.
///
/// **Armada never signs anyone in.** Adding an account is a name turned into
/// `~/.claude-<name>`, then an unmodified `claude` started in a terminal with
/// `CLAUDE_CONFIG_DIR` set to it; Claude Code runs its own onboarding and Anthropic's own
/// sign-in there. That is the line `docs/limits-accounts-and-terms.md` draws: a third-party
/// app may not offer Claude.ai login or touch its credentials, and this reads none and writes
/// none. Armada does not even create the folder. Claude Code does, along with `sessions/`,
/// the moment it starts and before its first question (measured 2026-09-17 on 2.1.274),
/// which is what lets `ClaudeConfigFolder.discoverAll` find the account at once.
nonisolated enum NewAccount {
  enum Check: Equatable {
    /// Nothing typed yet. Not an error, so the sheet says nothing about it.
    case empty
    case refused(String)
    /// The folder's own name, `.claude-work`, ready to be created.
    case ready(folderName: String)
  }

  /// The longest name accepted. A folder name, not a sentence.
  static let maximumLength = 40

  /// What `typed` would create in `home`, or why it cannot.
  ///
  /// **Letters, digits, `-`, `_` and `.`, starting with a letter or a digit.** The name
  /// becomes a path component and, through `CLAUDE_CONFIG_DIR`, part of a script. The script
  /// quotes it, but a name that needs quoting is one nobody will type correctly at a shell
  /// later, and a leading `.` or `-` reads as `..` or as a flag.
  ///
  /// The prefix is forgiven: someone who has read the note in Settings types `claude-work`
  /// or `.claude-work`, and meant `work`.
  ///
  /// **An existing folder is refused, whatever is in it.** One with `sessions/` is already an
  /// account in the list; one without is something else of the person's, and starting Claude
  /// Code on it would make it one.
  static func check(_ typed: String, home: URL, exists: (URL) -> Bool) -> Check {
    var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in [".claude-", "claude-"] where name.hasPrefix(prefix) {
      name.removeFirst(prefix.count)
      break
    }
    guard !name.isEmpty else {
      return typed.trimmingCharacters(in: .whitespaces).isEmpty
        ? .empty : .refused("Type a name after claude-.")
    }
    guard name.count <= maximumLength else {
      return .refused("Use at most \(maximumLength) characters.")
    }
    guard let first = name.unicodeScalars.first, isAlphanumeric(first),
      name.unicodeScalars.allSatisfy({ isAlphanumeric($0) || "-_.".unicodeScalars.contains($0) })
    else {
      return .refused("Use letters, digits, - _ and ., starting with a letter or a digit.")
    }
    let folderName = ".claude-\(name)"
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
