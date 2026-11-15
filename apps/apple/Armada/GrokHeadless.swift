import Foundation
import os

/// Headless Grok Build turns that Armada runs as its own child processes.
///
/// `armada_start_session` with `headless` starts one, and `armada_send_message` to a headless
/// session whose turn has ended runs its next one: a headless session has no process between
/// turns, so its next message is its next turn. `armada_close_session` stops one, which only
/// works here because Armada holds the process: Grok lists no pid for a headless run
/// (docs/grok-sessions.md).
///
/// What a turn may do is `GrokHeadlessCommand`'s to decide; this owns the processes.
///
/// **One writer per session.** Grok has no lock against two processes writing one session, so a
/// session is reserved from the moment `run` is called (`starting`), across its awaits, until its
/// process has exited; `isRunning` covers both, and every route into a Grok session checks it.
///
/// **A failure belongs to the turn that had it.** `run` reports a turn that exits badly within
/// `settle`, read from that turn's own `TurnExit`; one that fails later is logged and nothing
/// more, and can never be reported against a later turn.
///
/// The turn's output goes nowhere: the session's own `updates.jsonl` holds the conversation, and
/// `armada_read_transcript` reads it. Only stderr is kept, for a turn that fails at once.
@MainActor
final class GrokHeadless {
  static let shared = GrokHeadless()
  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "grok-headless")

  /// How long a new turn is watched for failing at once, such as a Grok that is signed out
  /// (0.2 s). Long enough for that, short enough for a tool call.
  static let settle: Duration = .seconds(2)
  /// Between `SIGTERM` and `SIGKILL` when a turn is stopped.
  static let grace: Duration = .seconds(5)

  /// How one turn ended, filled in by its termination handler.
  @MainActor
  private final class TurnExit {
    var status: Int32?
    var reason: Process.TerminationReason?
    var stderr = ""
  }

  private var running: [String: Process] = [:]
  /// Reserved by `run` before its first await, so nothing else starts a writer meanwhile.
  private var starting: Set<String> = []
  /// Turns `stop` was asked to end, whose signal death is not a failure.
  private var stopping: Set<String> = []
  /// When Armada saw its own last turn in a session end. See `ownTurnEnded`.
  private var endedAt: [String: Date] = [:]

  func isRunning(_ sessionID: String) -> Bool {
    starting.contains(sessionID) || running[sessionID]?.isRunning == true
  }

  /// When the session's most recent turn was Armada's and ended: a write to its log no later
  /// than this was that turn's own, not something else holding the session.
  func ownTurnEnded(_ sessionID: String) -> Date? { endedAt[sessionID] }

  /// The session is about to be continued by something other than Armada's headless runner, a
  /// terminal resume, so its last turn is no longer Armada's.
  func forget(_ sessionID: String) { endedAt[sessionID] = nil }

  /// Starts one turn. Nil once it is running, or has already finished cleanly; otherwise a
  /// sentence for the caller.
  func run(
    _ start: GrokHeadlessCommand.Start, home: GrokHome, cwd: String, prompt: String,
    model: String?
  ) async -> String? {
    let id = start.sessionID
    guard !isRunning(id) else {
      return "A headless turn is already running in that session. Wait for it to end."
    }
    starting.insert(id)
    defer { starting.remove(id) }

    guard let binary = GrokControl.executable() else {
      return "Armada could not find the grok command."
    }

    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appending(
      path: "armada-grok-\(UUID().uuidString)", directoryHint: .isDirectory)
    let promptFile = directory.appending(path: "prompt.txt", directoryHint: .notDirectory)
    let errorFile = directory.appending(path: "stderr.txt", directoryHint: .notDirectory)
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Data(prompt.utf8).write(to: promptFile)
      guard fileManager.createFile(atPath: errorFile.path(percentEncoded: false), contents: nil)
      else { throw CocoaError(.fileWriteUnknown) }
    } catch {
      try? fileManager.removeItem(at: directory)
      return "Armada could not write the turn's prompt: \(error.localizedDescription)"
    }

    let base = await VSCodeLaunch.loginShellEnvironment() ?? ProcessInfo.processInfo.environment

    let process = Process()
    process.executableURL = binary
    process.arguments = GrokHeadlessCommand.arguments(
      start: start, promptFile: promptFile.path(percentEncoded: false), cwd: cwd, model: model)
    process.environment = GrokHeadlessCommand.environment(
      base: base, homePath: home.path, isDefault: home.isDefault)
    process.currentDirectoryURL = URL(filePath: cwd, directoryHint: .isDirectory)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errorHandle: FileHandle
    do {
      errorHandle = try FileHandle(forWritingTo: errorFile)
    } catch {
      try? fileManager.removeItem(at: directory)
      return "Armada could not start the turn: \(error.localizedDescription)"
    }
    process.standardError = errorHandle
    let exit = TurnExit()
    process.terminationHandler = { finished in
      try? errorHandle.close()
      let status = finished.terminationStatus
      let reason = finished.terminationReason
      let stderr = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
      try? FileManager.default.removeItem(at: directory)
      Task { @MainActor in
        exit.status = status
        exit.reason = reason
        exit.stderr = stderr
        GrokHeadless.shared.finished(id, process: finished, status: status, reason: reason)
      }
    }

    do { try process.run() } catch {
      try? errorHandle.close()
      try? fileManager.removeItem(at: directory)
      return "Armada could not start grok: \(error.localizedDescription)"
    }
    running[id] = process
    starting.remove(id)
    endedAt[id] = nil
    Self.logger.notice("headless turn started in \(id, privacy: .public)")

    let clock = ContinuousClock()
    let deadline = clock.now + Self.settle
    while exit.status == nil, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let status = exit.status, let reason = exit.reason else { return nil }
    if reason == .exit, status == 0 { return nil }
    if reason == .uncaughtSignal, stopping.contains(id) { return nil }
    return GrokHeadlessCommand.failure(stderr: exit.stderr, status: status)
  }

  private func finished(
    _ id: String, process: Process, status: Int32, reason: Process.TerminationReason
  ) {
    guard running[id] === process else { return }
    running[id] = nil
    stopping.remove(id)
    endedAt[id] = Date()
    let how = reason == .exit ? "status" : "signal"
    Self.logger.notice(
      "headless turn in \(id, privacy: .public) ended with \(how, privacy: .public) \(status, privacy: .public)"
    )
  }

  struct Stopped {
    let killed: Bool
    let exited: Bool
  }

  /// Ends a running turn: `SIGTERM` to the turn's process group, so the commands it started
  /// stop with it, then `SIGKILL` to the group after `grace` if grok is still there. Nil when
  /// Armada is not running one in that session.
  ///
  /// A `Process` child leads its own group (measured 2026-11-15), and the group is signalled
  /// only while grok is unreaped, so its id cannot have passed to another group. Commands a turn
  /// put in a group of their own are out of reach; whether grok does is not measured.
  func stop(_ sessionID: String) async -> Stopped? {
    guard let process = running[sessionID], process.isRunning else { return nil }
    stopping.insert(sessionID)
    Self.signal(process, SIGTERM)
    if await Self.exits(process, within: Self.grace) {
      return Stopped(killed: false, exited: true)
    }
    Self.signal(process, SIGKILL)
    let exited = await Self.exits(process, within: .seconds(2))
    return Stopped(killed: true, exited: exited)
  }

  /// Every running turn, when Armada quits: `SIGTERM` to each group, without waiting. A turn
  /// left running would outlive Armada with nobody able to stop it.
  func stopAll() {
    for process in running.values where process.isRunning {
      Self.signal(process, SIGTERM)
    }
  }

  /// The process's group when it leads one that is not Armada's own, else the process alone.
  private static func signal(_ process: Process, _ signal: Int32) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    guard pid > 1 else { return }
    if getpgid(pid) == pid, pid != getpgrp() {
      kill(-pid, signal)
    } else {
      kill(pid, signal)
    }
  }

  private static func exits(_ process: Process, within limit: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while process.isRunning, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    return !process.isRunning
  }
}
