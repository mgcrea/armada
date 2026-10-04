import Foundation

/// Whether Armada keeps the Mac from idle-sleeping while an agent is working.
///
/// **What `caffeinate` does, held on a condition rather than a timer or a PID.**
/// `caffeinate -i` keeps the Mac up for as long as you guessed; this keeps it up for
/// as long as a session is actually producing something, and lets it go the moment
/// the last one stops. Armada is the one app on the machine that knows that — an MCP
/// supervisor only sees tool calls, and a long turn is mostly the model thinking or a
/// Bash command running, neither of which goes through one.
///
/// **Idle sleep only, never forced awake.** Both rungs hold an assertion against the
/// *idle* timer: closing the lid still sleeps the Mac, as does choosing Sleep, and on
/// battery that is what you want. Cupertino measured `.idleSystemSleepDisabled`
/// registering as `PreventUserIdleSystemSleep` — `caffeinate -i` — and that it holds
/// on battery; see its `SoundCapture.swift`.
///
/// **Off by default**, because changing when somebody's Mac sleeps is not a thing an
/// update should start doing on its own.
enum KeepAwake: String, CaseIterable, Sendable {
  case off
  /// `caffeinate -i`: the Mac stays up, the display still dims, sleeps and locks.
  case system
  /// `caffeinate -di`: the display stays lit too. For someone watching the work from
  /// across the room, or driving a desktop agent that needs an unlocked screen.
  case display

  static let defaultsKey = "armada.keepAwake"

  /// How long a Claude session on an unanswered `tool_use` still counts.
  ///
  /// `.runningTool` is a guess — a long build as often as a permission prompt on a
  /// build of Claude Code too old to report `waiting` — and the cost of guessing wrong
  /// here is a Mac kept up all night for a prompt nobody will answer. An hour covers
  /// every test suite and archive in the fleet; a tool still running after that is
  /// left to the idle timer. `.working` gets no cap: it is a write inside the idle
  /// threshold, and a write is evidence that something is moving now.
  static let toolCallCap: TimeInterval = 60 * 60

  var label: String {
    switch self {
    case .off: "Never"
    case .system: "While a session is working"
    case .display: "…and keep the display on"
    }
  }

  /// The assertion this rung takes while something is working, or nil for none.
  var options: ProcessInfo.ActivityOptions? {
    switch self {
    case .off: nil
    case .system: .idleSystemSleepDisabled
    case .display: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled]
    }
  }

  /// Whether anything is working, by the rule above.
  ///
  /// Takes counts and dates rather than the stores, as `MenuBarHalo.isLit` does, so it
  /// is a pure function the unit checks can reach. `claudeToolCalls` is each
  /// `.runningTool` session's last transcript write: the moment the `tool_use` landed.
  /// A session with no write to date it from does not count — it cannot be aged.
  /// Codex and Grok Build write both edges of a turn, so their `working` is a fact and
  /// needs no cap. `.waiting` and every vendor's open-but-idle state count for nothing:
  /// a session stopped on you is exactly the one that should not keep the Mac up.
  static func isWorking(
    claudeWriting: Int, claudeToolCalls: [Date?], codexWorking: Int, grokWorking: Int,
    now: Date
  ) -> Bool {
    if claudeWriting > 0 || codexWorking > 0 || grokWorking > 0 { return true }
    return claudeToolCalls.contains { started in
      guard let started else { return false }
      return now.timeIntervalSince(started) < toolCallCap
    }
  }
}
