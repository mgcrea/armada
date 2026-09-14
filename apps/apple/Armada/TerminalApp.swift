import AppKit
import Foundation

/// The terminal a new session opens in.
///
/// **Armada starts a session by handing a shell script to a terminal**, the way
/// `open -a Terminal run.command` does, rather than by driving the terminal with
/// AppleScript. Two reasons, and neither is style. AppleScript would put Armada
/// behind an Automation consent prompt per terminal — a permission dialog for
/// something a user has asked for by clicking a button. And the script is the only
/// place the environment can be set: **the launching process's environment does not
/// reach the new window.** Measured 2026-09-13, with `CLAUDE_CONFIG_DIR` exported in
/// the process that ran `open` and empty in the shell that came up — LaunchServices
/// hands the request to Terminal, whose windows inherit *its* environment, not the
/// caller's. So everything a session needs is written into the script; see
/// `NewSession`.
///
/// **The table is short on purpose.** A terminal belongs here only if opening a
/// `.command` file with it *runs* the file. Terminal.app does, measured. iTerm2 is
/// listed on its documented handling of shell scripts and is **unverified** — not
/// installed on this Mac. Ghostty, WezTerm, kitty and Alacritty are deliberately
/// absent: they take a command as an argument (`-e`) rather than as a document, which
/// is a second launch mechanism, and inventing one per terminal without a copy to test
/// against is how you ship a button that does nothing. Adding one is a row here plus a
/// branch in `NewSession.start`, once somebody can run it.
///
/// Only installed terminals are ever offered, so an unverified row costs nothing on a
/// Mac that does not have it.
nonisolated struct TerminalApp: Identifiable, Hashable, Sendable {
  let name: String
  let bundleID: String

  var id: String { bundleID }

  /// Every terminal Armada knows how to start a session in, best first.
  static let known: [TerminalApp] = [
    TerminalApp(name: "Terminal", bundleID: "com.apple.Terminal"),
    TerminalApp(name: "iTerm", bundleID: "com.googlecode.iterm2"),
  ]

  /// Terminal.app, which every Mac has. The fallback whenever the stored choice no
  /// longer resolves — an uninstalled iTerm should not leave the button dead.
  static let fallback = known[0]

  var applicationURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  /// The ones on this Mac. Terminal.app cannot be uninstalled, so this is never empty.
  static var installed: [TerminalApp] { known.filter { $0.applicationURL != nil } }

  static let defaultsKey = "armada.newSessionTerminal"

  /// The stored choice, or the first installed terminal.
  ///
  /// Empty is the unset case — nobody has opened Settings — and resolves to Terminal
  /// rather than being written at launch, so a preference file records only what
  /// somebody actually chose.
  static func preferred(stored: String) -> TerminalApp {
    installed.first { $0.bundleID == stored } ?? installed.first ?? fallback
  }
}
