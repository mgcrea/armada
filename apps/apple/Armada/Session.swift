import Foundation
import SwiftUI

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

  /// The newest compaction: the deep scan's, or one made since and found in what the
  /// transcript gained (see `TranscriptContext.compactionAppended`).
  var compaction: Compaction?

  /// Where the next look for a compaction starts. Nil until the deep scan has run.
  var compactionThrough: UInt64?

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
