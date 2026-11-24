import BuildSlotCore
import Darwin
import Foundation

/// The child a holder forwards SIGTERM and SIGHUP to; 0 until it exists. Global because a
/// signal handler is a C function and captures nothing.
nonisolated(unsafe) private var forwardTarget: pid_t = 0

private func forwardSignal(_ signal: Int32) {
  let child = forwardTarget
  // Never 0: `kill(0, …)` would signal this whole process group.
  if child > 0 { kill(child, signal) }
}

/// Runs the real tool while this process keeps the slot. A child rather than exec, because exec
/// would leave the lock with whatever the tool becomes, for some invocations a long-lived
/// process. The child stays in this process group, so a terminal's ^C and a kill aimed at the
/// group reach it directly.
enum ChildRunner {
  /// Spawns `path`, waits for it and exits as it did. `arguments` is the child's whole argv.
  static func run(path: String, arguments: [String], environment: [String: String]) -> Never {
    var environment = environment
    environment[Nesting.holderVariable] = String(getpid())

    // TERM and HUP stay blocked until the child's pid is known, so one that lands during the
    // spawn is forwarded once unblocked rather than lost.
    var forwarded = sigset_t()
    sigemptyset(&forwarded)
    sigaddset(&forwarded, SIGTERM)
    sigaddset(&forwarded, SIGHUP)
    var originalMask = sigset_t()
    sigprocmask(SIG_BLOCK, &forwarded, &originalMask)

    // ^C reaches the child through the group; forwarding it too would deliver it twice, and a
    // second SIGINT makes SwiftPM and xcodebuild abort hard instead of cancelling. An ignored
    // signal stays ignored across exec, and a non-interactive shell cannot even trap one ignored
    // on entry, so the child gets these two back at their default, unless they were already
    // ignored when this process started (a background job's ^C): then the child keeps that.
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGINT, SIGQUIT] where !isIgnored(Darwin.signal(signal, SIG_IGN)) {
      sigaddset(&defaults, signal)
    }
    // A signal ignored on entry (HUP under `nohup`) stays ignored, for this process and the
    // child alike, rather than forwarded.
    var action = sigaction()
    action.__sigaction_u.__sa_handler = forwardSignal
    action.sa_flags = SA_RESTART
    sigemptyset(&action.sa_mask)
    for signal in [SIGTERM, SIGHUP] {
      var current = sigaction()
      sigaction(signal, nil, &current)
      if !isIgnored(current.__sigaction_u.__sa_handler) { sigaction(signal, &action, nil) }
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &originalMask)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var child: pid_t = 0
    let result = posix_spawn(&child, path, nil, &attributes, argv, envp)
    guard result == 0 else {
      say("buildslot: cannot run \(path): \(String(cString: strerror(result))).")
      exit(127)
    }
    forwardTarget = child
    sigprocmask(SIG_SETMASK, &originalMask, nil)

    var status: Int32 = 0
    while waitpid(child, &status, 0) < 0 {
      guard errno == EINTR else {
        say("buildslot: lost \(path) (\(String(cString: strerror(errno)))).")
        exit(1)
      }
    }
    exitAs(status)
  }

  /// Replaces this process with `path`: a pass-through needs no wrapper and no slot.
  static func replace(path: String, arguments: [String]) -> Never {
    let argv = arguments.map { strdup($0) } + [nil]
    execv(path, argv)
    say("buildslot: cannot run \(path): \(String(cString: strerror(errno))).")
    exit(127)
  }

  private static func isIgnored(_ handler: sig_t?) -> Bool {
    unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
  }

  /// Signals a caller expects to see as the cause of death, re-raised so `WIFSIGNALED` holds.
  private static let reraised: Set<Int32> = [SIGINT, SIGTERM, SIGHUP, SIGKILL, SIGPIPE]

  /// Exits with the child's code, or dies of the signal it died of. Crash signals (ABRT, SEGV,
  /// BUS, ILL, TRAP, FPE, QUIT) and any other become `128 + signal` instead: re-raising those
  /// would have macOS write a crash report blaming `buildslot` each time a test crashes.
  private static func exitAs(_ status: Int32) -> Never {
    let signal = status & 0x7f
    if signal == 0 { exit((status >> 8) & 0xff) }
    if reraised.contains(signal) {
      Darwin.signal(signal, SIG_DFL)
      var unblock = sigset_t()
      sigemptyset(&unblock)
      sigaddset(&unblock, signal)
      sigprocmask(SIG_UNBLOCK, &unblock, nil)
      raise(signal)
    }
    exit(128 + signal)
  }
}
