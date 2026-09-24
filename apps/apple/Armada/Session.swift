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
}

/// One session as Armada shows it: the registry row, plus everything inferred.
@Observable
final class Session: Identifiable {
  /// **Replaced on every rescan, not frozen at adoption.** The registry is a live
  /// document: Claude Code rewrites it whenever the session's status changes, so
  /// `status`, `waitingFor` and `updatedAt` all move within it. Holding the copy read
  /// when the row first appeared would pin every one of them to that instant.
  var registry: SessionRegistry

  /// Nil until a transcript is found — and permanently nil for a session that has
  /// never been prompted, which has no transcript file at all.
  var transcript: URL?

  /// The newest `custom-title`, or failing one the newest `ai-title` — see
  /// `TranscriptTitle.newestTitle`. Nil for never-prompted sessions, and for resumed ones:
  /// resuming mints a new `sessionId` and a transcript with no `ai-title` and no
  /// link back to the original.
  var title: String?

  var state: SessionState = .idle
  var lastWrite: Date?

  /// What this session is waiting for, when `state` is `.waiting`. Display text
  /// straight from the registry — see `SessionRegistry.waitingFor`.
  var waitingFor: String? { state == .waiting ? registry.waitingFor : nil }

  /// Whether this session looks like it wants you: `.waiting`, plus `.runningTool`.
  ///
  /// **One definition, read in three places that must agree** — the menu bar halo's
  /// count (`Accounts.blockedSessionCount`), the mouse button's "next waiting"
  /// (`MouseCommand.waiting()`), and the MCP server's `armada_needs_attention`. A
  /// supervisor that skipped a session the halo was lit for would read as broken, and
  /// so would a button that did. See `Accounts.blockedSessionCount` for why the reported
  /// state and the inferred one are counted together.
  var wantsAttention: Bool { state == .waiting || state == .runningTool }

  /// The newest rate-limit refusal seen in this session's transcript, if any.
  ///
  /// **Kept once seen, never cleared by a later read.** A refusal is a thing that
  /// happened, and the record scrolls out of the 64KB tail as the session carries
  /// on past it — re-reading and finding nothing means the tail has moved, not that
  /// the refusal was retracted. `QuotaHit.isLive` is what decides whether it still
  /// says anything about now.
  var quotaHit: QuotaHit?

  /// How full the context window is, as of the newest assistant turn in the tail.
  ///
  /// Nil for a session that has never been prompted, and for the moment between a
  /// session appearing and its first transcript read.
  var context: ContextReading?

  /// The turn before `context`. Kept for the compaction check below, which needs
  /// only a fall between two consecutive readings.
  var previousContext: ContextReading?

  /// The lifetime of the newest cache write seen, from this turn or an earlier one.
  ///
  /// **Kept once seen, like `sessionModelID`.** A turn that hits the cache in full
  /// writes nothing and so carries no lifetime, which is not the session changing
  /// lifetime; the newest turn that did write is the one that says.
  var cacheTTL: PromptCacheTTL?

  /// The prompt cache as of the newest turn, or nil when the lifetime is unknown.
  ///
  /// Nil for a session that is mid-turn: each request it makes resets the clock, so
  /// a countdown there would only ever describe the past.
  var promptCache: PromptCache? {
    guard !state.isBusy, let cacheTTL, let context, let at = context.at else { return nil }
    return PromptCache(ttl: cacheTTL, lastRequest: at, tokens: context.total)
  }

  /// How fast the window is filling, over the readings in the newest tail.
  var growth: ContextGrowth?

  /// What was loaded before the first prompt. Read once, from the head of the file.
  var baseline: ContextBaseline?

  /// The newest compaction found by the deep scan, if any.
  var compaction: Compaction?

  /// The model id with its variant suffix, from the session's own `model` attachment.
  /// Usually nil — see `TranscriptContext.newestModelID`.
  var sessionModelID: String?

  /// Whether the context has been compacted since `baseline` was read.
  ///
  /// A compaction is the only thing that makes the running total *fall* between
  /// turns, so the two readings in the tail detect one that happened long after the
  /// deep scan, with no re-read. It matters because it invalidates the arithmetic:
  /// "added since the start" is meaningless once the middle of the session has been
  /// thrown away, and the UI drops that row rather than showing a negative.
  var hasCompactedSinceBaseline: Bool {
    guard let context, let previousContext else { return false }
    return context.total < previousContext.total
  }

  /// File size at the last title read, so an unchanged file is not re-read and the
  /// expensive full-scan fallback is paid for at most once per size.
  var titleScannedSize: UInt64 = 0
  var didFullScan = false

  /// The transcript's size and modification date the last time its tail was asked
  /// whether it ends on an unanswered `tool_use`, and the answer. Ignored by
  /// observation: no view draws it. See `SessionWatcher.isAwaitingToolResult`.
  @ObservationIgnored var toolResultCheck: (size: UInt64, modified: Date, awaiting: Bool)?

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
