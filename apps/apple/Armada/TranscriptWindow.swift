import AppKit
import SwiftUI

/// The window a transcript is read in.
///
/// **A window rather than a third column.** `AccountPaneView` is an `HSplitView` whose
/// detail half has a 300pt floor and holds a `Form` of labelled values; a conversation put
/// there wraps into a column two or three words wide. A transcript wants the width a
/// document wants.
///
/// **One window that retargets, not one per session.** Reading two transcripts side by side
/// is a real thing to want, and this does not do it — the tradeoff bought is one autosaved
/// frame under one key, against a `NSWindow Frame transcript-<uuid>` accumulating in
/// defaults for every session ever opened, none of which is ever read again because session
/// ids do not repeat. If side-by-side turns out to matter, the thing to add is a second
/// window, not a key per session.
@MainActor
@Observable
final class TranscriptWindow {
  static let shared = TranscriptWindow()

  private(set) var url: URL?
  private(set) var name = ""

  // `@ObservationIgnored` because the macro rewrites stored properties into computed
  // ones and `lazy` cannot survive that. Nothing observes the window anyway — the two
  // properties above are what a view reads.
  @ObservationIgnored private lazy var window = HostedWindow(
    title: "Transcript",
    autosaveName: "transcript",
    contentSize: NSSize(width: 820, height: 640)
  ) { TranscriptWindowView() }

  private init() {}

  /// Show `url`, replacing whatever was being read.
  ///
  /// Write first, then open — the order `MainWindowRoute` and `showSettings(_:)` both need,
  /// and for the same reason: it is what makes this work on a window already up.
  func show(url: URL, name: String) {
    self.url = url
    self.name = name
    window.retitle(name)
    window.show()
  }
}

/// The window's content: whatever `TranscriptWindow` is pointed at.
struct TranscriptWindowView: View {
  @State private var target = TranscriptWindow.shared

  var body: some View {
    if let url = target.url {
      TranscriptPane(url: url, title: target.name)
        // The url, not the name: two sessions can share a title, and re-reading a
        // transcript because a session was renamed is work for nothing.
        .id(url)
    } else {
      ContentUnavailableView(
        "No Transcript", systemImage: "text.bubble",
        description: Text("Pick a session and choose Read Transcript."))
    }
  }
}

/// "Read Transcript", or why there is nothing to read.
///
/// **Claude Code only, and it says so rather than opening an empty window.** `TranscriptLog`
/// parses Claude Code's JSONL; a Codex rollout is a different format with its own entry
/// shapes, and pointing this at one would find no entries and render as a session that had
/// never been prompted. `TranscriptTail` already carries the vendor split for the supervisor
/// tools, and that is the shape to copy when this grows a second reader.
struct TranscriptButton: View {
  let session: Session

  var body: some View {
    if let transcript = session.transcript {
      Button {
        TranscriptWindow.shared.show(url: transcript, name: session.displayName)
      } label: {
        Label("Read Transcript", systemImage: "text.bubble")
      }
    } else {
      Label("No transcript yet", systemImage: "text.bubble")
        .foregroundStyle(.secondary)
        .help("A session that has never been prompted has no transcript file.")
    }
  }
}
