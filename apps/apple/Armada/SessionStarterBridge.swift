import ArmadaMCP
import Foundation

/// `armada_start_session`'s door into the app: one main-actor hop that finds the project and the
/// account, and asks the launcher.
///
/// **Checks again what the tool already checked.** The tool found the project in a snapshot and
/// vetted the message, but the project can be removed and its folder moved between that
/// snapshot and this hop, and this is the side that opens the terminal.
///
/// **Throttled.** One launch per `throttle` seconds from agents, so a supervisor caught in a
/// loop opens one window and is told to wait rather than filling the screen.
nonisolated struct SessionStarterBridge: SessionStarter {
  static let throttle: TimeInterval = 10

  func startSession(_ request: StartSessionRequest) async -> StartSessionOutcome {
    await MainActor.run { Self.start(request, now: Date()) }
  }

  @MainActor
  static func start(_ request: StartSessionRequest, now: Date) -> StartSessionOutcome {
    guard EntitlementMonitor.shared.current.isEntitled else {
      return .refused("Armada has no licence and no trial running, so it starts nothing.")
    }
    let store = ProjectStore.shared
    guard let project = store.project(id: request.projectID) else {
      return .refused("That project is no longer saved in Armada.")
    }
    guard store.folderExists(project) else {
      return .refused("\(project.displayPath) is not there any more.")
    }
    if let prompt = request.prompt, let refusal = Tools.promptRefusal(prompt) {
      return .refused(refusal)
    }

    let (resolved, refusal) = agent(for: request, project: project)
    guard let agent = resolved else {
      return .refused(refusal ?? "Armada could not tell which account to start on.")
    }

    let launcher = NewSessionLauncher.shared
    if let last = launcher.lastAgentLaunchAt, now.timeIntervalSince(last) < throttle {
      return .refused(
        "An agent started a session \(Int(now.timeIntervalSince(last))) seconds ago. Wait a "
          + "moment before starting another.")
    }
    if let message = launcher.startForAgent(agent, in: project.url, prompt: request.prompt) {
      return .refused(message)
    }

    let (vendor, accountID): (String, String) =
      switch agent {
      case .claude(let folder): ("claude", folder.path)
      case .codex(let home): ("codex", home.id)
      }
    let account =
      Accounts.shared.account(id: accountID)?.displayName
      ?? CodexAccounts.shared.account(id: accountID)?.displayName ?? accountID
    return .started(
      StartedSession(
        project: project.displayName, path: project.path, vendor: vendor, accountID: accountID,
        account: account, terminal: launcher.terminal.name, withPrompt: request.prompt != nil))
  }

  /// The agent to launch: the account named, else the project's own when the vendor matches,
  /// else that vendor's first account. Always a live account's own folder or home — see
  /// `ProjectStore.resolve` for why a stored id is never rebuilt into one.
  @MainActor
  private static func agent(for request: StartSessionRequest, project: Project) -> (
    NewSession.Agent?, String?
  ) {
    let projectVendor =
      switch project.agent {
      case .claude: "claude"
      case .codex: "codex"
      }
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
