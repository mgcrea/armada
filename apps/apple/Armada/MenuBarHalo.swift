import Foundation

/// What lights the halo around the menu bar glyph.
///
/// A separate axis from the fill, and deliberately so. The rig has been filled
/// while something is working since before this existed, and that stays what it
/// means; the halo answers the louder question — *is anything asking for me* —
/// which is the one you want answered from across the room, and which only the
/// person using Armada can decide the shape of.
///
/// **The ladder is ordered by how much guessing each rung does.** Claude Code now
/// publishes the state this really wants — the registry carries `status: "waiting"`
/// and names the reason in `waitingFor`, so the middle rung below is no longer a
/// guess on the Claude side. Codex still leaves it to be inferred, and from the
/// opposite half of the record — see `SessionState` and `CodexSessionState`.
/// Widening the halo buys earlier warning and pays for it in false positives, so
/// the rungs are named for what they actually watch rather than for how eager
/// they are.
enum MenuBarHalo: String, CaseIterable, Sendable {
  /// No halo, ever. The glyph still fills while something works.
  case never
  /// Something is producing output right now.
  ///
  /// The default, and the only rung that rests on nothing inferred: Codex writes
  /// both edges of a turn, so its `working` is a fact, and Claude's is a write to
  /// the transcript inside the idle threshold.
  case working
  /// The above, plus a Claude session that is stopped and wants something.
  ///
  /// **Mostly reported now, and much sharper than it used to be.** Claude Code
  /// writes `status: "waiting"` with a reason — a permission prompt, an open
  /// dialog, a sandbox request — and that is a fact, not a reading. The old
  /// inference is still folded in for a folder on an older build, and it is the
  /// part that over-fires: an unanswered `tool_use` is a long-running tool as
  /// often as a prompt. See `SessionState` and `Accounts.blockedSessionCount`.
  case blocked
  /// The above, plus a Codex or Grok Build session that is open with its turn finished.
  ///
  /// The widest rung and the least selective: `CodexSessionState.awaitingInput`
  /// means "the process is alive and not busy", which is every Codex session you
  /// have open and are not at this second typing into. If you leave sessions
  /// running, expect this halo to be lit most of the time.
  case waiting

  static let defaultsKey = "armada.menuBarHalo"

  /// The picker's rows. Phrased as what the halo will be doing, not as a setting
  /// name, because the difference between the middle two is the whole decision
  /// and a two-word label cannot carry it.
  var label: String {
    switch self {
    case .never: "Never"
    case .working: "While a session is working"
    case .blocked: "…or a session is waiting on me"
    case .waiting: "…or a Codex or Grok session is sitting at a finished turn"
    }
  }

  /// Whether the halo should be lit, given what both vendors currently show.
  ///
  /// Takes the counts rather than the stores so this stays a pure function of the
  /// four numbers — it is the one piece of this feature worth being able to reason
  /// about without a running app.
  func isLit(
    claudeWorking: Int, claudeBlocked: Int, codexWorking: Int, codexAwaitingInput: Int,
    grokWorking: Int = 0, grokAwaitingInput: Int = 0
  ) -> Bool {
    let working = claudeWorking > 0 || codexWorking > 0 || grokWorking > 0
    switch self {
    case .never: return false
    case .working: return working
    case .blocked: return working || claudeBlocked > 0
    case .waiting:
      return working || claudeBlocked > 0 || codexAwaitingInput > 0 || grokAwaitingInput > 0
    }
  }
}
