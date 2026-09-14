import ArmadaMCP
import Foundation

/// The one place the MCP server touches the fleet.
///
/// Tool calls arrive on the listener's connection threads, never on the main actor, and this
/// type is the entire main-actor surface they are allowed. The rule it exists to enforce is
/// Almanac's: **hop once, take an immutable snapshot, leave.** Everything below reads stored
/// properties the watchers have already filled in, with no `await` and no I/O inside the hop,
/// so an agent asking about the fleet costs the UI one pass over arrays it already holds.
///
/// **A value type with no state**, and `nonisolated`, rather than a main-actor class. Under
/// this target's default isolation a main-actor class conforming to `FleetSource` would get an
/// isolated conformance, which cannot be handed to the listener's threads at all. The hop is
/// spelled out instead, as `MainActor.run`, where a reader can see it.
nonisolated struct FleetBridge: FleetSource {

  func snapshot() async -> FleetSnapshot {
    await MainActor.run { Self.build(now: Date()) }
  }

  /// A second, deliberate hop: `SessionHostLookup` walks the process tree on a cache miss.
  func host(forClaudeSession id: String) async -> FleetSnapshot.Host? {
    await MainActor.run {
      for account in Accounts.shared.all {
        guard let session = account.sessions.sessions.first(where: { $0.id == id }) else {
          continue
        }
        return SessionHostLookup.host(for: session.registry).map {
          FleetSnapshot.Host(name: $0.name, bundleID: $0.bundleID, pid: $0.pid)
        }
      }
      return nil
    }
  }

  @MainActor
  static func build(now: Date) -> FleetSnapshot {
    FleetSnapshot(
      takenAt: now,
      isEntitled: EntitlementMonitor.shared.current.isEntitled,
      claude: Accounts.shared.all.map { claude($0, now: now) },
      codex: CodexAccounts.shared.all.map { codex($0, now: now) })
  }

  // MARK: - Claude Code

  @MainActor
  private static func claude(_ account: Account, now: Date) -> FleetSnapshot.ClaudeAccount {
    FleetSnapshot.ClaudeAccount(
      id: account.id,
      name: account.displayName,
      plan: account.planLabel,
      modelID: account.modelID,
      // Corrected by a live refusal exactly as the popover and the Usage pane correct it,
      // through the same function, so the agent is never told a number the meter disowns.
      usage: account.usage.map { usage($0, correctedBy: account.quotaHit, now: now) },
      quotaHit: account.quotaHit.map(quotaHit),
      sessions: account.sessions.sessions.map { session($0, in: account) })
  }

  @MainActor
  private static func session(_ session: Session, in account: Account)
    -> FleetSnapshot.ClaudeSession
  {
    // The same resolution `ContextSection` draws, so the percentage an agent quotes is the
    // one on screen, and `limitNote` is the tooltip that says when the size was assumed.
    let window = session.context.map {
      ContextWindow.resolve(
        sessionModelID: session.sessionModelID, accountModelID: account.modelID,
        messageModelID: $0.modelID, observedTotal: $0.total)
    }
    let context: FleetSnapshot.Context? =
      if let reading = session.context, let window {
        Self.context(
          reading, limit: window.limit, note: window.source.explanation,
          compacted: session.hasCompactedSinceBaseline)
      } else {
        nil
      }

    return FleetSnapshot.ClaudeSession(
      id: session.id,
      pid: session.registry.pid,
      name: session.displayName,
      title: session.title,
      project: session.registry.projectName,
      cwd: session.registry.cwd,
      state: session.state.rawValue,
      stateLabel: session.state.label,
      stateIsInferred: session.state.isBestEffort,
      wantsAttention: session.wantsAttention,
      waitingFor: session.waitingFor,
      startedAt: session.registry.startedAtDate,
      lastActivity: session.lastActivity,
      statusChangedAt: session.registry.statusUpdatedAt.map {
        Date(timeIntervalSince1970: Double($0) / 1000)
      },
      model: window?.displayModelID ?? session.context?.modelID,
      context: context,
      quotaHit: session.quotaHit.map(quotaHit),
      transcriptPath: session.transcript?.path(percentEncoded: false))
  }

  // MARK: - Codex

  @MainActor
  private static func codex(_ account: CodexAccount, now: Date) -> FleetSnapshot.CodexAccount {
    FleetSnapshot.CodexAccount(
      id: account.id,
      name: account.displayName,
      plan: account.planLabel,
      usage: account.usage.map { usage($0.asSnapshot, correctedBy: nil, now: now) },
      sessions: account.sessions.sessions.map(codexSession))
  }

  @MainActor
  private static func codexSession(_ session: CodexSession) -> FleetSnapshot.CodexSession {
    let context: FleetSnapshot.Context? =
      if let reading = session.context, let limit = session.contextLimit {
        Self.context(
          reading, limit: limit,
          note: "Codex records the window size in its session log, so this is measured.",
          compacted: false)
      } else {
        nil
      }
    return FleetSnapshot.CodexSession(
      id: session.id,
      name: session.displayName,
      title: session.title,
      project: session.meta.projectName,
      cwd: session.meta.cwd,
      state: session.state.rawValue,
      stateLabel: session.state.label,
      isLive: session.state.isLive,
      isSubagent: session.isSubagent,
      kind: session.kindLabel,
      startedAt: session.meta.startedAt,
      lastActivity: session.lastActivity,
      model: session.meta.model,
      context: context,
      totalTokens: session.totalTokens,
      rolloutPath: session.rollout.path(percentEncoded: false))
  }

  // MARK: - Shared

  private static func usage(_ snapshot: UsageSnapshot, correctedBy hit: QuotaHit?, now: Date)
    -> FleetSnapshot.Usage
  {
    FleetSnapshot.Usage(
      fiveHour: snapshot.window(.fiveHour, correctedBy: hit, now: now).map(window),
      sevenDay: snapshot.window(.sevenDay, correctedBy: hit, now: now).map(window),
      limits: snapshot.limits.map {
        FleetSnapshot.Limit(
          title: $0.title, subtitle: $0.subtitle, percent: $0.percent, resetsAt: $0.resetsAt,
          isActive: $0.isActive)
      },
      fetchedAt: snapshot.fetchedAt,
      source: source(snapshot.source))
  }

  private static func window(_ window: UsageWindow) -> FleetSnapshot.Window {
    FleetSnapshot.Window(
      utilization: window.utilization, resetsAt: window.resetsAt, refusedAt: window.rejectedAt)
  }

  private static func source(_ source: UsageSnapshot.Source) -> String {
    switch source {
    case .live: "live"
    case .cache: "cache"
    case .sessionLog: "sessionLog"
    }
  }

  private static func quotaHit(_ hit: QuotaHit) -> FleetSnapshot.QuotaHit {
    FleetSnapshot.QuotaHit(
      at: hit.at, resetsAt: hit.resetsAt,
      window: hit.length.map { $0 == .fiveHour ? "fiveHour" : "sevenDay" })
  }

  private static func context(
    _ reading: ContextReading, limit: Int, note: String, compacted: Bool
  ) -> FleetSnapshot.Context {
    FleetSnapshot.Context(
      total: reading.total, limit: limit, limitNote: note, cacheRead: reading.cacheRead,
      cacheCreation: reading.cacheCreation, freshInput: reading.freshInput,
      output: reading.output, at: reading.at, hasCompacted: compacted)
  }
}
