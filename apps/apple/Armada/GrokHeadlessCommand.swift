import Foundation

/// The command line and environment of a headless Grok Build turn, kept apart from the runner
/// (`GrokHeadless`) so the unit checks can read them.
///
/// **Nobody is there to answer a permission prompt, and Grok's default answer is yes.** In
/// headless `default` mode a prompt is answered with the row the TUI would preselect, which is
/// `allow_once` unless `[ui] default_selected_permission` or `GROK_DEFAULT_SELECTED_PERMISSION`
/// says otherwise (Grok's user guide, 05-configuration.md, grok 1.0.77). So a plain `grok -p`
/// would approve every edit and command it asked about. Instead:
///
/// - `--permission-mode dontAsk`: "only pre-approved tools and built-in read-only handling"
///   (22-permissions-and-safety.md). The turn can read, search and run the read-only commands
///   Grok lists, and do what the person's own allow rules (`~/.grok/config.toml`, a project's
///   `.grok/config.toml`, `.claude/settings.json`) already permit. Everything else is denied.
/// - `GROK_DEFAULT_SELECTED_PERMISSION=reject`, so that if some path still reaches a prompt, the
///   preselected answer is no.
///
/// The person's Claude-compatible hooks stay on. Armada's own delivery hook used to hold a
/// headless turn open (docs/grok-sessions.md); it now exits at once inside Grok, and turning
/// hooks off would turn off the person's own safety hooks with it.
///
/// The prompt goes in a file (`--prompt-file`), never on the command line, as it does for a
/// terminal launch (`LaunchScript.promptLines`).
nonisolated enum GrokHeadlessCommand {
  enum Start: Equatable {
    /// A new session under an id Armada minted (`--session-id`).
    case fresh(sessionID: String)
    /// The next turn of a session that exists (`--resume`).
    case resume(sessionID: String)

    var sessionID: String {
      switch self {
      case .fresh(let id), .resume(let id): id
      }
    }
  }

  static func arguments(start: Start, promptFile: String, cwd: String, model: String?)
    -> [String]
  {
    var arguments = [
      "--prompt-file", promptFile, "--cwd", cwd, "--permission-mode", "dontAsk",
    ]
    switch start {
    case .fresh(let id): arguments += ["--session-id", id]
    case .resume(let id): arguments += ["--resume", id]
    }
    // One word, so an id that begins with a dash cannot become a flag.
    if let model { arguments.append("--model=" + model) }
    return arguments
  }

  /// `base` is the person's login environment, so the turn's shell tools find what a terminal
  /// would. The default home is unset rather than exported, as for a terminal launch
  /// (`NewSession.accountLines`), so a profile's `GROK_HOME` cannot redirect it.
  static func environment(base: [String: String], homePath: String, isDefault: Bool)
    -> [String: String]
  {
    var environment = base
    if isDefault {
      environment.removeValue(forKey: "GROK_HOME")
    } else {
      environment["GROK_HOME"] = homePath
    }
    environment["GROK_DEFAULT_SELECTED_PERMISSION"] = "reject"
    return environment
  }

  /// A sentence from what a turn that failed straight away printed: "Not signed in" exits in
  /// 0.2 s with the reason on stderr (grok 1.0.77, measured 2026-11-15).
  static func failure(stderr: String, status: Int32) -> String {
    let lines = stderr.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    // Plain output prints the reason bare; `--output-format json` puts "Error: " in front.
    let marked = lines.firstIndex { $0.hasPrefix("Error:") }
    guard let index = marked ?? (lines.isEmpty ? nil : 0) else {
      return "Grok Build stopped at once, with status \(status), and said nothing."
    }
    var reason = marked != nil ? String(lines[index].dropFirst(6)) : lines[index]
    // "…, run:" is followed by the command to run, which is the useful half.
    if reason.hasSuffix(":"), index + 1 < lines.count {
      reason += " " + lines[index + 1]
    }
    guard !reason.isEmpty else {
      return "Grok Build stopped at once, with status \(status), and said nothing."
    }
    return "Grok Build stopped at once: \(reason.trimmingCharacters(in: .whitespaces))"
  }
}
