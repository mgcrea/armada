import Foundation
import SupportKit
import SupportKitSettings

/// Armada's identity for the shared support package.
///
/// One constant; the feedback URL, the support page, the prefilled issue and the
/// mail draft are all derived from it.
///
/// **`armada.mgcrea.io` does not resolve yet.** Checked on 2026-09-11: the host
/// has no DNS, so the Help menu's Support and Feedback items are dead links until
/// the marketing site ships. That is a deliberate, recorded placeholder rather
/// than an oversight — the fleet convention is `<app>.mgcrea.io` and swapping it
/// is this one line — but it is the thing to fix before anyone but the author
/// runs this build. `https://mgcrea.io/support/` and `/feedback/` both answer 200
/// today if an interim destination is wanted.
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
