import Foundation

/// How big a session's context window is, and how confident that answer is.
///
/// **Nothing on disk states it.** Claude Code looks the size up from the model at
/// runtime, and the transcript records neither the size nor — the trap here —
/// a model id precise enough to derive it: `message.model` reads `claude-opus-5`
/// whether the session is a 200k one or a 1M one. Measured on 2026-09-12, every
/// distinct `message.model` across every transcript on this Mac was a bare id, while
/// the same machine's `settings.json` held `"opus[1m]"`.
///
/// So the size is resolved from whichever source is available, best first, and the
/// resolution carries its own provenance so the UI can say which one answered rather
/// than presenting a guess and a measurement identically.
nonisolated struct ContextWindow: Sendable, Hashable {
  let limit: Int
  let source: Source

  /// Where the size came from, worst consequences last.
  enum Source: Sendable, Hashable {
    /// The session's own `attachment` / `model` entry. Exact, and rare.
    case sessionModel(String)
    /// The account's configured default. Right until a session runs `/model`.
    case accountDefault(String)
    /// `message.model` against the table below, with no variant information.
    case assumed(String)
    /// Nothing identified the model.
    case unknown
    /// The session's own usage exceeded every limit above, so the window is at least
    /// this big whatever the other sources claimed.
    case observed

    var explanation: String {
      switch self {
      case .sessionModel(let id):
        "This session recorded its model as \(id)."
      case .accountDefault(let id):
        "Assumed from this account's configured model, \(id). A session that changed "
          + "model with /model would have a different window."
      case .assumed(let id):
        "Assumed from \(id). Claude Code does not record the context window size, and "
          + "the model id in a transcript does not distinguish a 1M session from a 200k one."
      case .unknown:
        "No model was recorded for this session, so this is the default window size."
      case .observed:
        "This session's context already exceeds the window its model normally has, so "
          + "it must be running on a larger one."
      }
    }
  }

  /// The model id to show, or nil to fall back to what the transcript recorded.
  ///
  /// **Only the session's own record, never the account's.** `settings.json` holds an
  /// alias like `opus[1m]`, which carries the variant this type exists to resolve but
  /// describes the account default rather than this session — putting it where a
  /// reader expects "the model this session is running" would state a guess as a
  /// fact. The window size it produced is still shown, with `source.explanation` on
  /// the tooltip saying where it came from, and the `1.0M` in the headline is the
  /// part that variant actually changes.
  var displayModelID: String? {
    if case .sessionModel(let id) = source { return id }
    return nil
  }

  static let fallbackLimit = 200_000
  static let extendedLimit = 1_000_000

  /// The window for a model id.
  ///
  /// Deliberately shallow: the `[1m]` suffix is the only thing in an id that changes
  /// the answer today, and every current model is 200k without it. A table of exact
  /// ids would need editing on every model release and would fail closed on an id it
  /// had never seen — this fails open to the common case instead.
  static func limit(forModelID id: String) -> Int {
    id.contains("[1m]") ? extendedLimit : fallbackLimit
  }

  /// Resolve the window, then correct it against what the session has actually used.
  ///
  /// - Parameters:
  ///   - sessionModelID: from the session's `attachment` / `model` entry, if it has one.
  ///   - accountModelID: the account's `settings.json` `.model`.
  ///   - messageModelID: `message.model` from the newest assistant turn.
  ///   - observedTotal: the session's current context, which is a *floor* on the window.
  ///
  /// The floor is what stops the bar rendering past full. A 1M session whose model
  /// attachment is missing resolves to 200k from the table and then reads 389k — at
  /// which point the table is simply wrong about this session, and the reading is the
  /// thing that was measured.
  static func resolve(
    sessionModelID: String?,
    accountModelID: String?,
    messageModelID: String?,
    observedTotal: Int
  ) -> ContextWindow {
    var resolved: ContextWindow =
      if let id = sessionModelID {
        ContextWindow(limit: limit(forModelID: id), source: .sessionModel(id))
      } else if let id = accountModelID {
        ContextWindow(limit: limit(forModelID: id), source: .accountDefault(id))
      } else if let id = messageModelID {
        ContextWindow(limit: limit(forModelID: id), source: .assumed(id))
      } else {
        ContextWindow(limit: fallbackLimit, source: .unknown)
      }

    if observedTotal > resolved.limit {
      resolved = ContextWindow(
        limit: max(extendedLimit, observedTotal), source: .observed)
    }
    return resolved
  }
}
