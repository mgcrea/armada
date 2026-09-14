import Foundation

@testable import ArmadaMCP

/// A fleet with no app, no config folder and no bound port behind it.
///
/// Three accounts, chosen so each rule the tools state has a session that would break it: two
/// Claude sessions waiting on different accounts (recency across accounts), one inferred
/// `runningTool` more recent than both (urgency before recency), two ids sharing an 8-character
/// prefix (ambiguity), and Codex threads in all three of its states, one of them a subagent.
final class FakeFleetSource: FleetSource, @unchecked Sendable {
  static let now = Date(timeIntervalSince1970: 1_789_000_000)

  static let waiting = "aaaaaaaa-1111-4000-8000-000000000001"
  static let waitingTwin = "aaaaaaaa-9999-4000-8000-000000000009"
  static let runningTool = "bbbbbbbb-2222-4000-8000-000000000002"
  static let idle = "cccccccc-3333-4000-8000-000000000003"
  static let otherAccountWaiting = "dddddddd-4444-4000-8000-000000000004"
  static let codexOpen = "eeeeeeee-5555-4000-8000-000000000005"
  static let codexSubagent = "ffffffff-6666-4000-8000-000000000006"
  static let codexEnded = "99999999-7777-4000-8000-000000000007"

  private let lock = NSLock()
  private var calls = 0
  let fleet: FleetSnapshot
  var hosts: [String: FleetSnapshot.Host] = [:]

  init(_ fleet: FleetSnapshot = FakeFleetSource.fleet()) {
    self.fleet = fleet
  }

  var snapshotCalls: Int { lock.withLock { calls } }

  func snapshot() async -> FleetSnapshot {
    lock.withLock { calls += 1 }
    return fleet
  }

  func host(forClaudeSession id: String) async -> FleetSnapshot.Host? { hosts[id] }

  static func fleet(
    isEntitled: Bool = true, transcriptPath: String? = nil, rolloutPath: String = "/tmp/rollout",
    claude: [FleetSnapshot.ClaudeAccount]? = nil
  ) -> FleetSnapshot {
    FleetSnapshot(
      takenAt: now, isEntitled: isEntitled,
      claude: claude ?? [
        FleetSnapshot.ClaudeAccount(
          id: "/Users/me/.claude", name: "Default", plan: "Max", modelID: "opus[1m]",
          usage: FleetSnapshot.Usage(
            fiveHour: .init(
              utilization: 17, resetsAt: now.addingTimeInterval(7_800), refusedAt: nil),
            sevenDay: .init(
              utilization: 69, resetsAt: now.addingTimeInterval(3 * 86_400), refusedAt: nil),
            limits: [
              .init(
                title: "Fable", subtitle: "7 days, this model", percent: 16, resetsAt: nil,
                isActive: false)
            ],
            fetchedAt: now.addingTimeInterval(-30), source: "live"),
          quotaHit: nil,
          sessions: [
            claudeSession(
              waiting, name: "Fix login", state: "waiting", waitingFor: "permission prompt",
              ago: 600, transcriptPath: transcriptPath),
            claudeSession(waitingTwin, name: "Fix login copy", state: "working", ago: 5),
            claudeSession(runningTool, name: "Refactor api", state: "runningTool", ago: 10),
            claudeSession(idle, name: "Docs", state: "idle", ago: 3_600, transcriptPath: nil),
          ]),
        FleetSnapshot.ClaudeAccount(
          id: "/Users/me/.claude-work", name: "Work", plan: nil, modelID: nil, usage: nil,
          quotaHit: nil,
          sessions: [
            claudeSession(
              otherAccountWaiting, name: "Billing", state: "waiting", waitingFor: "input needed",
              ago: 60)
          ]),
      ],
      codex: [
        FleetSnapshot.CodexAccount(
          id: "/Users/me/.codex", name: "Codex", plan: "Pro", usage: nil,
          sessions: [
            codexSession(
              codexOpen, name: "Codex thread", state: "awaitingInput", ago: 1,
              rolloutPath: rolloutPath),
            codexSession(codexSubagent, name: "Guardian", state: "working", ago: 2, subagent: true),
            codexSession(codexEnded, name: "Yesterday", state: "ended", ago: 86_400),
          ])
      ])
  }

  static func claudeSession(
    _ id: String, name: String, state: String, waitingFor: String? = nil, ago: TimeInterval,
    transcriptPath: String? = "/tmp/transcript.jsonl"
  ) -> FleetSnapshot.ClaudeSession {
    FleetSnapshot.ClaudeSession(
      id: id, pid: 4242, name: name, title: name, project: "armada", cwd: "/Users/me/armada",
      state: state, stateLabel: state, stateIsInferred: state == "runningTool",
      wantsAttention: state == "waiting" || state == "runningTool", waitingFor: waitingFor,
      startedAt: now.addingTimeInterval(-7_200), lastActivity: now.addingTimeInterval(-ago),
      statusChangedAt: now.addingTimeInterval(-ago), model: "claude-opus-5",
      context: FleetSnapshot.Context(
        total: 250_000, limit: 1_000_000, limitNote: "Assumed.", cacheRead: 240_000,
        cacheCreation: 9_000, freshInput: 1_000, output: 2_000, at: now, hasCompacted: false),
      quotaHit: nil, transcriptPath: transcriptPath)
  }

  static func codexSession(
    _ id: String, name: String, state: String, ago: TimeInterval, subagent: Bool = false,
    rolloutPath: String = "/tmp/rollout"
  ) -> FleetSnapshot.CodexSession {
    FleetSnapshot.CodexSession(
      id: id, name: name, title: nil, project: "armada", cwd: "/Users/me/armada", state: state,
      stateLabel: state, isLive: state != "ended", isSubagent: subagent,
      kind: subagent ? "Guardian review" : nil, startedAt: now.addingTimeInterval(-9_000),
      lastActivity: now.addingTimeInterval(-ago), model: "gpt-5.5", context: nil,
      totalTokens: 12_000, rolloutPath: rolloutPath)
  }
}
