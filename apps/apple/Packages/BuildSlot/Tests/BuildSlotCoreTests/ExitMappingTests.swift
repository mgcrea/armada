import BuildSlotCore
import Darwin
import Testing

// How a holder ends after its child, from `waitpid` statuses built by hand: crashing a real
// child to get one would have macOS write a crash report for it on every run.
struct ExitMappingTests {
  /// A status as `waitpid` reports a child killed by `signal`.
  private func killed(by signal: Int32) -> Int32 { signal }
  /// A status as `waitpid` reports a child that called `exit(code)`.
  private func exited(_ code: Int32) -> Int32 { code << 8 }

  @Test(arguments: [0, 1, 7, 130, 255] as [Int32])
  func exitCodePassesOn(code: Int32) {
    #expect(ExitMapping.outcome(forWaitStatus: exited(code)) == .exit(code))
  }

  @Test(arguments: [SIGINT, SIGTERM, SIGHUP, SIGKILL, SIGPIPE])
  func deathSignalsAreRaised(signal: Int32) {
    #expect(ExitMapping.outcome(forWaitStatus: killed(by: signal)) == .raise(signal))
  }

  @Test(arguments: [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGQUIT])
  func crashSignalsBecomeExitCodes(signal: Int32) {
    #expect(ExitMapping.outcome(forWaitStatus: killed(by: signal)) == .exit(128 + signal))
  }

  // The core-dump flag (0x80) sits beside the signal number and must not change it.
  @Test func coreDumpFlagIsIgnored() {
    #expect(ExitMapping.outcome(forWaitStatus: SIGSEGV | 0x80) == .exit(128 + SIGSEGV))
  }
}
