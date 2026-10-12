import Foundation
import SwiftUI

/// What a session is doing.
///
/// **Reported where Claude Code reports it, inferred only where it does not.** The
/// registry carries a `status` of `busy` / `waiting` / `idle` — see
/// `SessionRegistry.status` — and that is the authority for the coarse state. Earlier
/// versions of this app had no such field to read and inferred all three from
/// transcript writes; that inference survives as the fallback for a folder running an
/// older build, and as the one refinement the registry cannot make.
///
/// See `docs/claude-code-sessions.md`.
enum SessionState: String, Sendable {
  /// `status: "busy"` — or, with no reported status, wrote to its transcript within
  /// the idle threshold.
  case working
  /// Busy, and its newest transcript entry is an unanswered `tool_use`.
  ///
  /// **The one state that is still a guess, and the only one that has to be.** The
  /// registry says `busy`; the transcript says what kind of busy. See
  /// `TranscriptTitle.isAwaitingToolResult`.
  case runningTool
  /// `status: "waiting"` — stopped, and wanting something from you. What it wants is
  /// in `Session.waitingFor`.
  ///
  /// Claude Code's own word for this status, kept rather than renamed: the app's rule
  /// is to use each vendor's vocabulary rather than invent a third. Note that
  /// `MenuBarHalo.blocked` is a *setting*, not this.
  case waiting
  /// `status: "idle"` — or, with no reported status, silent and finished its turn.
  case idle

  var label: String {
    switch self {
    case .working: "Working"
    case .runningTool: "Running a tool"
    case .waiting: "Waiting for you"
    case .idle: "Idle"
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .runningTool: .orange
    // Blue, as `CodexSessionState.awaitingInput` is. The two vendors mean subtly
    // different things by it, but "this one is stopped and wants you" is the same
    // sentence in both panes and should not be two colours.
    case .waiting: .blue
    case .idle: .secondary
    }
  }

  /// Whether the UI should mark this as a guess.
  ///
  /// Only `.runningTool`, and now for a narrower reason than it used to be: the other
  /// three come straight from the registry. It stays best-effort because distinguishing
  /// a running tool from one awaiting approval is the transcript's job, and the
  /// transcript cannot do it — though a session genuinely blocked on a prompt now
  /// usually reports `.waiting` before this ever fires.
  var isBestEffort: Bool { self == .runningTool }

  /// Mid-turn, so closing now would stop work part-way. What `armada_close_session` refuses
  /// without `force` and what Armada asks about before closing.
  ///
  /// Not `.waiting`: a session stopped at a prompt is doing nothing that a close interrupts.
  var isBusy: Bool { self == .working || self == .runningTool }

  /// The registry's vocabulary, or nil for an absent or unrecognised status.
  ///
  /// Nil rather than a default: an unknown string is a Claude Code that has grown a
  /// state this app has never seen, and falling back to the transcript inference is a
  /// better answer than picking one of these four at random.
  init?(registryStatus: String?) {
    switch registryStatus {
    case "busy": self = .working
    case "waiting": self = .waiting
    case "idle": self = .idle
    default: return nil
    }
  }

  /// The state to show, from what the registry reports and what just happened.
  ///
  /// **The registry's answer wins wherever it has one.** A transcript write is only
  /// evidence of work on a build that reports no status; on one that does, the write
  /// and the registry rewrite arrive through the same FSEvents stream, so the write is
  /// not fresher. `busy` is refined by the transcript, the one thing the registry cannot
  /// say: whether the newest entry is an unanswered `tool_use`.
  ///
  /// `awaitingTool` is a closure because answering it can cost a tail read, and most
  /// states never ask.
  static func resolve(
    reported: SessionState?, wrote: Bool, hasTranscript: Bool, awaitingTool: () -> Bool
  ) -> SessionState {
    if let reported {
      guard reported == .working, hasTranscript else { return reported }
      return awaitingTool() ? .runningTool : .working
    }
    if wrote { return .working }
    guard hasTranscript else { return .idle }
    return awaitingTool() ? .runningTool : .idle
  }
}
