import Foundation
import SwiftUI

/// What a Grok Build session appears to be doing.
///
/// Codex's vocabulary, because Grok answers the same halves of the question: it writes the end
/// of a turn explicitly (`turn_completed`), and it says which sessions are open, here with a pid.
/// Grok could say more: a `permission_prompt` notification means a session wants the person.
/// That is not read from disk yet, so there is no `waiting` state to show.
enum GrokSessionState: String, Sendable {
  /// A turn is under way.
  case working
  /// Open in a TUI with its turn finished.
  case awaitingInput
  /// Not in `active_sessions.json` with a live pid, and not a headless run still writing.
  case ended

  var label: String {
    switch self {
    case .working: "Working"
    case .awaitingInput: "Waiting for input"
    case .ended: "Ended"
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .awaitingInput: .blue
    case .ended: .secondary
    }
  }

  var isLive: Bool { self != .ended }
}

/// One Grok Build session as Armada shows it.
@Observable
final class GrokSession: Identifiable {
  /// The session directory's name, which is also `summary.json`'s `info.id`.
  let id: String
  let directory: URL

  var summary: GrokFiles.Summary
  var state: GrokSessionState = .ended
  var lastEventAt: Date?
  var usage: GrokFiles.Usage?
  var context: GrokFiles.Context?
  /// From `active_sessions.json`, while the session is open in a TUI.
  var pid: Int32?

  /// `updates.jsonl`'s size at the last read, so an unchanged session is not re-read.
  var scannedSize: UInt64 = 0
  var summaryModified: Date?

  init(id: String, directory: URL, summary: GrokFiles.Summary) {
    self.id = id
    self.directory = directory
    self.summary = summary
  }

  var displayName: String { summary.title ?? summary.projectName }
  var isHeadless: Bool { summary.kind == "headless" }
  var isFork: Bool { summary.parentSessionId != nil }
}
