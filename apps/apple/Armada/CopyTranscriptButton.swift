import AppKit
import SwiftUI

/// "Copy Transcript", for a session row's context menu.
///
/// The whole conversation as plain text, thinking and tool calls included, each entry at full
/// length. Read when the item is chosen rather than when the menu is built: a menu is opened
/// far more often than this is picked, and the read is a whole file.
struct CopyTranscriptButton: View {
  let url: URL?

  var body: some View {
    if let url {
      Button("Copy Transcript") { TranscriptCopy.copy(url) }
    }
  }
}

/// Putting a transcript on the pasteboard, off the main actor until it is one string.
enum TranscriptCopy {
  static func copy(_ url: URL, thinking: Bool = true, tools: Bool = true) {
    Task {
      let text = await Task.detached(priority: .userInitiated) {
        TranscriptLog.plainText(of: url, thinking: thinking, tools: tools)
      }.value
      // An unreadable file leaves the pasteboard as it was rather than emptying it.
      guard let text, !text.isEmpty else {
        NSSound.beep()
        return
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }
}
