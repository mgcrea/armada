import BuildSlotCore
import Darwin
import Foundation

/// Settings ▸ Build Slots' state: the switch, `settings.json`, the shims in `~/.local/bin`, and
/// whether the login shell's `PATH` reaches them.
///
/// **The settings file is at a fixed path, not under `AppInfo.supportDirectory`.** That folder is
/// keyed by bundle id, so a Debug and a Release build would each write their own file while the
/// one `buildslot` tool reads only `BuildSlotPaths.standard().settingsFile`.
///
/// **Only the Release bundle installs.** A Debug build pointing the shims at itself would leave
/// every build on the Mac depending on a bundle in DerivedData; on a branch, its own
/// `Contents/Helpers/buildslot install` does that on purpose, and the next Release launch takes
/// the shims back. Turning the switch off removes them from any bundle, and only files carrying
/// the shim marker.
///
/// Not `@AppStorage`, for `MouseBindingsStore`'s reason: launch reads the switch with no view
/// around, so the store is the authority and persists on write.
@MainActor
@Observable
final class BuildSlots {
  static let shared = BuildSlots()

  static let enabledKey = "armada.buildSlots.enabled"
  static let releaseBundleID = "io.mgcrea.armada"

  private(set) var isEnabled: Bool

  var settings: BuildSlotSettings {
    didSet {
      guard settings != oldValue else { return }
      saveSettings()
    }
  }

  /// The last install's outcome, for the pane's refusal lines. Nil until one ran.
  private(set) var installReport: InstallReport?
  /// Set when the login shell's `PATH` reaches the real `swift` before the shims. Nil when the
  /// check passed, has not run, or could not read the `PATH`: no warning on a guess.
  private(set) var pathWarning: String?
  /// Why `settings.json` could not be written, the last time it was not.
  private(set) var settingsError: String?

  /// Whether this bundle may install shims. See the type's comment.
  let installsShims = Bundle.main.bundleIdentifier == releaseBundleID

  private let paths = BuildSlotPaths.standard()
  private var pathCheck: Task<Void, Never>?
  private var shimWork: Task<Void, Never>?

  private init() {
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    settings = BuildSlotSettings.load(from: paths.settingsFile)
  }

  /// `~/.local/bin`, the one folder the shims live in.
  nonisolated static var binDir: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: ".local/bin", directoryHint: .isDirectory)
  }

  /// The helper this bundle ships, which the shims it writes call.
  nonisolated static var helperPath: String {
    Bundle.main.bundleURL.appending(path: "Contents/Helpers/buildslot").path(
      percentEncoded: false)
  }

  /// At launch: re-point the shims if Armada moved since they were written, and watch the queue.
  func launch() {
    if isEnabled && installsShims { install() }
    if isEnabled { checkPath() }
    BuildSlotMonitor.shared.start()
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    if enabled {
      if installsShims { install() }
      checkPath()
    } else {
      uninstall()
    }
  }

  /// Reads the login shell's `PATH` again. The pane calls it on appearance, since somebody
  /// fixing the warning edits their profile while Armada runs.
  func checkPath() {
    guard isEnabled else {
      pathWarning = nil
      return
    }
    pathCheck?.cancel()
    pathCheck = Task {
      let warning = await Self.readPathWarning()
      guard !Task.isCancelled, isEnabled else { return }
      pathWarning = warning
    }
  }

  /// Each install or uninstall waits for the one before it, so flicking the switch twice cannot
  /// remove the shims and then have an earlier install land after it.
  private func install() {
    let previous = shimWork
    shimWork = Task {
      await previous?.value
      let report = await Self.installOffMain()
      if isEnabled { installReport = report }
    }
  }

  private func uninstall() {
    installReport = nil
    pathWarning = nil
    pathCheck?.cancel()
    let previous = shimWork
    shimWork = Task {
      await previous?.value
      await Self.uninstallOffMain()
    }
  }

  @concurrent
  private nonisolated static func installOffMain() async -> InstallReport {
    ShimInstaller.install(binDir: binDir, helperPath: helperPath)
  }

  @concurrent
  private nonisolated static func uninstallOffMain() async {
    _ = ShimInstaller.uninstall(binDir: binDir)
  }

  private func saveSettings() {
    do {
      try StoreFile.write(settings.encoded(), to: paths.settingsFile, blockedBy: nil)
      settingsError = nil
    } catch {
      settingsError = error.localizedDescription
    }
  }

  // MARK: - PATH

  /// The person's login shell, asked for its `PATH` the way `VSCodeLaunch` asks it for its
  /// environment, cut off after five seconds.
  @concurrent
  private nonisolated static func readPathWarning() async -> String? {
    let shell = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    guard
      let data = await LoginShell.run(
        shell: shell, flags: ["-ilc"], script: "printf %s \"$PATH\"", timeout: 5),
      let path = String(data: data, encoding: .utf8), !path.isEmpty
    else { return nil }
    return pathWarning(shellPATH: path, binDir: binDir.path(percentEncoded: false))
  }

  /// The warning for `shellPATH`, or nil when a `swift` typed in that shell reaches the shim.
  /// The real one is found as the shim finds it, so a `swift` in Homebrew's or a toolchain's
  /// folder counts as well as `/usr/bin`'s.
  nonisolated static func pathWarning(shellPATH: String, binDir: String) -> String? {
    let real = RealTool.resolve(
      .swift, path: shellPATH, skipping: binDir, helperPath: helperPath)
    let realDir = (real as NSString).deletingLastPathComponent
    guard !PathCheck.shimsComeFirst(path: shellPATH, binDir: binDir, realToolDirs: [realDir])
    else { return nil }
    return "~/.local/bin must come before \(abbreviated(realDir)) on your shell's PATH."
  }

  private nonisolated static func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
    return path.hasPrefix(trimmed + "/") ? "~" + path.dropFirst(trimmed.count) : path
  }
}
