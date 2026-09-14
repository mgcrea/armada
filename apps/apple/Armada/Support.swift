import Foundation
import SupportKit
import SupportKitSettings

/// Armada's identity for the shared support package.
///
/// One constant; the feedback URL, the support page, the prefilled issue and the
/// mail draft are all derived from it.
///
/// `armada.mgcrea.io` has resolved since 2026-09-14, when the marketing site
/// shipped, so the Help menu's Support and Feedback items land on real pages. Until
/// then it was a recorded placeholder: the fleet convention is `<app>.mgcrea.io`,
/// and this one line is where the host would move.
///
/// `trackerURL` is the shared `mgcrea/support` tracker rather than a repo of
/// Armada's own, matching the eight App Store apps: Armada has no public
/// repository to file against. `preferIssueTracker` stays false for the same
/// reason — the tracker is a fallback here, not the primary channel it is for
/// cupertino, which does have a public repo.
enum Support {
  static let app = SupportApp(
    slug: "armada",
    displayName: "Armada",
    siteURL: URL(string: "https://armada.mgcrea.io")!,
    trackerURL: URL(string: "https://github.com/mgcrea/support")!
  )

  /// Whether the Help menu lists the public tracker above the feedback form.
  static let preferIssueTracker = false

  /// The persisted Settings pane. No `legacyKeys:` — Armada has never shipped, so
  /// there is no bare `settingsPane` key of its own to carry forward.
  static let settings = SettingsSelection<SettingsPane>(app: app)
}
