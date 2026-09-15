import ArmadaMCP
import Foundation
import MCPKit
import MCPKitLoopback
import Observation
import os

/// Owns the MCP listener, its token, and the decision of when it runs.
///
/// **One reconciler, `sync()`**, rather than start and stop calls scattered through views —
/// Almanac's shape. Two things decide whether the socket should be bound: the switch in
/// Settings ▸ Supervisor, and the entitlement. A second place that could bind the socket
/// would be a second place that could leave it bound after the switch was turned off.
///
/// **Off by default, and never constructed until switched on.** An Armada nobody has pointed
/// at this has no listener object at all, the same property the updater has. The listener
/// binds 127.0.0.1 and nothing else — the kit makes the interface unconfigurable. Every tool but
/// one reads. `armada_start_session` sits behind the kit's write gate, and `allowWrites` is the
/// Allow writes switch in Settings ▸ Supervisor, read from defaults on every request so the
/// switch needs no restart and cannot drift from the listener.
///
/// **Threading.** The listener serves each request on a connection thread of its own. The
/// only door from there to the main actor is `FleetBridge`, which hops once. Never call the
/// server from the main actor, and never read this object from a tool.
@MainActor
@Observable
final class MCPServerController {
  static let shared = MCPServerController()

  static let enabledKey = "armada.mcpEnabled"
  static let portKey = "armada.mcpPort"
  static let defaultPort = 8790

  /// Off by default. `nonisolated` because the listener asks on its connection threads, and
  /// `UserDefaults` is safe to read from any of them.
  nonisolated static let allowWritesKey = "armada.mcpAllowWrites"
  nonisolated static var allowsWrites: Bool {
    UserDefaults.standard.bool(forKey: allowWritesKey)
  }

  private(set) var state: LoopbackListener.State = .stopped
  private(set) var tokenError: String?

  /// Per bundle identifier, so the Debug build and the installed one each keep their own
  /// Keychain item. One shared item would put a Keychain consent prompt in front of whichever
  /// build did not create it, since the two are signed differently.
  @ObservationIgnored private let tokens = KeychainTokenStore(
    service: Bundle.main.bundleIdentifier ?? "io.mgcrea.armada")
  @ObservationIgnored private var listener: LoopbackListener?
  @ObservationIgnored private var boundPort: Int?

  private init() {}

  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

  /// The stored port, or the default for anything unset or outside the unprivileged range.
  static var port: Int {
    let stored = UserDefaults.standard.integer(forKey: portKey)
    return (1024...65_535).contains(stored) ? stored : defaultPort
  }

  var runningPort: Int? {
    if case .running(let port) = state { return port }
    return nil
  }

  /// The token, minted on first read. Empty when the Keychain refused, which the pane shows
  /// rather than hiding behind a blank field.
  ///
  /// The error is only written when it changes: this is read from view bodies, and an
  /// `@Observable` write on every read would invalidate the view that is reading it.
  var token: String {
    do {
      let value = try tokens.current()
      if tokenError != nil { tokenError = nil }
      return value
    } catch {
      let message = error.localizedDescription
      if tokenError != message { tokenError = message }
      return ""
    }
  }

  func regenerateToken() {
    do {
      try tokens.regenerate()
      tokenError = nil
    } catch {
      tokenError = error.localizedDescription
    }
  }

  /// Bring the listener into line with the switch and the entitlement. Safe to call on every
  /// change; `EntitlementMonitor.apply()` calls it at launch and whenever a licence or trial
  /// changes, and the pane calls it when the switch or the port moves.
  func sync() {
    // An unlicensed Armada has stopped its watchers and holds nothing, so a server would
    // answer every question with an empty fleet. Off is the honest state.
    guard Self.isEnabled, EntitlementMonitor.shared.current.isEntitled else {
      stop()
      return
    }
    let wanted = Self.port
    if listener != nil, boundPort == wanted { return }
    stop()
    start(port: wanted)
  }

  private func start(port: Int) {
    let server = MCPServer(
      info: ServerInfo(
        name: NewSession.Supervisor.serverName, version: AppInfo.shortVersion, title: "Armada"),
      instructions: Tools.instructions,
      tools: Tools.table(source: FleetBridge(), starter: SessionStarterBridge()))

    let listener = LoopbackListener(
      server: server,
      gate: RequestGate(port: port) { [tokens] presented in tokens.verdict(for: presented) },
      allowWrites: { MCPServerController.allowsWrites },
      // One line per request into the unified log. Never the arguments: `AuditEntry` cannot
      // carry them, which is the point of it being a type rather than a closure over the frame.
      audit: { entry in MCPLog.request(entry) })
    listener.start(port: port)
    self.listener = listener
    boundPort = port
    state = listener.state
    switch listener.state {
    case .running: MCPLog.logger.info("mcp server listening on 127.0.0.1:\(port, privacy: .public)")
    case .failed(let message):
      MCPLog.logger.error("mcp server failed: \(message, privacy: .public)")
    case .stopped: break
    }
  }

  private func stop() {
    listener?.stop()
    listener = nil
    boundPort = nil
    state = .stopped
  }
}

/// The audit log, reachable from the listener's connection threads.
nonisolated enum MCPLog {
  static let logger = Logger(subsystem: "io.mgcrea.armada", category: "mcp")

  static func request(_ entry: AuditEntry) {
    // Composed first, then logged as one interpolation: `OSLogMessage` is not a `String`.
    let line =
      "\(entry.method ?? "?") \(entry.name ?? "-") \(String(describing: entry.outcome)) "
      + "\(entry.durationMs)ms"
    logger.info("mcp \(line, privacy: .public)")
  }
}
