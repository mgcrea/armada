import ArmadaMCP
import Foundation

/// `armada_start_session`'s door into the app: one main-actor hop that finds the project and the
/// account, and asks the launcher.
///
/// **Checks again what the tool already checked.** The tool found the project in a snapshot and
/// vetted the message, but the project can be removed and its folder moved between that
/// snapshot and this hop, and this is the side that opens the terminal or VS Code.
///
/// **Throttled.** One launch per `throttle` seconds from agents, so a supervisor caught in a
/// loop opens one window and is told to wait rather than filling the screen.
///
/// **Names the session when it can.** A fresh Claude Code session bound for a terminal gets an id
/// minted here and passed as `--session-id`, so the agent can watch or close exactly the session
/// it started. Grok Build takes the same (`--session-id`). VS Code opens its tab through the
/// extension's link, which takes no id, and Codex has no such flag; both still come back without one.
///
/// **Resumes only what nothing has open.** See `resume`.
nonisolated struct SessionStarterBridge: SessionStarter {
  static let throttle: TimeInterval = 10
  /// A transcript written this recently may belong to a session Armada does not watch — one over
  /// ssh, or on a folder it has not discovered — so it is not resumed.
  static let recentWrite: TimeInterval = 30
  func startSession(_ request: StartSessionRequest) async -> StartSessionOutcome {
    await MainActor.run { Self.start(request, now: Date()) }
  }

  @MainActor
  static func start(_ request: StartSessionRequest, now: Date) -> StartSessionOutcome {
    guard EntitlementMonitor.shared.current.isEntitled else {
      return .refused("Armada has no licence and no trial running, so it starts nothing.")
    }
    if let prompt = request.prompt, let refusal = Tools.promptRefusal(prompt) {
      return .refused(refusal)
    }
    if let id = request.resume {
      if request.vendor == "grok" { return resumeGrok(id, prompt: request.prompt, now: now) }
      return resume(id, prompt: request.prompt, now: now, fallBackToGrok: request.vendor == nil)
    }

    let store = ProjectStore.shared
    guard let projectID = request.projectID, let project = store.project(id: projectID) else {
      return .refused("That project is no longer saved in Armada.")
    }
    guard store.folderExists(project) else {
      return .refused("\(project.displayPath) is not there any more.")
    }

    let (resolved, refusal) = agent(for: request, project: project)
    guard let agent = resolved else {
      return .refused(refusal ?? "Armada could not tell which account to start on.")
    }

    let launcher = NewSessionLauncher.shared
    if let refusal = throttled(now) { return .refused(refusal) }
    let sessionID: String?
    let start: NewSession.Start
    let takesID =
      switch agent {
      case .claude: !launcher.opensInVSCode(agent)
      case .grok: true
      case .codex: false
      }
    if takesID {
      let minted = UUID().uuidString.lowercased()
      sessionID = minted
      start = .identified(sessionID: minted)
    } else {
      sessionID = nil
      start = .fresh
    }
    if let message = launcher.startForAgent(
      agent, in: project.url, start: start, prompt: request.prompt)
    {
      return .refused(message)
    }

    let (vendor, accountID): (String, String) =
      switch agent {
      case .claude(let folder): ("claude", folder.path)
      case .codex(let home): ("codex", home.id)
      case .grok(let home): ("grok", home.id)
      }
    let account =
      Accounts.shared.account(id: accountID)?.displayName
      ?? CodexAccounts.shared.account(id: accountID)?.displayName
      ?? GrokAccounts.shared.account(id: accountID)?.displayName ?? accountID
    return .started(
      StartedSession(
        project: project.displayName, path: project.path, vendor: vendor, accountID: accountID,
        account: account, terminal: launcher.destinationName(for: agent),
        withPrompt: request.prompt != nil,
        promptAwaitsSend: request.prompt != nil && launcher.opensInVSCode(agent)
          && !VSCodeLaunch.sendsPrompt,
        sessionID: sessionID))
  }

  @MainActor
  private static func throttled(_ now: Date) -> String? {
    guard let last = NewSessionLauncher.shared.lastAgentLaunchAt,
      now.timeIntervalSince(last) < throttle
    else { return nil }
    return "An agent started a session \(Int(now.timeIntervalSince(last))) seconds ago. Wait a "
      + "moment before starting another."
  }

  /// Continue a Claude Code session in a terminal, in the folder it ran in, on the account whose
  /// folder holds its transcript.
  ///
  /// **Never one that is open.** The checks are `SessionResume.prepare`'s, shared with Resume in
  /// the Projects pane; what is the agent's own is the wording, the throttle and the opening
  /// message.
  @MainActor
  private static func resume(
    _ id: String, prompt: String?, now: Date, fallBackToGrok: Bool
  ) -> StartSessionOutcome {
    let account: Account
    let cwd: String
    let project: Project
    switch SessionResume.prepare(id, now: now) {
    case .ready(let target):
      (account, cwd, project) = (target.account, target.cwd, target.project)
    case .refused(.live(let live)):
      return .refused(
        "\(live.displayName) is still open in \(live.registry.projectName). Close it with "
          + "armada_close_session first, or start a fresh session.")
    case .refused(.noTranscript):
      // An id with no vendor named is looked for in Grok Build too: both mint UUIDs, and an
      // agent resuming a session it read from the fleet should not have to know which kind.
      if fallBackToGrok,
        GrokAccounts.shared.all.contains(where: { $0.home.sessionDirectory(id: id) != nil })
      {
        return resumeGrok(id, prompt: prompt, now: now)
      }
      return .refused("No Claude Code account on this Mac has a transcript for session \(id).")
    case .refused(.recentWrite(let seconds)):
      return .refused(
        "Session \(id) wrote to its transcript \(seconds) seconds ago, so something may still "
          + "have it open. Try again in a minute.")
    case .refused(.noFolder):
      return .refused("Session \(id)'s transcript records no folder to resume it in.")
    case .refused(.notInProject(let cwd)):
      return .refused(
        "Session \(id) ran in \((cwd as NSString).abbreviatingWithTildeInPath), which is not in "
          + "a saved project. Only sessions in saved projects are resumed.")
    case .refused(.folderGone(let cwd)):
      return .refused("\((cwd as NSString).abbreviatingWithTildeInPath) is not there any more.")
    }

    if let refusal = throttled(now) { return .refused(refusal) }
    let launcher = NewSessionLauncher.shared
    let agent = NewSession.Agent.claude(account.folder)
    if let message = launcher.startForAgent(
      agent, in: URL(filePath: cwd, directoryHint: .isDirectory), start: .resume(sessionID: id),
      prompt: prompt)
    {
      return .refused(message)
    }
    return .started(
      StartedSession(
        project: project.displayName, path: cwd, vendor: "claude", accountID: account.folder.path,
        account: account.displayName, terminal: launcher.terminal.name,
        withPrompt: prompt != nil, sessionID: id, resumed: true))
  }

  /// Continue a Grok Build session, under `resume`'s three checks.
  ///
  /// Open means listed as live by the watcher, or in `active_sessions.json` with a live pid, which
  /// the watcher's state already reflects within a sweep; `recentWrite` covers the sweep's gap and a
  /// headless `grok -p` that no list names. The folder is `summary.json`'s.
  @MainActor
  private static func resumeGrok(_ id: String, prompt: String?, now: Date) -> StartSessionOutcome {
    let homes = GrokAccounts.shared.all
    for account in homes {
      if let live = account.sessions.sessions.first(where: { $0.id == id }), live.state.isLive {
        return .refused(
          "\(live.displayName) is still open in \(live.summary.projectName). Close it first, or "
            + "start a fresh session.")
      }
    }
    guard
      let (account, directory) = homes.lazy.compactMap({ account in
        account.home.sessionDirectory(id: id).map { (account, $0) }
      }).first
    else {
      return .refused("No Grok Build home on this Mac has session \(id).")
    }

    let updates = directory.appending(path: "updates.jsonl").path(percentEncoded: false)
    if let modified = try? FileManager.default.attributesOfItem(atPath: updates)[.modificationDate]
      as? Date, now.timeIntervalSince(modified) < recentWrite
    {
      return .refused(
        "Session \(id) wrote to its log \(max(0, Int(now.timeIntervalSince(modified)))) seconds "
          + "ago, so something may still have it open. Try again in a minute.")
    }
    guard
      let summary = (try? Data(contentsOf: directory.appending(path: "summary.json")))
        .flatMap(GrokFiles.summary), !summary.cwd.isEmpty
    else {
      return .refused("Session \(id) records no folder to resume it in.")
    }
    let cwd = summary.cwd
    guard let project = ProjectStore.shared.project(containing: cwd) else {
      return .refused(
        "Session \(id) ran in \((cwd as NSString).abbreviatingWithTildeInPath), which is not in "
          + "a saved project. Only sessions in saved projects are resumed.")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .refused("\((cwd as NSString).abbreviatingWithTildeInPath) is not there any more.")
    }

    if let refusal = throttled(now) { return .refused(refusal) }
    let launcher = NewSessionLauncher.shared
    if let message = launcher.startForAgent(
      .grok(account.home), in: URL(filePath: cwd, directoryHint: .isDirectory),
      start: .resume(sessionID: id), prompt: prompt)
    {
      return .refused(message)
    }
    return .started(
      StartedSession(
        project: project.displayName, path: cwd, vendor: "grok", accountID: account.id,
        account: account.displayName, terminal: launcher.terminal.name,
        withPrompt: prompt != nil, sessionID: id, resumed: true))
  }

  /// The agent to launch: the account named, else the project's own when the vendor matches,
  /// else that vendor's first account. Always a live account's own folder or home — see
  /// `ProjectStore.resolve` for why a stored id is never rebuilt into one.
  @MainActor
  private static func agent(for request: StartSessionRequest, project: Project) -> (
    NewSession.Agent?, String?
  ) {
    let projectVendor = project.agent.vendorKey
    let vendor = request.vendor ?? projectVendor

    if let query = request.account?.trimmingCharacters(in: .whitespacesAndNewlines),
      !query.isEmpty
    {
      let lowered = query.lowercased()
      if vendor == "codex" {
        let all = CodexAccounts.shared.all
        let matches = all.filter {
          $0.id.lowercased() == lowered || $0.displayName.lowercased() == lowered
        }
        guard matches.count == 1 else {
          return (nil, noAccount(query, vendor: "Codex home", names: all.map(\.displayName)))
        }
        return (.codex(matches[0].home), nil)
      }
      if vendor == "grok" {
        let all = GrokAccounts.shared.all
        let matches = all.filter {
          $0.id.lowercased() == lowered || $0.displayName.lowercased() == lowered
        }
        guard matches.count == 1 else {
          return (nil, noAccount(query, vendor: "Grok Build home", names: all.map(\.displayName)))
        }
        return (.grok(matches[0].home), nil)
      }
      let all = Accounts.shared.all
      let matches = all.filter {
        $0.id.lowercased() == lowered || $0.displayName.lowercased() == lowered
      }
      guard matches.count == 1 else {
        return (nil, noAccount(query, vendor: "Claude Code account", names: all.map(\.displayName)))
      }
      return (.claude(matches[0].folder), nil)
    }

    if vendor == projectVendor {
      guard let agent = ProjectStore.shared.resolve(project.agent) else {
        return (
          nil,
          "The account \(project.displayName) starts on is not on this Mac. Name another with "
            + "`account`."
        )
      }
      return (agent, nil)
    }
    if vendor == "codex" {
      guard let home = CodexAccounts.shared.all.first else {
        return (nil, "There is no Codex home on this Mac.")
      }
      return (.codex(home.home), nil)
    }
    if vendor == "grok" {
      guard let home = GrokAccounts.shared.all.first else {
        return (nil, "There is no Grok Build home on this Mac.")
      }
      return (.grok(home.home), nil)
    }
    guard let account = Accounts.shared.all.first else {
      return (nil, "There is no Claude Code account on this Mac.")
    }
    return (.claude(account.folder), nil)
  }

  private static func noAccount(_ query: String, vendor: String, names: [String]) -> String {
    let known =
      names.isEmpty ? "There is none on this Mac." : "Known: \(names.joined(separator: ", "))."
    return "No single \(vendor) matches \"\(query)\". \(known)"
  }
}
