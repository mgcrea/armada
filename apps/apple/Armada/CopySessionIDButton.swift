import AppKit
import SwiftUI

/// "Copy Session ID", for a session row's context menu.
///
/// The id each vendor resumes by, so what lands on the pasteboard is what
/// `claude --resume`, `codex resume` or a transcript search wants, with nothing around it.
struct CopySessionIDButton: View {
  let id: String

  var body: some View {
    if !id.isEmpty {
      Button("Copy Session ID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
      }
    }
  }
}
