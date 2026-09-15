import Foundation

/// The parts of a session's startup script that are only text, apart from `NewSession`, which
/// also needs AppKit to hand the script to a terminal — so `make unit` can check them.
nonisolated enum LaunchScript {
  /// A value as a single-quoted shell word, with any quote of its own escaped.
  ///
  /// Single quotes rather than double: inside them the shell expands nothing, so a folder named
  /// `$HOME` or `a(b)` is a folder and not an expansion. The one character that needs care is
  /// the quote itself, which is closed, escaped and reopened — the standard `'\''` dance.
  static func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// An opening message, read from its file rather than written into the script.
  ///
  /// **Never in the script's text.** The message comes from an agent, through
  /// `armada_start_session`, and a script is the one place where a mistake in quoting runs as a
  /// command. So the message is written to a 0600 file beside the script, read into a variable
  /// by zsh's `$(<file)`, and the file is removed before the agent starts. `"$prompt"` then
  /// reaches the command line as exactly one word: the shell does not split, glob or expand what
  /// a parameter expansion produces inside double quotes.
  static func promptLines(file: String) -> (setup: [String], argument: String) {
    (["prompt=\"$(<\(quoted(file)))\"", "rm -f \(quoted(file))"], "\"$prompt\"")
  }
}
