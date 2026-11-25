import Foundation
import Subprocess
import System

/// Running a command that Armada waits on for an answer, then is done with.
///
/// **Bounded three ways, whatever the child does.** A deadline ends it; cancelling the calling
/// task ends it, so a probe whose account was locked stops its `claude` rather than letting it
/// run to the deadline; and reading stops when the child exits, even when something it started
/// still holds the pipe, which swift-subprocess does by cancelling the read once its exit monitor
/// fires and then draining what is buffered. Under `Process` each caller built these itself: a
/// watchdog work item, a second thread draining stderr, a temp file in place of a pipe.
///
/// **Each child leads a process group of its own**, as a `Process` child did (measured
/// 2026-11-15), and at the deadline or on cancellation is stopped by its group, so what it
/// started goes with it; a child that answered is stopped alone (`afterAnswer`). That needs
/// `processGroupID = 0`: by default a Subprocess child stays in Armada's own group, and a
/// teardown sent to that group would reach Armada.
///
/// **Signals wait on the reap.** Subprocess reaps a child only after both the work on it and its
/// exit monitor are done, so a signal sent from that work cannot reach a reused pid. A teardown on
/// cancellation runs beside that work, and checks the child is there before each step: between
/// that check and the signal is the one narrow window left, microseconds wide, as it was under
/// `Process`'s `isRunning` and `kill`.
public enum ChildProcess {
  /// How a child that is still running is stopped, at the deadline, on cancellation, or once its
  /// answer is in.
  public enum Stop: Sendable {
    /// `SIGTERM` to the group, so a CLI can take its own children down, then `SIGKILL` to the
    /// group if the leader is still there after `grace`.
    case terminate(grace: Duration)
    /// `SIGKILL` to the group at once. For an interactive zsh or bash, which ignores `SIGTERM`.
    case kill
  }

  /// A child that ran to its exit.
  public struct Finished: Sendable {
    /// The exit code; nil when a signal ended it.
    public let exitCode: Int32?
    /// The signal that ended it; nil when it exited.
    public let signal: Int32?
    public let standardOutput: Data
    public let standardError: Data

    public var succeeded: Bool { exitCode == 0 }

    /// The status as `Process.terminationStatus` gave it: the exit code, or the signal.
    public var status: Int32 { exitCode ?? signal ?? -1 }
  }

  /// What happens to the child's stdout and stderr.
  public enum Output: Sendable {
    /// Read into `Finished`, up to `outputLimit` each.
    case collect
    /// The null device, as `Process` gave a child with `FileHandle.nullDevice`. For a command
    /// that may start something long-lived, such as VS Code's `code` starting VS Code: that
    /// would inherit a pipe, and get `SIGPIPE` on its next write once Armada stops reading.
    case discard
  }

  /// The most either stream is read into memory. Beyond it the run fails, which every caller
  /// treats as no answer: nothing Armada asks prints more than a login environment.
  public static let outputLimit = 4 << 20

  /// Runs `executable` to its exit and returns what it printed. Nil when it cannot be started,
  /// prints more than `outputLimit`, or is still running at `timeout` or when the task is
  /// cancelled — in which case it has been stopped by `stop` before this returns.
  @concurrent
  public static func collect(
    _ executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
    directory: URL? = nil, output: Output = .collect, timeout: Duration,
    stop: Stop = .terminate(grace: .seconds(2))
  ) async -> Finished? {
    // The last moment before a process exists: a task already cancelled starts nothing.
    guard !Task.isCancelled else { return nil }
    let configuration = configuration(
      executable, arguments: arguments, environment: environment, directory: directory, stop: stop)
    return await bounded(timeout) {
      switch output {
      case .collect:
        let result = try await Subprocess.run(
          configuration, input: .none, output: .data(limit: outputLimit),
          error: .data(limit: outputLimit))
        return Finished(result.terminationStatus, result.standardOutput, result.standardError)
      case .discard:
        let result = try await Subprocess.run(
          configuration, input: .none, output: .discarded, error: .discarded)
        return Finished(result.terminationStatus, Data(), Data())
      }
    }
  }

  /// Writes `input` to the child's stdin and reads its stdout a line at a time until `answer`
  /// makes something of one, then closes stdin and stops the child. Nil when it cannot be
  /// started, exits or reaches `timeout` before a line answers, or the task is cancelled.
  ///
  /// Stdin stays open while waiting: the CLIs this serves (`claude` and `grok` over stream-json
  /// and ACP) exit when it closes, and some would before answering.
  @concurrent
  public static func ask<Answer: Sendable>(
    _ executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
    directory: URL? = nil, input: Data, timeout: Duration,
    stop: Stop = .terminate(grace: .seconds(2)),
    answer: @escaping @Sendable (Data) -> Answer?
  ) async -> Answer? {
    guard !Task.isCancelled else { return nil }
    let configuration = configuration(
      executable, arguments: arguments, environment: environment, directory: directory, stop: stop)
    let answered = afterAnswer(stop)
    return await bounded(timeout) {
      let result = try await Subprocess.run(
        configuration, input: .inputWriter, output: .sequence, error: .discarded
      ) { execution -> Answer? in
        let writer = execution.standardInputWriter
        _ = try await writer.write(Array(input))
        var lines = LineBuffer()
        var found: Answer?
        reading: for try await chunk in execution.standardOutput {
          for line in lines.append(chunk.withUnsafeBytes { Data($0) }) {
            if let value = answer(line) {
              found = value
              break reading
            }
          }
        }
        // Closing stdin asks the CLI to exit, but not instantly, and `run` returns only once
        // it has: the teardown is what makes sure it does.
        try? await writer.finish()
        await execution.teardown(using: answered)
        return found
      }
      return result.closureResult
    }
  }

  /// Stopping a child that has answered: the child alone, as `Process.terminate()` did, and
  /// never its group. A `claude` run for a session's folder starts the person's MCP servers and
  /// hooks, and one that answered has done nothing wrong for them to be killed over; it gets
  /// the grace to take them down itself, then `SIGKILL`, to itself only.
  static func afterAnswer(_ stop: Stop) -> [TeardownStep] {
    switch stop {
    case .terminate(let grace):
      [.gracefulShutDown(toProcessGroup: false, allowedDurationToNextStep: grace)]
    case .kill:
      [.send(signal: .kill, toProcessGroup: false, allowedDurationToNextStep: .milliseconds(500))]
    }
  }

  // MARK: - Internals

  /// `work`'s value, or nil once `timeout` has passed or the task is cancelled. Returns only
  /// after `work` has ended, so a child stopped by its teardown is gone, not just signalled.
  static func bounded<Value: Sendable>(
    _ timeout: Duration, _ work: @escaping @Sendable () async throws -> Value?
  ) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
      group.addTask { (try? await work()) ?? nil }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      // Cancelling a running `Subprocess.run` runs the configuration's teardown sequence.
      group.cancelAll()
      return first
    }
  }

  static func configuration(
    _ executable: URL, arguments: [String], environment: [String: String]?, directory: URL?,
    stop: Stop
  ) -> Configuration {
    var options = PlatformOptions()
    options.processGroupID = 0
    options.teardownSequence = teardown(stop)
    return Configuration(
      executable: .path(FilePath(executable.path(percentEncoded: false))),
      arguments: Arguments(arguments),
      environment: environment.map { values in
        .custom(
          Dictionary(
            values.compactMap { key, value in Environment.Key(rawValue: key).map { ($0, value) } },
            uniquingKeysWith: { _, last in last }))
      } ?? .inherit,
      workingDirectory: directory.map { FilePath($0.path(percentEncoded: false)) },
      platformOptions: options)
  }

  /// Every step to the group, for a child stopped at the deadline or with its task. The
  /// `SIGKILL` Subprocess appends to the last step follows that step's target, so it reaches the
  /// group too.
  static func teardown(_ stop: Stop) -> [TeardownStep] {
    switch stop {
    case .terminate(let grace):
      [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: grace)]
    case .kill:
      [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .milliseconds(500))]
    }
  }
}

extension ChildProcess.Finished {
  init(_ status: TerminationStatus, _ output: Data, _ error: Data) {
    switch status {
    case .exited(let code): (exitCode, signal) = (code, nil)
    case .signaled(let signal): (exitCode, self.signal) = (nil, signal)
    }
    standardOutput = output
    standardError = error
  }
}

/// Newline-delimited lines out of arbitrary chunks. A line is never empty and never carries its
/// newline.
struct LineBuffer {
  private var buffer = Data()

  mutating func append(_ chunk: Data) -> [Data] {
    buffer.append(chunk)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer.removeSubrange(buffer.startIndex...newline)
      if !line.isEmpty { lines.append(Data(line)) }
    }
    return lines
  }
}
