import Foundation

/// Acting on several sessions at once: the parts that are words and arithmetic, kept apart from
/// the app so `make unit` can check them. The actions themselves are `SessionBatchActions`.
///
/// **One sentence for the whole batch.** The single-session actions each put up an alert when
/// something goes wrong, and eight of those in a row, each replacing the last, would be worse
/// than none: the person would read one refusal and lose seven. A batch collects what did not go
/// through and says it once, naming each session.
nonisolated enum SessionBatch {
  /// Something one session in a batch did not do, and why.
  struct Refusal: Equatable, Sendable {
    let name: String
    let reason: String
  }

  /// "1 session", "3 sessions".
  static func sessions(_ count: Int) -> String {
    count == 1 ? "1 session" : "\(count) sessions"
  }

  /// "Session" or "Sessions", for a button that already says how many.
  static func noun(_ count: Int) -> String {
    count == 1 ? "Session" : "Sessions"
  }

  /// What a copy on another account should be called, or nil to leave it to Claude Code.
  ///
  /// **The name the original shows**, so a batch of copies arrives as rows someone can tell
  /// apart. A fork carries no title of its own (see `docs/claude-code-sessions.md`), and eight
  /// untitled rows under the new account were the price of moving eight sessions.
  ///
  /// **Not a name Claude Code derived from the folder**: it would come back derived again, and
  /// passing it would turn a default into a name somebody seems to have chosen.
  static func carriedName(title: String?, registryName: String?, nameSource: String?) -> String? {
    if let title = trimmed(title) { return title }
    guard nameSource != "derived" else { return nil }
    return trimmed(registryName)
  }

  /// One line for one refusal, naming the session unless the reason opens with its name.
  ///
  /// **Opens with, not contains.** The refusals that name their session all lead with it
  /// ("<name> started a turn as you closed it"), and a short name such as "A" is contained in
  /// half the sentences Armada writes.
  static func line(for refusal: Refusal) -> String {
    refusal.reason.hasPrefix(refusal.name + " ")
      ? refusal.reason : "\(refusal.name): \(refusal.reason)"
  }

  /// What to tell the person after a batch, or nil when every session went through.
  ///
  /// `verb` is the past participle the headline uses ("moved", "closed"). A reason several
  /// sessions share is said once, after all their names: one that is not about any session in
  /// particular, such as the licence, would otherwise repeat for every row.
  static func report(verb: String, attempted: Int, refusals: [Refusal]) -> String? {
    guard !refusals.isEmpty else { return nil }
    let done = max(0, attempted - refusals.count)
    let headline =
      done == 0
      ? (attempted == 1
        ? "The session was not \(verb)." : "None of the \(attempted) sessions were \(verb).")
      : "\(done) of \(attempted) sessions were \(verb)."
    var reasons: [String] = []
    var names: [String: [String]] = [:]
    for refusal in refusals {
      if names[refusal.reason] == nil { reasons.append(refusal.reason) }
      names[refusal.reason, default: []].append(refusal.name)
    }
    let lines = reasons.map { reason in
      let sharing = names[reason] ?? []
      return sharing.count == 1
        ? line(for: Refusal(name: sharing[0], reason: reason))
        : "\(sharing.joined(separator: ", ")): \(reason)"
    }
    return ([headline, ""] + lines).joined(separator: "\n")
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}
