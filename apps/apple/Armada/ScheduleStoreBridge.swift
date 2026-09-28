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
          // Measured: Codex does not update the run-times row when a file is paused, so a
          // paused automation's `nextRunAt` from the database would be stale. Only an active
          // file's next fire time is trustworthy.
          let run = runs[a.id]
          let heartbeat = a.kind == "heartbeat"
          out.append(
            ScheduleRow(
              vendor: "codex", accountID: home.id, account: home.displayName, id: a.id,
              name: a.name,
              status: a.apiStatus, rrule: a.rrule,
              summary: CodexAutomationFile.summary(a.rrule), cwd: a.cwds.first, model: a.model,
              reasoningEffort: a.reasoningEffort, lastRunAt: run?.lastRunAt,
              nextRunAt: a.status == "ACTIVE" ? run?.nextRunAt : nil,
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

  func save(_ request: SaveScheduleRequest) async -> ScheduleOutcome {
    .refused("Saving schedules is not wired up yet.")
  }

  func delete(_ request: DeleteScheduleRequest) async -> ScheduleOutcome {
    .refused("Deleting schedules is not wired up yet.")
  }
}
