import Foundation

/// Whether this launch is a screenshot capture, asked from anywhere.
///
/// The half of screenshot mode that has to compile into every build, because the
/// guards that read it live in shipping files: `HostedWindow`, `DockPresence`,
/// `Changelog`, the stores' refresh paths. What it answers is decided in
/// `DemoSeed`, which is `#if DEBUG` in its entirety — so in a Release build this is
/// the constant `false`, every guard folds away, and no shipped binary can be talked
/// into anything by a launch argument. See `LicenseStore` for why that matters here
/// more than in bastion and cupertino.
nonisolated enum ScreenshotMode {
  static let isEnabled: Bool = {
    #if DEBUG
      DemoSeed.isEnabled
    #else
      false
    #endif
  }()

  /// Whether the capture asked the app to stay out of the foreground.
  ///
  /// `appshot capture --no-activate` passes `-ScreenshotActivation none`; a focused
  /// run passes `focused`, and an older appshot passes nothing. Compared against
  /// `none` rather than `focused` so that the absent value keeps the behaviour a
  /// focused run needs: on macOS 14+ the app must put itself in front once, or the
  /// driver cannot raise it for the shutter.
  static let staysInBackground: Bool = {
    #if DEBUG
      DemoSeed.isEnabled && DemoSeed.activation == "none"
    #else
      false
    #endif
  }()
}

/// The time every screen is drawn at.
///
/// `Date()` everywhere else; under a capture, the one instant `DemoSeed.now` pins.
/// A screenshot of this app is mostly clocks — "resets in 2h", a weekly chart laid
/// out on weekday names, "3 minutes ago" beside every session — and a fixture
/// pinned relative to launch is deterministic only until the chart's axis lands on
/// a different weekday, which is the next morning.
///
/// **All or nothing.** Only *display* reads go through this. A clock that decides
/// correctness — a trial's expiry, a throttle, a timestamp something is stored with —
/// keeps `Date()`, because pinning one of those would be a bug dressed up for a
/// screenshot. And a display read left on `Date()` is worse than none of them
/// pinned: it drifts away from the rest a little more every day.
nonisolated enum AppClock {
  static var now: Date { pinned ?? Date() }

  /// The pinned instant, or nil on an ordinary launch.
  static var pinned: Date? {
    #if DEBUG
      DemoSeed.isEnabled ? DemoSeed.now : nil
    #else
      nil
    #endif
  }
}

/// `.relative(presentation:)`, measured from `AppClock` instead of the system clock.
///
/// SwiftUI's `Text(date, format: .relative(...))` formats against `Date.now` at
/// render time, so a pinned `now` in the view does not reach it. Off a capture this
/// is exactly the system style; on one it anchors the same presentation to the
/// pinned instant.
///
/// Search for `RelativeFormatStyle(` as well as `.relative(` when auditing: the panel's
/// compact reset label was built the long way, missed by the first sweep, and printed
/// "1w ago" beside a window resetting in two hours.
nonisolated struct ClockRelativeFormat: FormatStyle {
  let presentation: Date.RelativeFormatStyle.Presentation
  var unitsStyle: Date.RelativeFormatStyle.UnitsStyle = .wide

  func format(_ value: Date) -> String {
    guard let pinned = AppClock.pinned else {
      return Date.RelativeFormatStyle(presentation: presentation, unitsStyle: unitsStyle)
        .format(value)
    }
    return Date.AnchoredRelativeFormatStyle(
      anchor: value, presentation: presentation, unitsStyle: unitsStyle
    ).format(pinned)
  }
}

extension FormatStyle where Self == ClockRelativeFormat {
  static func clockRelative(
    presentation: Date.RelativeFormatStyle.Presentation,
    unitsStyle: Date.RelativeFormatStyle.UnitsStyle = .wide
  ) -> Self {
    ClockRelativeFormat(presentation: presentation, unitsStyle: unitsStyle)
  }
}
