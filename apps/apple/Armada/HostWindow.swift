import AppKit
import ApplicationServices
import Observation

/// Getting from a session's folder to the window that has it open.
///
/// **Why this exists at all.** The process walk in `SessionHost` reaches the
/// application and stops, which is the honest ceiling of a process walk — every VS
/// Code window on a Mac is drawn by one pid (measured 2026-09-12: pid 3280, six
/// windows), so activating that pid raises whichever window was frontmost last.
/// `containerPID` tells two sessions in the same app apart but maps to no window, and
/// `~/.claude/ide/<port>.lock` reports the *app* pid rather than the extension host's,
/// so it does not close the gap either. The Accessibility API is the only supported
/// route left, and this is it.
///
/// **No bundle identifiers anywhere.** The match is on window titles alone, so VS
/// Code, Cursor, VSCodium and Windsurf all work for the same reason and a terminal
/// whose title carries the folder works too. Anything that does not match falls
/// through untouched rather than being raised wrongly.
@MainActor
enum HostWindow {
  /// Whether Armada holds the Accessibility grant, asked **without prompting**.
  ///
  /// `AXIsProcessTrusted()` is the silent one; its `WithOptions` sibling takes
  /// `kAXTrustedCheckOptionPrompt` and will put a system alert on screen. Every
  /// caller here degrades quietly, so the silent one is the only one used — the
  /// grant is asked for in Settings, where there is room to say what it buys.
  ///
  /// The grant is keyed to the code signature, and Debug builds carry their own
  /// bundle identifier (`io.mgcrea.armada.debug`), so a granted debug build says
  /// nothing about the shipped one.
  static var isTrusted: Bool { AXIsProcessTrusted() }

  static func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }

  /// Raise the window of `pid` that has `cwd` open. `false` when there is no grant,
  /// no window, or no title that names the folder — in which case the caller should
  /// do what it did before this existed.
  ///
  /// The window, never the tab or the panel inside it. Raising VS Code's window does
  /// not put the cursor in the Claude panel, and nothing here pretends otherwise.
  @discardableResult
  static func raise(inApplication pid: pid_t, cwd: String) -> Bool {
    guard isTrusted else { return false }
    let app = AXUIElementCreateApplication(pid)

    // **Load-bearing, not tidiness.** Accessibility calls are synchronous IPC on the
    // calling thread and the default timeout is six seconds, so one wedged Electron
    // app would freeze Armada's UI for as long as it stayed wedged. Set on the
    // application element it covers every message sent to that application, so this
    // one call caps the whole walk below.
    AXUIElementSetMessagingTimeout(app, messagingTimeout)

    guard let windows = value(of: app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
    // Front-to-back, which is what makes "the first match" mean "the match you used
    // most recently" when the same folder is open in two windows.
    let titles = windows.map { value(of: $0, kAXTitleAttribute) as? String ?? "" }
    let folders = candidates(for: cwd)

    // **Both passes run over every candidate before the weaker one starts.** An
    // exact segment is worth more than a deeper folder name found loosely: a window
    // on `apps` whose title has a segment reading exactly `apps` is more certainly
    // the right one than a window mentioning `armada` somewhere in a filename.
    for folder in folders {
      if let index = titles.firstIndex(where: { names($0, folder) }) {
        return raise(windows[index])
      }
    }
    for folder in folders {
      if let index = titles.firstIndex(where: { mentions($0, folder) }) {
        return raise(windows[index])
      }
    }
    return false
  }

  /// Long enough that a busy application still answers, short enough that eleven
  /// windows of a wedged one cost a couple of seconds rather than a minute.
  private static let messagingTimeout: Float = 0.2

  /// How far above the session's own folder to look for the workspace root.
  private static let maxDepth = 4

  /// Folder names to try: `armada`, then `apps`, then `Projects`.
  ///
  /// The shallower ones are there for the session whose `cwd` is a subfolder of the
  /// folder the editor actually has open — a window on `~/Projects/apps` holding a
  /// session in `~/Projects/apps/armada` is matched by `apps` once `armada` has
  /// found nothing. It stops below the home directory, because `olivier` and `Users`
  /// name no project and would match half the titles on the machine.
  ///
  /// **Repository roots go first, and that is not a nicety.** Deepest-first alone
  /// gets `~/Projects/apps/armada/apps/apple` wrong: its `apps` is nearer than
  /// `armada`, so it wins, and it matches the *other* window — the one holding
  /// `~/Projects/apps`. Two unrelated directories sharing a name is exactly what
  /// matching on names cannot see, and an editor window is nearly always opened at a
  /// repository root, so preferring one settles it for four `stat` calls. A `.git`
  /// that is a file rather than a directory counts: that is what a worktree has.
  private static func candidates(for cwd: String) -> [String] {
    var url = URL(filePath: cwd).standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
    // `1` rather than `0` for a path outside home: the first component is "/".
    let floor = url.pathComponents.starts(with: home) ? home.count : 1
    guard url.pathComponents.count > floor else { return [] }

    var folders: [(name: String, isRepository: Bool)] = []
    for _ in 0..<min(url.pathComponents.count - floor, maxDepth) {
      let isRepository = FileManager.default.fileExists(
        atPath: url.appending(component: ".git").path)
      folders.append((url.lastPathComponent, isRepository))
      url = url.deletingLastPathComponent()
    }
    return folders.filter(\.isRepository).map(\.name)
      + folders.filter { !$0.isRepository }.map(\.name)
  }

  /// Separators a window title is built from, across every application seen.
  ///
  /// VS Code and Terminal both use an em dash; the rest are here because splitting
  /// on a separator that is not there costs nothing and a title that is one bare
  /// folder name still arrives as a single segment.
  private static let separators = CharacterSet(charactersIn: "—–|·")

  /// Whether one segment of `title` **is** `folder`.
  ///
  /// The strong signal, and the one that actually fires. Measured 2026-09-12, VS
  /// Code's six windows on this Mac title themselves
  /// `<active tab> — <folder> — <profile>`:
  ///
  /// ```
  /// Menubar icon halo border — armada — Skitrust
  /// Sentry MCP latest error — lisphoto-shopify-apps — TypeScript
  /// Direct sales apps settin… — apps — Skitrust
  /// ```
  ///
  /// Note what the first segment is — the Claude Code panel's own session title,
  /// because that panel is the active tab — and note that it is **truncated with an
  /// ellipsis** while the folder segment never is. Splitting is what keeps a stray
  /// `apps` inside a truncated tab name from outranking the window whose folder
  /// segment says `apps` outright.
  private static func names(_ title: String, _ folder: String) -> Bool {
    title.components(separatedBy: separators)
      .contains { $0.trimmingCharacters(in: .whitespaces) == folder }
  }

  /// Whether `title` mentions `folder` as a word of its own.
  ///
  /// The fallback, for an application whose title is shaped in a way the split above
  /// does not reach. A plain `contains` would be wrong here: a window on
  /// `armada-old`, or one simply editing `armada.ts`, both contain `armada` and
  /// neither is the window wanted. Requiring the characters either side of the hit
  /// to be non-word characters settles it without knowing any title format.
  private static func mentions(_ title: String, _ folder: String) -> Bool {
    guard !folder.isEmpty else { return false }
    var searched = title.startIndex
    while let found = title.range(of: folder, range: searched..<title.endIndex) {
      let before =
        found.lowerBound == title.startIndex
        ? nil : title[title.index(before: found.lowerBound)]
      let after = found.upperBound == title.endIndex ? nil : title[found.upperBound]
      if !isWordCharacter(before), !isWordCharacter(after) { return true }
      searched = title.index(after: found.lowerBound)
    }
    return false
  }

  private static func isWordCharacter(_ character: Character?) -> Bool {
    guard let character else { return false }
    return character.isLetter || character.isNumber || "._-".contains(character)
  }

  /// Unminimize first: `AXRaise` on a window that is in the Dock succeeds and
  /// changes nothing visible, which reads as a dead click.
  private static func raise(_ window: AXUIElement) -> Bool {
    if value(of: window, kAXMinimizedAttribute) as? Bool == true {
      AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
  }

  private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }
}

/// Whether Armada holds the Accessibility grant, as something a view can watch.
///
/// The grant is given in System Settings, outside this process, and there is no
/// notification for it — so the one moment it is worth re-reading is when Armada
/// becomes active again, which is exactly what a person coming back from granting it
/// does. Without this the Settings row would keep saying "Not allowed" until the
/// window was closed and reopened, which reads as the grant not having worked.
@MainActor @Observable
final class AccessibilityTrust {
  static let shared = AccessibilityTrust()

  private(set) var isTrusted: Bool

  private init() {
    isTrusted = HostWindow.isTrusted
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  func refresh() { isTrusted = HostWindow.isTrusted }
}
