import ArmadaSupervisor
import Foundation

/// The `claude` that answers spoken questions: started on the first question, kept while the
/// conversation is active, closed after five idle minutes.
///
/// **Armada owns this process**, which is a deliberate exception to "watches, never owns": see
/// the 2026-09-15 row in docs/design.md. What keeps it narrow is `SupervisorArguments`, and
/// what keeps it short-lived is `idleTimeout`. An idle `claude` measured 128MB RSS in
/// `ClaudeControl`, so it is not kept a moment longer than a follow-up question needs.
///
/// **Events reach the main queue in the order they were written.** One `DispatchQueue.main.async`
/// per line, from the one serial readability handler, rather than a `Task` per line, whose
/// order the main actor does not promise.
///
/// **It only ever signals the pid it started**, never a pattern: `pkill -f "input-format
/// stream-json"` once took down 18 of 24 live VS Code sessions (docs/claude-code-sessions.md).
nonisolated final class SupervisorProcess: @unchecked Sendable {
  struct Launch: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
  }

  static let idleTimeout: TimeInterval = 300
  /// How long a closed stdin has to end the process before it is terminated, and a terminated
  /// one before it is killed.
  static let grace: TimeInterval = 2

  private let onEvent: @Sendable (StreamEvent) -> Void
  private let onExit: @Sendable (Int32, String) -> Void

  private let lock = NSLock()
  private var process: Process?
  private var stdin: FileHandle?
  private var idle: DispatchWorkItem?
  private var stderrTail = Data()

  /// - Parameters:
  ///   - onEvent: each decoded line, on the main queue, in order. `.other` is never delivered.
  ///   - onExit: once, on the main queue, after the last event: the exit status and the end of
  ///     stderr.
  init(
    onEvent: @escaping @Sendable (StreamEvent) -> Void,
    onExit: @escaping @Sendable (Int32, String) -> Void
  ) {
    self.onEvent = onEvent
    self.onExit = onExit
  }

  var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

  func start(_ launch: Launch) throws {
    let process = Process()
    process.executableURL = launch.executable
    process.arguments = launch.arguments
    process.environment = launch.environment
    process.currentDirectoryURL = launch.directory

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    // A question written in the moment between the process dying and its exit being noticed
    // would otherwise raise SIGPIPE, and SIGPIPE ends Armada. With this the write fails, and
    // `send` ignores the failure.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    // The exit is reported only once stdout has reached its end, so the last `result` line is
    // never overtaken by the news that the process is gone.
    let drained = DispatchGroup()
    drained.enter()
    let lines = LineSplitter()
    let onEvent = onEvent
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        drained.leave()
        return
      }
      for line in lines.append(chunk) {
        let event = StreamEvent.decode(line)
        guard event != .other else { continue }
        DispatchQueue.main.async { onEvent(event) }
      }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.appendStderr(chunk)
    }
    let onExit = onExit
    process.terminationHandler = { [weak self] ended in
      _ = drained.wait(timeout: .now() + 2)
      let status = ended.terminationStatus
      let tail = self?.ended() ?? ""
      DispatchQueue.main.async { onExit(status, tail) }
    }

    try process.run()
    lock.withLock {
      self.process = process
      self.stdin = input.fileHandleForWriting
    }
    touch()
  }

  /// Write one frame. Dropped when the process has gone, rather than raising `SIGPIPE`.
  func send(_ frame: Data) {
    let handle: FileHandle? = lock.withLock {
      guard process?.isRunning == true else { return nil }
      return stdin
    }
    guard let handle else { return }
    try? handle.write(contentsOf: frame)
    touch()
  }

  /// Close stdin, which ends the CLI, and make sure it ends.
  func stop() {
    let (process, stdin) = lock.withLock { () -> (Process?, FileHandle?) in
      idle?.cancel()
      idle = nil
      let handles = (self.process, self.stdin)
      self.stdin = nil
      return handles
    }
    try? stdin?.close()
    guard let process, process.isRunning else { return }
    let pid = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.grace) {
      guard process.isRunning else { return }
      // SIGTERM first, so the CLI can take its MCP connection down with it.
      process.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.grace) {
        if process.isRunning { kill(pid, SIGKILL) }
      }
    }
  }

  /// Push the idle deadline back: called on every question sent and every process start.
  private func touch() {
    let item = DispatchWorkItem { [weak self] in self?.stop() }
    lock.withLock {
      idle?.cancel()
      idle = item
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + Self.idleTimeout, execute: item)
  }

  private func appendStderr(_ chunk: Data) {
    lock.withLock {
      stderrTail.append(chunk)
      if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
    }
  }

  private func ended() -> String {
    lock.withLock {
      idle?.cancel()
      idle = nil
      process = nil
      stdin = nil
      return String(decoding: stderrTail, as: UTF8.self)
    }
  }
}

/// Newline-delimited lines out of arbitrary chunks. Touched only from one readability handler,
/// which the system calls serially.
nonisolated private final class LineSplitter: @unchecked Sendable {
  private var buffer = Data()

  func append(_ chunk: Data) -> [Data] {
    buffer.append(chunk)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      lines.append(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
    }
    return lines
  }
}
