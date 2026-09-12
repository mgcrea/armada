import Foundation
import SwiftUI

/// What a Codex session appears to be doing.
///
/// A different set from `SessionState`, and the difference is the point. Claude
/// Code tells Armada a session is *alive* (a registry file with a live pid) and
/// leaves it to guess at the turn; Codex tells it the turn is over (`task_complete`
/// is written explicitly) and leaves it to guess at the session. The two vendors
/// answer opposite halves of the same question, so pretending one enum fits both
/// would mean throwing away whichever half the shared enum could not express.
///
/// The mapping is deliberately correct under both readings of the lock file — see
/// `CodexLocks` for what the probe could and could not settle. If the lock spans a
/// whole session, `awaitingInput` is a real state and appears for an idle
/// interactive session. If it only spans a turn, `awaitingInput` simply never
/// occurs and the list is still right. **Seeing an `awaitingInput` row in the wild
/// is what settles the open question**, which is a good reason not to collapse it
/// into `ended`.
enum CodexSessionState: String, Sendable {
  /// A process holds the lock and the last event is not `task_complete`.
  case working
  /// A process holds the lock and the turn is finished.
  case awaitingInput
  /// No lock. The session's process is gone, or it crashed and left the lock —
  /// which nothing on disk can tell apart.
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

  /// Whether the UI should mark this as a guess.
  ///
  /// **Nothing here is, which is the whole difference from `SessionState`.** Codex
  /// writes both edges of a turn explicitly and holds a lock for the life of a
  /// session, so all three states are read rather than inferred.
  ///
  /// `awaitingInput` was marked best-effort until 2026-09-12, when the lock was
  /// confirmed to span a session rather than a turn — an idle VS Code thread was
  /// found still holding its lock 7h20m after `task_complete`, and the state has
  /// since been seen in the app. The property stays so that the shared dot keeps one
  /// shape for both vendors, and so there is somewhere obvious to set it if a future
  /// state does need hedging.
  var isBestEffort: Bool { false }

  /// Whether this session is one a person might still be sitting in front of.
  var isLive: Bool { self != .ended }
}

/// One Codex session as Armada shows it.
@Observable
final class CodexSession: Identifiable {
  /// The uuid from the rollout's **filename**, which is also what the lock file is
  /// named and what `session_index.jsonl` keys on. Taken from there rather than
  /// from the parsed `session_meta` so that a row has an identity before — and
  /// even without — a successful parse, and so that the one field Codex fills in
  /// surprisingly (`session_id` on a subagent, see `CodexSessionMeta.sessionId`)
  /// cannot decide which row is which.
  let id: String

  let meta: CodexSessionMeta
  let rollout: URL

  /// From `session_index.jsonl`. Nil for a thread Codex never named — on this Mac
  /// that means every `guardian_review` subagent. See `CodexTitleIndex`.
  var title: String?

  var state: CodexSessionState = .ended
  var lastEventAt: Date?

  /// Cumulative tokens across the session — every request added up, which on a long
  /// session is several times the context window. Shown as a session total and never
  /// as occupancy; `context` is the occupancy.
  var totalTokens: Int?

  /// The newest request's prompt, and the window Codex stated for it. Held rather
  /// than cleared when a scan reads nothing, for the reason the Claude side holds its
  /// context figures: a tail that happens to contain no `token_count` is not evidence
  /// that the session has emptied.
  var context: ContextReading?
  var contextLimit: Int?
  var growth: ContextGrowth?

  /// What the session was carrying on its first request. Filled in once, off the main
  /// actor — the first `token_count` sits hundreds of KB into the file.
  var baseline: ContextBaseline?
  var didScanBaseline = false

  /// File size at the last tail read, so a rollout that has not grown is not
  /// re-parsed on every filesystem event.
  var tailScannedSize: UInt64 = 0

  init(id: String, meta: CodexSessionMeta, rollout: URL) {
    self.id = id
    self.meta = meta
    self.rollout = rollout
  }

  var displayName: String { title ?? meta.projectName }

  /// A spawned subagent rather than a thread someone started. `parent_thread_id`
  /// is set on exactly these, so this needs no guessing from names.
  var isSubagent: Bool { meta.parentThreadId != nil }

  /// "Automation", "Guardian review", "You" — what started this thread.
  ///
  /// `thread_source` is the honest field for it. `source` is not: it is `"vscode"`
  /// on a normal thread and the JSON object `{"subagent":{"other":"guardian"}}` on
  /// a spawned one, so anything reading it as a string gets nil exactly where the
  /// interesting case is.
  var kindLabel: String? {
    switch meta.threadSource {
    case "user": nil  // the ordinary case needs no badge
    case "automation": "Automation"
    case "guardian_review": "Guardian review"
    case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
    case nil: nil
    }
  }

  /// Why this session has no title, for the list to explain itself.
  var untitledReason: String? {
    guard title == nil else { return nil }
    return isSubagent ? "Spawned subagent" : "Not named yet"
  }
}
