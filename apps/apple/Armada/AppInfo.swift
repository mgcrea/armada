import Foundation
import ServiceManagement

/// Who this copy of Armada is: version, build, and the identity macOS holds it to.
enum AppInfo {
  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// Marks a locally built copy wherever the version is shown. A Debug build and
  /// an installed one look identical in the menu bar, and telling them apart
  /// otherwise means reading `ps`.
  #if DEBUG
    static let developmentSuffix = "-dev"
  #else
    static let developmentSuffix = ""
  #endif

  /// The marketing version alone, for the places that show it in passing rather
  /// than as an About line: the menu bar popover and the sidebar footer.
  static var shortVersion: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    return short + developmentSuffix
  }

  /// The commit this bundle was built from, or nil for a build that had no git to
  /// ask — an Xcode-only build, or a source tarball.
  ///
  /// `CFBundleVersion` is the commit *count*, which orders builds but does not
  /// identify one: two branches at the same depth carry the same number, and so
  /// does a rebuild after an amend. This is the part that turns "0.1.0 (1)" in a
  /// bug report into a diff.
  static var commit: String? {
    let value = Bundle.main.infoDictionary?["ArmadaGitCommit"] as? String ?? ""
    return value.isEmpty ? nil : value
  }

  /// One line naming this exact build, for pasting into a bug report. Everything
  /// a maintainer needs to reproduce what the reporter is running, and nothing
  /// that identifies them.
  static var buildLine: String {
    var parts = ["Armada \(version)"]
    if let commit { parts.append(commit) }
    parts.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    return parts.joined(separator: " · ")
  }
}

/// Start Armada at login.
///
/// A convenience rather than a requirement for this prototype: Armada only reads
/// `~/.claude/*`, so a session it was not running for is fully readable the
/// moment it starts. That changes if the messaging design in `docs/design.md`
/// ever lands — hook events fired while the app is closed are lost — which is
/// why the intent is recorded now rather than inferred from the service later.
enum LoginItem {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static var status: SMAppService.Status {
    SMAppService.mainApp.status
  }

  /// Returns a message on failure, nil on success.
  ///
  /// Registering from a translocated or temporary copy records a path that will
  /// not be there next login. Not guarded here the way cupertino guards it,
  /// because this app has no installer yet; `GeneralPane` shows the real status
  /// back, so a registration that did not take is visible rather than assumed.
  static func set(_ enabled: Bool) -> String? {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}
