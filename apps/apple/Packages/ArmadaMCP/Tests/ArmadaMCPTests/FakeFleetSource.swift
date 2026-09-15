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

  /// Two projects whose ids share an 8-character prefix (ambiguity), one nested inside the
  /// other, and a third whose folder is gone and whose account is not on this Mac.
  static let armadaProject = "3f2a0000-0000-4000-8000-000000000001"
  static let siteProject = "3f2a0000-0000-4000-8000-000000000002"
  static let almanacProject = "7c1b0000-0000-4000-8000-000000000003"

  private let lock = NSLock()
  private var calls = 0
  private var projectCalls = 0
  let fleet: FleetSnapshot
  var hosts: [String: FleetSnapshot.Host] = [:]
  var projectsFixture: ProjectsSnapshot = FakeFleetSource.projects()

  init(_ fleet: FleetSnapshot = FakeFleetSource.fleet()) {
    self.fleet = fleet
  }

  var snapshotCalls: Int { lock.withLock { calls } }
  var projectsCalls: Int { lock.withLock { projectCalls } }

  func snapshot() async -> FleetSnapshot {
    lock.withLock { calls += 1 }
    return fleet
  }

  func host(forClaudeSession id: String) async -> FleetSnapshot.Host? { hosts[id] }

  func projects() async -> ProjectsSnapshot {
    lock.withLock { projectCalls += 1 }
    return projectsFixture
  }

  static func projects(
    isEntitled: Bool = true, complete: Bool = true, list: [ProjectsSnapshot.Project]? = nil
  ) -> ProjectsSnapshot {
    ProjectsSnapshot(
      takenAt: now, isEntitled: isEntitled,
      index: .init(
        complete: complete, filesRead: complete ? nil : 412, filesTotal: complete ? nil : 2_290,
        earliestDay: now.addingTimeInterval(-40 * 86_400)),
      projects: list ?? [
        project(
          armadaProject, name: "armada", path: "/Users/me/armada",
          live: [
            .init(
              id: waiting, vendor: "claude", name: "Fix login", state: "waiting",
              cwd: "/Users/me/armada")
          ],
          week: 41_200_000, sessions: 18),
        project(
          siteProject, name: "Armada site", path: "/Users/me/armada/web", live: [], week: 900_000,
          sessions: 2),
        project(
          almanacProject, name: "almanac", path: "/Users/me/almanac", exists: false,
          accountName: nil, live: [], week: 0, sessions: 0),
      ])
  }

  static func project(
    _ id: String, name: String, path: String, exists: Bool = true,
    accountName: String? = "Default", live: [ProjectsSnapshot.LiveSession], week: Int,
    sessions: Int
  ) -> ProjectsSnapshot.Project {
    func tokens(_ total: Int) -> ProjectsSnapshot.Tokens {
      let fresh = total / 100
      let cacheWrite = total / 20
      let output = total / 50
      return .init(
        fresh: fresh, cacheWrite: cacheWrite, cacheRead: total - fresh - cacheWrite - output,
        output: output, reasoning: 0)
    }
    let windows: [ProjectsSnapshot.Window] = [
      .init(key: "7d", tokens: tokens(week), sessions: sessions),
      .init(key: "30d", tokens: tokens(week * 3), sessions: sessions * 3),
      .init(key: "all", tokens: tokens(week * 5), sessions: sessions * 5),
    ]
    return ProjectsSnapshot.Project(
      id: id, name: name, path: path, exists: exists,
      defaultAgent: .init(
        vendor: "claude", accountID: "/Users/me/.claude", accountName: accountName),
      live: live, lastActive: week > 0 ? now.addingTimeInterval(-600) : nil, windows: windows,
      byModel: [
        .init(key: "claude-opus-5", label: "claude-opus-5", vendor: "claude", windows: windows),
        .init(key: "gpt-5.5", label: "gpt-5.5", vendor: "codex", windows: windows),
      ],
      byAccount: [
        .init(key: "/Users/me/.claude", label: "Default", vendor: "claude", windows: windows)
      ])
  }

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
