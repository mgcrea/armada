import AppKit
import SwiftUI

/// The Claude icon, asked of the system at runtime.
///
/// **Nothing is bundled.** LaunchServices is asked where the app with this bundle
/// id lives and IconServices is asked what it looks like, so Armada ships no
/// Anthropic artwork and none can go stale: an icon that changes in an update
/// changes here too. This is the same rule — and the same reasoning — as
/// cupertino's `AppIcon`, which draws Apple's app icons without redistributing
/// any of them.
///
/// Degrades to an SF Symbol, because Claude Code is a CLI: it is perfectly normal
/// for someone to run it with the desktop app nowhere on the Mac, and a missing
/// icon must not leave a hole in the sidebar.
@MainActor
enum ClaudeIcon {
  /// Claude for desktop. Verified on this Mac: `/Applications/Claude.app`.
  static let bundleID = "com.anthropic.claudefordesktop"

  /// `icon(forFile:)` reaches IconServices, and a SwiftUI list redraws far more
  /// often than an installed app changes.
  ///
  /// Hits only. A miss costs one lookup per redraw and buys the property that
  /// matters more: installing Claude while Armada is running picks the icon up at
  /// the next redraw rather than staying a glyph until somebody relaunches.
  private static var cached: NSImage?

  static var image: NSImage? {
    if let cached { return cached }
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    cached = icon
    return icon
  }
}

/// A sidebar-sized Claude icon, or the fallback glyph.
struct ClaudeIconView: View {
  var size: CGFloat = 16

  var body: some View {
    if let image = ClaudeIcon.image {
      Image(nsImage: image)
        .resizable()
        .frame(width: size, height: size)
    } else {
      Image(systemName: "sparkle")
        .frame(width: size, height: size)
    }
  }
}
