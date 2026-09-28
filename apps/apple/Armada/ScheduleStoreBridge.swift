import ArmadaMCP
import Foundation

/// The schedule tools' door into the app. See `ScheduleStore`.
///
/// Reads the disk off the main actor, after one main-actor hop for the accounts and the
/// entitlement, so a slow folder never stalls the window.
nonisolated struct ScheduleStoreBridge: ScheduleStore {
  func schedules() async -> SchedulesSnapshot {
    let (homes, entitled) = await MainActor.run {
      (CodexAccounts.shared.all.map(\.home), EntitlementMonitor.shared.current.isEntitled)
    }
    let rows =
      entitled ? Self.rows(homes: homes, claudeRoot: ClaudeDesktopSchedules.defaultRoot) : []
    return SchedulesSnapshot(takenAt: Date(), isEntitled: entitled, rows: rows)
  }

  static func rows(homes: [CodexHome], claudeRoot: URL) -> [ScheduleRow] {
    var out: [ScheduleRow] = []
    for home in homes {
      let store = CodexAutomations(home: home)
      let runs = store.runTimes()
      let owned = store.isAccountOwned()
      for listed in store.list() {
        switch listed.parsed {
        case .automation(let a):
          let run = runs[a.id]
          let heartbeat = a.kind == "heartbeat"
          out.append(
            ScheduleRow(
              vendor: "codex", accountID: home.id, account: home.displayName, id: a.id,
              name: a.name,
              status: a.apiStatus, rrule: a.rrule,
              summary: CodexAutomationFile.summary(a.rrule), cwd: a.cwds.first, model: a.model,
              reasoningEffort: a.reasoningEffort, lastRunAt: run?.lastRunAt,
              // Measured: Codex does not update the run-times row when a file is paused, so a
              // paused automation's `nextRunAt` from the database would be stale. Only an
              // active file's next fire time is trustworthy.
              nextRunAt: a.apiStatus == "active" ? run?.nextRunAt : nil,
              prompt: a.prompt, editable: !owned && !heartbeat,
              readOnlyReason: owned
                ? CodexAutomations.accountOwnedRefusal
                : heartbeat ? CodexAutomations.heartbeatRefusal(a.id) : nil))
        case .handEdited(let why):
          out.append(
            ScheduleRow(
              vendor: "codex", accountID: home.id, account: home.displayName, id: listed.id,
              name: listed.id, status: "unknown", summary: "unreadable", editable: false,
              readOnlyReason: "Edited by hand (\(why)), so Armada will not rewrite it."))
        case .notAutomation:
          break
        }
      }
    }
    for task in ClaudeDesktopSchedules.read(root: claudeRoot) {
      out.append(
        ScheduleRow(
          vendor: "claude", accountID: task.account, account: task.account, id: task.id,
          name: task.id,
          status: task.enabled ? "active" : "paused", cronExpression: task.cronExpression,
          fireAt: task.fireAt,
          summary: task.cronExpression ?? task.fireAt.map { "once at \($0.formatted())" }
            ?? "unscheduled",
          lastRunAt: task.lastRunAt, editable: false,
          readOnlyReason:
            "Claude desktop tasks change from a Claude Code session in the Claude app, which has "
            + "tools for it. Armada does not read its prompt."))
    }
    return out
  }

  private static let projectGoneRefusal = "That project is no longer saved in Armada."

  enum Resolved {
    case home(CodexHome, cwd: String?)
    case refused(String)
  }

  /// The Codex home and folder for a request, found again on the main actor: the tool resolved
  /// the project seconds ago, and it may have been removed since.
  @MainActor
  static func resolve(projectID: String?, account: String?) -> Resolved {
    var cwd: String?
    var projectHome: String?
    if let projectID {
      guard let project = ProjectStore.shared.project(id: projectID) else {
        return .refused(projectGoneRefusal)
      }
      cwd = project.path
      if case .codex(let homeID) = project.agent { projectHome = homeID }
    }
    let homes = CodexAccounts.shared.all.map(\.home)
    if homes.isEmpty { return .refused("There is no Codex home on this Mac.") }
    if let account {
      let wanted = account.lowercased()
      guard
        let home = homes.first(where: { $0.id == account || $0.displayName.lowercased() == wanted })
      else {
        return .refused(
          "No Codex account \"\(account)\". This Mac has: "
            + homes.map { "\($0.displayName) (\($0.displayPath))" }.joined(separator: ", ") + ".")
      }
      return .home(home, cwd: cwd)
    }
    if let projectHome, let home = homes.first(where: { $0.id == projectHome }) {
      return .home(home, cwd: cwd)
    }
    if homes.count == 1 { return .home(homes[0], cwd: cwd) }
    return .refused(
      "This Mac has \(homes.count) Codex homes. Pass `account`: "
        + homes.map(\.displayName).joined(separator: ", ") + ".")
  }

  /// The home holding `id`, when no account was named: the only home that has it.
  ///
  /// **Zero holders checks Claude desktop before refusing.** An id an agent passes without an
  /// account can equally be a Claude desktop task's — the two vendors share no id space, and
  /// only this lookup tells them apart.
  static func home(holding id: String, in homes: [CodexHome]) -> Resolved {
    let holders = homes.filter { home in
      CodexAutomations(home: home).list().contains { $0.id == id }
    }
    switch holders.count {
    case 1: return .home(holders[0], cwd: nil)
    case 0:
      if ClaudeDesktopSchedules.read(root: ClaudeDesktopSchedules.defaultRoot).contains(where: {
        $0.id == id
      }) {
        return .refused(
          "Claude desktop tasks change from a Claude Code session in the Claude app, which has tools for it."
        )
      }
      return .refused(CodexAutomations.unknownID(id))
    default:
      return .refused(
        "\"\(id)\" is in \(holders.count) Codex homes. Pass `account`: "
          + holders.map(\.displayName).joined(separator: ", ") + ".")
    }
  }

  func save(_ request: SaveScheduleRequest) async -> ScheduleOutcome {
    let resolved: Resolved
    if let id = request.id, request.account == nil {
      let homes = await MainActor.run { CodexAccounts.shared.all.map(\.home) }
      let holder = Self.home(holding: id, in: homes)
      guard case .home(let home, _) = holder else { return Self.refusal(holder) }
      let cwd = await MainActor.run {
        request.projectID.flatMap { ProjectStore.shared.project(id: $0)?.path }
      }
      if request.projectID != nil, cwd == nil { return .refused(Self.projectGoneRefusal) }
      resolved = .home(home, cwd: cwd)
    } else {
      resolved = await MainActor.run {
        Self.resolve(projectID: request.projectID, account: request.account)
      }
    }
    guard case .home(let home, let cwd) = resolved else { return Self.refusal(resolved) }

    let input = SaveInput(
      id: request.id, name: request.name, prompt: request.prompt, rrule: request.rrule, cwd: cwd,
      model: request.model, reasoningEffort: request.reasoningEffort, status: request.status)
    switch CodexAutomations(home: home).save(input, now: Date()) {
    case .refused(let message):
      return .refused(message)
    case .saved(let a, let created):
      let change = Self.change(a, home: home, created: created)
      ScheduleNotifier.post(verb: created ? "scheduled" : "changed", change: change)
      return .saved(change)
    }
  }

  func delete(_ request: DeleteScheduleRequest) async -> ScheduleOutcome {
    let resolved: Resolved
    let homes = await MainActor.run { CodexAccounts.shared.all.map(\.home) }
    if let account = request.account {
      resolved = await MainActor.run { Self.resolve(projectID: nil, account: account) }
    } else {
      resolved = Self.home(holding: request.id, in: homes)
    }
    guard case .home(let home, _) = resolved else { return Self.refusal(resolved) }
    switch CodexAutomations(home: home).remove(id: request.id) {
    case .refused(let message):
      return .refused(message)
    case .removed(let a):
      let change =
        a.map { Self.change($0, home: home, created: false) }
        ?? ScheduleChange(
          id: request.id, name: request.id, account: home.displayName, summary: "", status: "",
          created: false)
      ScheduleNotifier.post(verb: "deleted", change: change)
      return .deleted(change)
    }
  }

  private static func refusal(_ resolved: Resolved) -> ScheduleOutcome {
    if case .refused(let message) = resolved { return .refused(message) }
    return .refused("Armada could not tell which Codex home to use.")
  }

  private static func change(_ a: CodexAutomation, home: CodexHome, created: Bool) -> ScheduleChange
  {
    ScheduleChange(
      id: a.id, name: a.name, account: home.displayName,
      summary: CodexAutomationFile.summary(a.rrule),
      status: a.apiStatus, created: created)
  }
}
