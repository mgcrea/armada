/// Stands in for `AppInfo.swift`, which `License.swift` reaches only through the
/// `major:` default argument, and which would bring `ServiceManagement` and the real
/// bundle in behind it. Every licence check in `UnitCheck.swift` passes its major
/// explicitly, so this value is never the one under test.
///
/// `nonisolated` for the reason the real one is: `LicenseKey` reads it as a default
/// argument from outside the main actor, and this build uses the app's main-actor
/// default isolation.
nonisolated enum AppInfo {
  static let major = 1
}
