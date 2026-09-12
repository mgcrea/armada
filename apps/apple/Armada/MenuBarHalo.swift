import Foundation

/// What lights the halo around the menu bar glyph.
///
/// A separate axis from the fill, and deliberately so. The rig has been filled
/// while something is working since before this existed, and that stays what it
/// means; the halo answers the louder question — *is anything asking for me* —
/// which is the one you want answered from across the room, and which only the
/// person using Armada can decide the shape of.
///
/// **The ladder is ordered by how much guessing each rung does**, because none of
/// the vendors publish the state this really wants. Claude Code and Codex both
/// leave "waiting for you" to be inferred, and they leave it to be inferred from
/// opposite halves of the record — see `SessionState` and `CodexSessionState`.
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
  /// The above, plus a Claude session whose newest entry is an unanswered
  /// `tool_use`.
  ///
  /// Catches most of the moments Claude is actually blocked on a permission
  /// prompt — and also every long-running tool that nobody needs to answer,
  /// because the transcript has no field that tells those apart. See
  /// `TranscriptTitle.isAwaitingToolResult`.
  case blocked
  /// The above, plus a Codex session holding its lock with the turn finished.
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
    case .blocked: "…or a tool is waiting for approval"
    case .waiting: "…or any session is waiting on me"
    }
  }

  /// Whether the halo should be lit, given what both vendors currently show.
  ///
  /// Takes the counts rather than the stores so this stays a pure function of the
  /// four numbers — it is the one piece of this feature worth being able to reason
  /// about without a running app.
  func isLit(
    claudeWorking: Int, claudeAwaitingTool: Int, codexWorking: Int, codexAwaitingInput: Int
  ) -> Bool {
    switch self {
    case .never: false
    case .working: claudeWorking > 0 || codexWorking > 0
    case .blocked: claudeWorking > 0 || codexWorking > 0 || claudeAwaitingTool > 0
    case .waiting:
      claudeWorking > 0 || codexWorking > 0 || claudeAwaitingTool > 0 || codexAwaitingInput > 0
    }
  }
}
