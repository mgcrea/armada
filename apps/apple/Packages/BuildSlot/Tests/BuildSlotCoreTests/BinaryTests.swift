import BuildSlotCore
import Darwin
import Foundation
import Testing

// The `buildslot` binary end to end: two processes queueing on one slot, the lines the waiter
// prints, exit statuses and signals. Each test has its own lock folder and a one-slot settings
// file with the memory rule off, so the queue is only what the test makes it. Waits are on
// what the processes show (`status --json`, their stderr, marker files), never fixed sleeps.
struct BinaryTests {
  /// Built beside the test bundle. `Bundle(for:)` rather than `Bundle.allBundles`: under
  /// `swiftpm-testing-helper` (Swift Testing) the `.xctest` bundle is not in that list.
  static let binary = Bundle(for: Run.self).bundleURL.deletingLastPathComponent()
    .appending(path: "buildslot").path

  /// One test's lock folder, settings and a working folder outside any git checkout, so the
  /// same-tree nesting rule never lets one test process through behind another.
  struct Sandbox {
    let root: URL
    var environment: [String: String]

    init(lockDir: String? = nil) {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("buildslot-binary-\(UUID().uuidString)", isDirectory: true)
      try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let settings = root.appendingPathComponent("settings.json")
      try! Data(#"{"version":1,"slots":1,"memoryRule":"off"}"#.utf8).write(to: settings)
      var environment = ProcessInfo.processInfo.environment
      // The test run may itself be a queued build: its holder variable must not let these
      // processes through.
      environment[Nesting.holderVariable] = nil
      environment["ARMADA_BUILDSLOT"] = nil
      environment["ARMADA_BUILDSLOT_DIR"] = lockDir ?? root.appendingPathComponent("locks").path
      environment["ARMADA_BUILDSLOT_SETTINGS"] = settings.path
      self.environment = environment
    }

    func path(_ name: String) -> String { root.appendingPathComponent(name).path }
  }

  /// A `buildslot` process in a process group of its own, so a signal sent to its group never
  /// reaches the test runner, with its stdout and stderr in files.
  final class Run {
    let pid: pid_t
    let stdoutPath: String
    let stderrPath: String
    private(set) var status: Int32?
    private(set) var endedAt: Date?

    init(_ arguments: [String], sandbox: Sandbox, cwd: String? = nil) {
      let id = UUID().uuidString
      stdoutPath = sandbox.path("out-\(id)")
      stderrPath = sandbox.path("err-\(id)")
      let directory = cwd ?? sandbox.root.path

      var actions: posix_spawn_file_actions_t? = nil
      posix_spawn_file_actions_init(&actions)
      defer { posix_spawn_file_actions_destroy(&actions) }
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      posix_spawn_file_actions_addopen(&actions, 1, stdoutPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
      posix_spawn_file_actions_addopen(&actions, 2, stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
      posix_spawn_file_actions_addchdir_np(&actions, directory)

      var attributes: posix_spawnattr_t? = nil
      posix_spawnattr_init(&attributes)
      defer { posix_spawnattr_destroy(&attributes) }
      var defaults = sigset_t()
      sigfillset(&defaults)
      var mask = sigset_t()
      sigemptyset(&mask)
      posix_spawnattr_setsigdefault(&attributes, &defaults)
      posix_spawnattr_setsigmask(&attributes, &mask)
      posix_spawnattr_setpgroup(&attributes, 0)
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

      let argv = ([BinaryTests.binary] + arguments).map { strdup($0) } + [nil]
      defer { for pointer in argv { free(pointer) } }
      let envp = sandbox.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer { for pointer in envp { free(pointer) } }
      var pid: pid_t = 0
      let result = posix_spawn(&pid, BinaryTests.binary, &actions, &attributes, argv, envp)
      precondition(result == 0, "posix_spawn: \(String(cString: strerror(result)))")
      self.pid = pid
    }

    deinit {
      // A test that failed part way leaves nothing running: the whole group, children too.
      if status == nil {
        kill(-pid, SIGKILL)
        _ = poll()
      }
    }

    var stderr: String { (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? "" }
    var stdout: String { (try? String(contentsOfFile: stdoutPath, encoding: .utf8)) ?? "" }

    /// Reaps the process if it has ended; true once it has.
    func poll() -> Bool {
      if status != nil { return true }
      var raw: Int32 = 0
      let result = waitpid(pid, &raw, WNOHANG)
      guard result == pid else { return false }
      status = raw
      endedAt = .now
      return true
    }

    /// Waits for the process to end, at most `timeout` seconds.
    @discardableResult
    func wait(timeout: TimeInterval = 20) -> Bool {
      until(timeout: timeout) { self.poll() }
    }

    var exitCode: Int32? { status.flatMap { exited($0) ? exitStatus($0) : nil } }
    var signal: Int32? { status.flatMap { signalled($0) ? termSignal($0) : nil } }
  }

  // MARK: Helpers

  private func shell(_ script: String) -> [String] { ["run", "--", "/bin/sh", "-c", script] }

  /// Polls `condition` every 20 ms until it holds or `timeout` passes.
  @discardableResult
  static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if condition() { return true }
      usleep(20_000)
    }
    return condition()
  }

  private func until(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    Self.until(timeout: timeout, condition)
  }

  struct Status: Decodable {
    struct Entry: Decodable {
      var slot: Int?
      var pid: Int32
      var label: String
      var cwd: String
    }
    var pressure: String
    var holders: [Entry]
    var waiters: [Entry]
  }

  private func status(_ sandbox: Sandbox) -> Status? {
    let run = Run(["status", "--json"], sandbox: sandbox)
    guard run.wait(timeout: 10), run.exitCode == 0 else { return nil }
    return try? JSONDecoder().decode(Status.self, from: Data(run.stdout.utf8))
  }

  /// Starts a holder and returns once `status --json` lists it.
  private func holder(_ script: String, sandbox: Sandbox, cwd: String? = nil) throws -> Run {
    let run = Run(shell(script), sandbox: sandbox, cwd: cwd)
    let listed = until { status(sandbox)?.holders.contains { $0.pid == run.pid } == true }
    try #require(listed, "the holder never showed in status; stderr: \(run.stderr)")
    return run
  }

  /// Starts a process that must queue, and returns once it says it is waiting.
  private func waiter(_ script: String, sandbox: Sandbox) throws -> Run {
    let run = Run(shell(script), sandbox: sandbox)
    let waiting = until { run.stderr.contains("waiting for a slot") }
    try #require(waiting, "never said it was waiting; stderr: \(run.stderr)")
    return run
  }

  // MARK: Queueing

  @Test func secondWaitsAndSaysWhy() throws {
    let sandbox = Sandbox()
    let repo = "/tmp/a-repo"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    let a = try holder("sleep 2", sandbox: sandbox, cwd: repo)
    let b = try waiter("exit 0", sandbox: sandbox)
    #expect(until(timeout: 20) { a.poll() && b.poll() })
    #expect(a.exitCode == 0)
    #expect(b.exitCode == 0)
    let stderr = b.stderr
    #expect(stderr.contains("waiting for a slot (1 of 1 busy), held by a-repo (pid \(a.pid)"))
    #expect(stderr.contains("Queued, not hung."))
    #expect(stderr.contains("buildslot: got slot 0 after"))
    let endA = try #require(a.endedAt)
    let endB = try #require(b.endedAt)
    #expect(endB >= endA)
  }

  @Test func killNineFreesAtOnce() throws {
    let sandbox = Sandbox()
    let a = try holder("sleep 30", sandbox: sandbox)
    let b = try waiter("exit 0", sandbox: sandbox)
    #expect(kill(a.pid, SIGKILL) == 0)
    let killedAt = Date.now
    let got = until(timeout: 5) { b.stderr.contains("got slot 0") }
    let took = Date.now.timeIntervalSince(killedAt)
    #expect(got)
    #expect(took < 1.5, "took \(took) s")
    #expect(b.wait())
    #expect(b.exitCode == 0)
    // The orphaned `sleep 30` is still in A's group.
    kill(-a.pid, SIGKILL)
  }

  @Test func statusJSON() throws {
    let sandbox = Sandbox()
    let a = try holder("sleep 30", sandbox: sandbox)
    let status = try #require(status(sandbox))
    #expect(status.holders.count == 1)
    #expect(status.holders.first?.slot == 0)
    #expect(status.holders.first?.pid == a.pid)
    #expect(status.waiters.isEmpty)
    #expect(["normal", "warning", "critical"].contains(status.pressure))
    kill(-a.pid, SIGKILL)
  }

  // MARK: Exit status

  @Test func exitCodePassesThrough() {
    let run = Run(shell("exit 7"), sandbox: Sandbox())
    #expect(run.wait())
    #expect(run.exitCode == 7)
    // A slot taken at once prints nothing.
    #expect(run.stderr.isEmpty)
  }

  @Test func signalDeathReRaised() {
    let run = Run(shell("kill -TERM $$"), sandbox: Sandbox())
    #expect(run.wait())
    #expect(run.signal == SIGTERM)
  }

  // MARK: Signals

  @Test func interruptReachesChildOnce() throws {
    let sandbox = Sandbox()
    let log = sandbox.path("interrupts")
    let ready = sandbox.path("ready")
    let script = """
      trap 'echo int >> "\(log)"' INT
      : > "\(ready)"
      n=0; while [ $n -lt 10 ]; do sleep 0.1; n=$((n+1)); done
      exit 130
      """
    let run = Run(shell(script), sandbox: sandbox)
    try #require(until { FileManager.default.fileExists(atPath: ready) })
    #expect(kill(-run.pid, SIGINT) == 0)
    #expect(run.wait())
    #expect(run.exitCode == 130)
    let lines = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    #expect(lines == "int\n")
  }

  @Test func termForwarded() throws {
    let sandbox = Sandbox()
    let log = sandbox.path("terms")
    let ready = sandbox.path("ready")
    let script = """
      trap 'echo term >> "\(log)"; exit 143' TERM
      : > "\(ready)"
      n=0; while [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
      exit 0
      """
    let run = Run(shell(script), sandbox: sandbox)
    try #require(until { FileManager.default.fileExists(atPath: ready) })
    #expect(kill(run.pid, SIGTERM) == 0)
    #expect(run.wait())
    #expect(run.signal == SIGTERM || run.exitCode == 143)
    let lines = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    #expect(lines == "term\n")
  }

  // MARK: Passing through

  @Test func nestedPassesThrough() {
    var sandbox = Sandbox()
    sandbox.environment["BUILDSLOT"] = Self.binary
    let run = Run(shell(#""$BUILDSLOT" run -- /bin/echo inner"#), sandbox: sandbox)
    #expect(run.wait(timeout: 5))
    #expect(run.exitCode == 0)
    #expect(run.stdout == "inner\n")
    #expect(!run.stderr.contains("waiting"))
  }

  @Test func passThroughNeverWaits() throws {
    let sandbox = Sandbox()
    let a = try holder("sleep 30", sandbox: sandbox)
    let run = Run(["--as", "swift", "build", "--show-bin-path"], sandbox: sandbox)
    #expect(run.wait(timeout: 10))
    #expect(!run.stderr.contains("buildslot:"))
    kill(-a.pid, SIGKILL)
  }

  @Test func offPassesThrough() throws {
    var sandbox = Sandbox()
    let a = try holder("sleep 30", sandbox: sandbox)
    sandbox.environment["ARMADA_BUILDSLOT"] = "off"
    let run = Run(shell("exit 4"), sandbox: sandbox)
    #expect(run.wait(timeout: 5))
    #expect(run.exitCode == 4)
    #expect(run.stderr.isEmpty)
    kill(-a.pid, SIGKILL)
  }

  @Test func unwritableLockDirRunsUnqueued() {
    let run = Run(shell("exit 3"), sandbox: Sandbox(lockDir: "/System/forbidden"))
    #expect(run.wait())
    #expect(run.exitCode == 3)
    #expect(run.stderr.hasPrefix("buildslot: "))
    #expect(run.stderr.contains("; running unqueued."))
  }

  @Test func badUsageExits64() {
    for arguments in [[], ["--as", "cc"], ["run"], ["frobnicate"]] {
      let run = Run(arguments, sandbox: Sandbox())
      #expect(run.wait())
      #expect(run.exitCode == 64, "\(arguments)")
    }
  }
}

// The wait(2) macros, which Swift does not import.
private func exited(_ status: Int32) -> Bool { status & 0x7f == 0 }
private func exitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
private func signalled(_ status: Int32) -> Bool { status & 0x7f != 0 && status & 0x7f != 0x7f }
private func termSignal(_ status: Int32) -> Int32 { status & 0x7f }
