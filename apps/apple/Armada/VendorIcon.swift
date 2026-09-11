import AppKit

/// An installed app's icon, asked of the system at runtime.
///
/// Extracted from `ClaudeIcon` when Codex became a second vendor. **Nothing is
/// bundled**: LaunchServices is asked where the app with a bundle id lives and
/// IconServices is asked what it looks like, so Armada ships no Anthropic or OpenAI
/// artwork and none can go stale. Same rule and same reasoning as cupertino's
/// `AppIcon`.
@MainActor
enum VendorIcon {
  /// `icon(forFile:)` reaches IconServices, and a SwiftUI list redraws far more
  /// often than an installed app changes.
  ///
  /// Hits only. A miss costs one lookup per redraw and buys the property that
  /// matters more: installing the app while Armada is running picks the icon up at
  /// the next redraw rather than staying a glyph until somebody relaunches.
  private static var cache: [String: NSImage] = [:]

  static func image(bundleID: String) -> NSImage? {
    if let hit = cache[bundleID] { return hit }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    cache[bundleID] = icon
    return icon
  }
}
