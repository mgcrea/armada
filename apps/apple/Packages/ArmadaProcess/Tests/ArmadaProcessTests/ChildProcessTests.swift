import Darwin
import Foundation
import Testing

@testable import ArmadaProcess

@Suite struct ChildProcessTests {
  private let sh = URL(filePath: "/bin/sh")

  private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  /// Whether `pid` is still a process. Only for pids these tests wrote down themselves, a moment
  /// ago: a reused number would read as alive, never as gone.
  private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  private func pid(in file: URL) -> pid_t? {
    (try? String(contentsOf: file, encoding: .utf8))
      .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "armada-process-\(UUID().uuidString)", directoryHint: .notDirectory)
  }

  // MARK: - collect

  @Test func collectReturnsStatusAndBothStreams() async throws {
    let finished = try #require(
      await ChildProcess.collect(
        sh, arguments: ["-c", "printf out; printf err >&2; exit 3"], timeout: .seconds(5)))
    #expect(finished.exitCode == 3)
    #expect(finished.signal == nil)
    #expect(!finished.succeeded)
    #expect(String(decoding: finished.standardOutput, as: UTF8.self) == "out")
    #expect(String(decoding: finished.standardError, as: UTF8.self) == "err")
  }

  @Test func collectPassesTheEnvironmentAndDirectoryGiven() async throws {
    let finished = try #require(
      await ChildProcess.collect(
        sh, arguments: ["-c", #"printf '%s %s' "$ARMADA_PROBE" "$PWD""#],
        environment: ["ARMADA_PROBE": "seen"], directory: URL(filePath: "/private/tmp"),
        timeout: .seconds(5)))
    #expect(String(decoding: finished.standardOutput, as: UTF8.self) == "seen /private/tmp")
  }

  @Test func discardedOutputStillReportsTheStatus() async throws {
    let finished = try #require(
      await ChildProcess.collect(
        sh, arguments: ["-c", "printf out; exit 4"], output: .discard, timeout: .seconds(5)))
    #expect(finished.exitCode == 4)
    #expect(finished.standardOutput.isEmpty)
  }

  @Test func aMissingExecutableIsNil() async {
    #expect(
      await ChildProcess.collect(URL(filePath: "/nonexistent/armada"), timeout: .seconds(5))
        == nil)
  }

  @Test func theDeadlineStopsTheWholeGroup() async throws {
    // The shell starts a child of its own and waits on it; both must be gone at the deadline.
    let file = scratch()
    defer { try? FileManager.default.removeItem(at: file) }
    let start = ContinuousClock.now
    let finished = await ChildProcess.collect(
      sh, arguments: ["-c", "sleep 30 & echo $! > \"$1\"; wait", "sh", file.path],
      timeout: .seconds(1),
      stop: .terminate(grace: .milliseconds(500)))
    #expect(finished == nil)
    #expect(seconds(since: start) < 4)
    let grandchild = try #require(pid(in: file))
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!alive(grandchild))
  }

  @Test func aChildThatIgnoresSIGTERMIsKilledAfterTheGrace() async {
    let start = ContinuousClock.now
    let finished = await ChildProcess.collect(
      sh, arguments: ["-c", "trap '' TERM; sleep 30"], timeout: .milliseconds(300),
      stop: .terminate(grace: .milliseconds(500)))
    #expect(finished == nil)
    #expect(seconds(since: start) < 4)
  }

  @Test func cancellingTheTaskStopsTheChild() async throws {
    let file = scratch()
    defer { try? FileManager.default.removeItem(at: file) }
    let sh = self.sh
    let task = Task {
      await ChildProcess.collect(
        sh, arguments: ["-c", "echo $$ > \"$1\"; sleep 30", "sh", file.path], timeout: .seconds(60))
    }
    var child: pid_t?
    for _ in 0..<50 where child == nil {
      try? await Task.sleep(for: .milliseconds(50))
      child = pid(in: file)
    }
    let pid = try #require(child)
    let start = ContinuousClock.now
    task.cancel()
    #expect(await task.value == nil)
    #expect(seconds(since: start) < 4)
    #expect(!alive(pid))
  }

  @Test func anAlreadyCancelledTaskStartsNothing() async {
    let file = scratch()
    let sh = self.sh
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await ChildProcess.collect(
        sh, arguments: ["-c", "touch \"$1\"", "sh", file.path], timeout: .seconds(5))
    }
    #expect(await task.value == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func theChildLeadsItsOwnGroupNotArmadas() async throws {
    let finished = try #require(
      await ChildProcess.collect(
        sh, arguments: ["-c", "echo $$; ps -o pgid= -p $$"], timeout: .seconds(5)))
    let numbers = String(decoding: finished.standardOutput, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
    try #require(numbers.count == 2)
    #expect(numbers[1] == numbers[0])
    #expect(numbers[1] != getpgrp())
  }

  // MARK: - ask

  @Test func askReturnsTheFirstLineThatAnswers() async {
    // Echoes stdin back with a prefix, so a line answers only after the request was written.
    let reply = await ChildProcess.ask(
      sh, arguments: ["-c", "echo noise; while read line; do echo \"got $line\"; done"],
      input: Data("one\ntwo\n".utf8), timeout: .seconds(5)
    ) { line -> String? in
      let text = String(decoding: line, as: UTF8.self)
      return text.hasSuffix("two") ? text : nil
    }
    #expect(reply == "got two")
  }

  @Test func askStopsAChildThatOutlivesItsAnswer() async throws {
    // Answers, then ignores stdin closing and SIGTERM.
    let file = scratch()
    defer { try? FileManager.default.removeItem(at: file) }
    let start = ContinuousClock.now
    let reply = await ChildProcess.ask(
      sh,
      arguments: ["-c", "echo $$ > \"$1\"; trap '' TERM; echo ready; sleep 30", "sh", file.path],
      input: Data(), timeout: .seconds(10), stop: .terminate(grace: .milliseconds(300))
    ) { line in String(decoding: line, as: UTF8.self) == "ready" ? true : nil }
    #expect(reply == true)
    #expect(seconds(since: start) < 4)
    let pid = try #require(pid(in: file))
    #expect(!alive(pid))
  }

  @Test func askIsNilWhenTheChildExitsWithoutAnswering() async {
    let reply = await ChildProcess.ask(
      sh, arguments: ["-c", "echo nothing useful"], input: Data(), timeout: .seconds(5)
    ) { _ -> Bool? in nil }
    #expect(reply == nil)
  }

  @Test func askIsNilAtTheDeadlineWhenTheChildGoesSilent() async {
    let start = ContinuousClock.now
    let reply = await ChildProcess.ask(
      sh, arguments: ["-c", "sleep 30"], input: Data(), timeout: .milliseconds(500)
    ) { _ -> Bool? in true }
    #expect(reply == nil)
    #expect(seconds(since: start) < 4)
  }

  @Test func askEndsOnExitEvenWhenAGrandchildHoldsThePipe() async {
    let start = ContinuousClock.now
    let reply = await ChildProcess.ask(
      sh, arguments: ["-c", "(sleep 3 &); exit 0"], input: Data(), timeout: .seconds(10)
    ) { _ -> Bool? in true }
    #expect(reply == nil)
    #expect(seconds(since: start) < 4)
  }

  @Test func askTakesAnAnswerFromAChildThatExitsAtOnce() async {
    let reply = await ChildProcess.ask(
      sh, arguments: ["-c", "printf 'ready\\n'; exit 0"], input: Data(), timeout: .seconds(5)
    ) { line in String(decoding: line, as: UTF8.self) == "ready" ? true : nil }
    #expect(reply == true)
  }

  @Test func cancellingAskMidReadStopsTheChild() async throws {
    let file = scratch()
    defer { try? FileManager.default.removeItem(at: file) }
    let sh = self.sh
    let task = Task {
      await ChildProcess.ask(
        sh, arguments: ["-c", "echo $$ > \"$1\"; echo noise; sleep 30", "sh", file.path],
        input: Data(), timeout: .seconds(60)
      ) { _ -> Bool? in nil }
    }
    var child: pid_t?
    for _ in 0..<50 where child == nil {
      try? await Task.sleep(for: .milliseconds(50))
      child = pid(in: file)
    }
    let pid = try #require(child)
    let start = ContinuousClock.now
    task.cancel()
    #expect(await task.value == nil)
    #expect(seconds(since: start) < 4)
    #expect(!alive(pid))
  }

  @Test func aChildThatAnsweredIsStoppedAloneNotWithItsGroup() async throws {
    // What it started, an MCP server or a hook for a real `claude`, is left to it.
    let file = scratch()
    defer { try? FileManager.default.removeItem(at: file) }
    let reply = await ChildProcess.ask(
      sh, arguments: ["-c", "sleep 30 & echo $! > \"$1\"; echo ready; wait", "sh", file.path],
      input: Data(), timeout: .seconds(10), stop: .terminate(grace: .milliseconds(300))
    ) { line in String(decoding: line, as: UTF8.self) == "ready" ? true : nil }
    #expect(reply == true)
    let grandchild = try #require(pid(in: file))
    defer { kill(grandchild, SIGKILL) }
    #expect(alive(grandchild))
  }

  // MARK: - LineBuffer

  @Test func linesSplitAcrossChunksAndSkipEmpties() {
    var lines = LineBuffer()
    #expect(lines.append(Data("a\nb".utf8)) == [Data("a".utf8)])
    #expect(lines.append(Data("c\n\nd\n".utf8)) == [Data("bc".utf8), Data("d".utf8)])
  }
}
