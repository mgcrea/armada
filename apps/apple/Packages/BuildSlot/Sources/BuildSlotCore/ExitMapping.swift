import Darwin

/// How a holder ends once its child has: with the child's code, or by the signal it died of.
public enum ExitMapping {
  public enum Outcome: Equatable, Sendable {
    case exit(Int32)
    /// Reset the signal to its default and raise it, so the caller sees the same `WIFSIGNALED`.
    case raise(Int32)
  }

  /// Signals a caller expects to see as the cause of death.
  static let reraised: Set<Int32> = [SIGINT, SIGTERM, SIGHUP, SIGKILL, SIGPIPE]

  /// From a `waitpid` status. Crash signals (ABRT, SEGV, BUS, ILL, TRAP, FPE, QUIT) and any other
  /// become `128 + signal`: re-raising those would have macOS write a crash report blaming
  /// `buildslot` each time a test crashes.
  public static func outcome(forWaitStatus status: Int32) -> Outcome {
    let signal = status & 0x7f
    if signal == 0 { return .exit((status >> 8) & 0xff) }
    return reraised.contains(signal) ? .raise(signal) : .exit(128 + signal)
  }
}
