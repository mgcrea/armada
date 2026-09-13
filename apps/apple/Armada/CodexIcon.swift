import AppKit
import SwiftUI

/// The Codex icon, asked of the system at runtime. See `VendorIcon`.
///
/// Degrades to an SF Symbol for the same reason `ClaudeIcon` does, and rather more
/// often: the `codex` binary ships *inside* ChatGPT.app on this Mac
/// (`/Applications/ChatGPT.app/Contents/Resources/codex`) and is not on `PATH`, but
/// the VS Code extension carries its own copy under `~/.vscode/extensions`. So
/// somebody can be running Codex all day with no ChatGPT.app installed, and the
/// row still has to look like something.
@MainActor
enum CodexIcon {
  /// Verified on this Mac with `mdls`: ChatGPT.app is `com.openai.codex`, not the
  /// `com.openai.chat` the name suggests.
  ///
  /// `nonisolated` so that `CodexCLI` — which runs off the main actor and looks inside
  /// this bundle for the `codex` binary — can name the same id rather than keeping a
  /// second copy of it. A `let` of a `String` is safe to read from anywhere.
  nonisolated static let bundleID = "com.openai.codex"

  static var image: NSImage? { VendorIcon.image(bundleID: bundleID) }
}

/// A sidebar-sized Codex icon, or the fallback glyph.
struct CodexIconView: View {
  var size: CGFloat = 16

  var body: some View {
    if let image = CodexIcon.image {
      Image(nsImage: image)
        .resizable()
        .frame(width: size, height: size)
    } else {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: size * 0.62))
        .frame(width: size, height: size)
    }
  }
}
