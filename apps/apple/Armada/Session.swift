import Foundation
import SwiftUI

/// What a session appears to be doing.
///
/// Inferred, never read: no state field exists in the registry, in
/// `claude agents --json`, or in the transcript format. See
/// `docs/claude-code-sessions.md`.
enum SessionState: String, Sendable {
  /// Wrote to its transcript within the idle threshold.
  case working
  /// Silent, and its newest entry is an unanswered `tool_use` — running a tool,
  /// or waiting for approval to. Best-effort; see `TranscriptTitle`.
  case runningTool
  /// Silent, and finished its turn.
  case idle

  var label: String {
    switch self {
    case .working: "Working"
    case .runningTool: "Running a tool"
    case .idle: "Idle"
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .runningTool: .orange
    case .idle: .secondary
    }
  }

  /// Whether the UI should mark this as a guess. `.runningTool` rests on a rule
  /// `docs/claude-code-sessions.md` files as unverified.
  var isBestEffort: Bool { self == .runningTool }
}

/// One session as Armada shows it: the registry row, plus everything inferred.
@Observable
final class Session: Identifiable {
  let registry: SessionRegistry

  /// Nil until a transcript is found — and permanently nil for a session that has
  /// never been prompted, which has no transcript file at all.
  var transcript: URL?

  /// The newest `ai-title`. Nil for never-prompted sessions, and for resumed ones:
  /// resuming mints a new `sessionId` and a transcript with no `ai-title` and no
  /// link back to the original.
  var title: String?

  var state: SessionState = .idle
  var lastWrite: Date?

  /// The newest rate-limit refusal seen in this session's transcript, if any.
  ///
  /// **Kept once seen, never cleared by a later read.** A refusal is a thing that
  /// happened, and the record scrolls out of the 64KB tail as the session carries
  /// on past it — re-reading and finding nothing means the tail has moved, not that
  /// the refusal was retracted. `QuotaHit.isLive` is what decides whether it still
  /// says anything about now.
  var quotaHit: QuotaHit?

  /// File size at the last title read, so an unchanged file is not re-read and the
  /// expensive full-scan fallback is paid for at most once per size.
  var titleScannedSize: UInt64 = 0
  var didFullScan = false

  var id: String { registry.sessionId }

  init(registry: SessionRegistry) {
    self.registry = registry
  }

  /// What to call this session in a list.
  var displayName: String {
    title ?? registry.name ?? registry.projectName
  }

  /// Why this session has no title, for the sessions list to explain itself.
  ///
  /// Best-effort by construction: the spike could not classify 3 of 6 untitled
  /// sessions even this way, because a resume copies history with fresh uuids and
  /// leaves nothing that identifies it as a resume.
  var untitledReason: String? {
    guard title == nil else { return nil }
    return transcript == nil ? "Never prompted" : "Resumed, or not yet titled"
  }
}
