import SwiftUI

/// Everything a fork needs, and the one place that decides whether there is one.
///
/// Three surfaces offer this — the detail pane, a row's context menu and the menu bar
/// popover — and the guards below are why they cannot disagree about which rows are
/// forkable. A row that offers the action in one place and not another reads as a bug
/// in the row rather than as a rule about the session.
nonisolated struct ForkTarget: Hashable, Sendable {
  let agent: NewSession.Agent
  let project: URL
  let sessionID: String

  /// What the fork costs, for the one surface with room to say it.
  ///
  /// The two vendors genuinely differ here and the sentence follows them rather than
  /// splitting the difference: Claude Code records nothing linking a fork to its
  /// original — the same fact `Session.untitledReason` already has to explain — while
  /// Codex writes `forked_from_id` into the new rollout's `session_meta`.
  let note: String

  var start: NewSession.Start { .fork(sessionID: sessionID) }
}

/// A fork, or the sentence explaining why this row has none.
///
/// Modelled on `FocusButton`'s rule rather than on a disabled control: a button nobody
/// can press says only that the app wanted one there, and the interesting half is why.
enum ForkAvailability {
  case available(ForkTarget)
  case unavailable(String)

  var target: ForkTarget? {
    if case .available(let target) = self { return target }
    return nil
  }

  /// **Only a session that has been prompted can be forked.** `--resume` resolves the
  /// id against a transcript in the project's folder, and a session nobody has typed
  /// at yet has no transcript at all — the case the "No title" section already
  /// describes. Liveness is deliberately not a condition: forking the session someone
  /// is sitting in front of is the ordinary use, and `--fork-session` is what makes it
  /// safe.
  @MainActor
  static func claude(_ session: Session, in account: Account) -> ForkAvailability {
    guard session.transcript != nil else {
      return .unavailable(
        "This session has never been prompted, so there is no conversation to fork.")
    }
    guard !session.registry.cwd.isEmpty else {
      return .unavailable("This session records no folder, so there is nowhere to open a fork.")
    }
    return .available(
      ForkTarget(
        agent: .claude(account.folder),
        project: URL(filePath: session.registry.cwd, directoryHint: .isDirectory),
        sessionID: session.registry.sessionId,
        note:
          "Claude Code opens a copy in a terminal and this session keeps running, untouched. The copy gets a new session id and no recorded link back, so it arrives in the list as a separate, untitled row."
      ))
  }

  /// **A subagent is not a thread anyone forks by hand.** `CodexSessionMeta` records
  /// how easily subagent identity is read wrong; the honest answer for a
  /// `guardian_review` row is to point at the thread that spawned it.
  ///
  /// An `ended` session is forkable and that is not an oversight: `codex fork` reads
  /// the rollout from disk, so the session having no process left is no obstacle.
  @MainActor
  static func codex(_ session: CodexSession, in account: CodexAccount) -> ForkAvailability {
    guard !session.isSubagent else {
      return .unavailable(
        "A spawned subagent is not a thread to fork. Fork the thread that started it instead.")
    }
    guard !session.meta.cwd.isEmpty else {
      return .unavailable(
        "This session's log records no folder, so there is nowhere to open a fork.")
    }
    return .available(
      ForkTarget(
        agent: .codex(account.home),
        project: URL(filePath: session.meta.cwd, directoryHint: .isDirectory),
        sessionID: session.id,
        note:
          "Codex opens a copy in a terminal and this session is not touched. It records this session as the copy's parent, so the fork can be traced back here."
      ))
  }
}

extension ForkAvailability {
  /// `grok --resume <id> --fork-session` reads `updates.jsonl`, so a session opened and never
  /// prompted has nothing to copy. An ended session forks like a live one, as with Codex.
  @MainActor
  static func grok(_ session: GrokSession, in account: GrokAccount) -> ForkAvailability {
    let updates = session.directory.appending(path: "updates.jsonl", directoryHint: .notDirectory)
    guard session.scannedSize > 0
      || FileManager.default.fileExists(atPath: updates.path(percentEncoded: false))
    else {
      return .unavailable(
        "This session has never been prompted, so there is no conversation to fork.")
    }
    guard !session.summary.cwd.isEmpty else {
      return .unavailable("This session records no folder, so there is nowhere to open a fork.")
    }
    return .available(
      ForkTarget(
        agent: .grok(account.home),
        project: URL(filePath: session.summary.cwd, directoryHint: .isDirectory),
        sessionID: session.id,
        note:
          "Grok Build opens a copy in a terminal and this session is not touched. It records this session as the copy's parent."
      ))
  }
}

/// "Fork Session", or why this one cannot be.
///
/// **"Fork" is both vendors' own word** — `--fork-session`, `codex fork`, and Codex's
/// `/fork` command — which is the rule `SessionState` sets out: keep the vocabulary the
/// vendor uses rather than invent a friendlier one that means something slightly else.
/// "Duplicate" or "Branch" would each be a promise about what happens to the original.
struct ForkButton: View {
  let availability: ForkAvailability

  var body: some View {
    switch availability {
    case .available(let target):
      Button {
        NewSessionLauncher.shared.start(target.agent, in: target.project, start: target.start)
      } label: {
        Label("Fork Session", systemImage: "arrow.triangle.branch")
      }
      Text(target.note)
        .font(.caption)
        .foregroundStyle(.secondary)
    case .unavailable(let reason):
      Text(reason)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
