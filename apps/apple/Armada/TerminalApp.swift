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
/// installed on this Mac.
///
/// **Ghostty was in the deliberately-absent list and is now measured in.** It was kept
/// out on the assumption it takes a command as an argument (`-e`) rather than as a
/// document; that was wrong for 1.3.1, which declares `.command`, `.tool`, `.sh`, `.zsh`,
/// `.csh` and `.pl` under `CFBundleDocumentTypes` as "Terminal scripts". Measured on
/// 2026-09-18 against a `chmod 700` script opened with `NSWorkspace`, which is the exact
/// call `NewSession.start` makes:
///
/// - **It runs the file**, and the script's own `cd` takes effect.
/// - **A clean exit closes the surface**, which is what `NewSession.body` relies on when
///   it waits for a keystroke only on a failure.
/// - **The ancestry walk reaches it in three hops** — script shell → login shell →
///   `login` → `ghostty` — so `login` is the `containerPID` exactly as it is for a
///   Terminal tab, and the tty is real (`/dev/ttys009`) rather than the `??` a
///   VS Code-hosted session shows. No daemonized server reparenting to launchd, which is
///   the thing that makes iTerm2 a special case. See `docs/focusing-sessions.md`.
/// - **No branch in `NewSession.start` was needed after all.** The prediction in the old
///   version of this comment assumed a second launch mechanism; the document path is the
///   same one Terminal.app takes.
///
/// One wart, and it is Ghostty's rather than Armada's: a **cold** launch opens Ghostty's
/// own default window beside the session's. A warm one does not.
///
/// WezTerm, kitty and Alacritty stay out on the original reasoning, now that it is known
/// to be an assumption: check `CFBundleDocumentTypes` before believing it of any of them.
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
    // Ghostty above iTerm because this order is what the picker shows and Ghostty is the
    // measured one; iTerm is still listed on its documentation alone. Terminal stays at
    // index 0, which `fallback` depends on.
    TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
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
