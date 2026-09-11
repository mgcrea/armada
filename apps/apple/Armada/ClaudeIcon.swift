import AppKit
import SwiftUI

/// The Claude icon, asked of the system at runtime. See `VendorIcon`, which holds
/// the lookup and the reasoning now that Codex is a second vendor.
///
/// Degrades to an SF Symbol, because Claude Code is a CLI: it is perfectly normal
/// for someone to run it with the desktop app nowhere on the Mac, and a missing
/// icon must not leave a hole in the sidebar.
@MainActor
enum ClaudeIcon {
  /// Claude for desktop. Verified on this Mac: `/Applications/Claude.app`.
  static let bundleID = "com.anthropic.claudefordesktop"

  static var image: NSImage? { VendorIcon.image(bundleID: bundleID) }
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
