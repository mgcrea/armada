import Foundation
import os

/// A full-function evaluation window, started by a person and held in memory.
///
/// Unlicensed, Armada watches nothing — no sessions, no usage, no mouse bindings —
/// so nobody could find out whether it reads *their* accounts and *their* sessions
/// correctly before paying. A refund is the trial for the purchase decision; this
/// is for the technical one, which is a different question and is asked first.
///
/// Three properties, each load-bearing, all bastion's:
///
/// **Full function.** Every account, every session, every action. A crippled demo
/// answers the wrong question — the thing being evaluated is whether this works on
/// this Mac against these folders, and a degraded mode cannot answer that.
///
/// **In memory.** The deadline dies with the process, so there is no expiry state
/// on disk, nothing to invalidate, and no "one trial per machine" fiction to
/// pretend to enforce. Quitting and reopening starts another one. Somebody
/// relaunching the app every half hour to avoid the price was never going to buy
/// it, and the code to stop them would cost more than they are worth.
///
/// **Started by hand.** `start()` is reachable only from a button. A trial that
/// armed itself at login would burn in a menu bar nobody was looking at.
nonisolated enum Trial {
  static let duration: TimeInterval = 30 * 60

  /// Locked rather than a bare static: the reaper below reads it from a dispatch
  /// callback, and a stored `Date?` is not thread-safe the way `UserDefaults` is.
  private static let state = OSAllocatedUnfairLock<Date?>(initialState: nil)

  /// Arm the window, or extend nothing. Starting a trial that is already running
  /// returns the existing deadline rather than pushing it out, so leaning on the
  /// button cannot stretch the half hour.
  @discardableResult
  static func start() -> Date {
    let (deadline, isFresh) = state.withLock { stored -> (Date, Bool) in
      if let stored, stored > Date() { return (stored, false) }
      let next = Date().addingTimeInterval(duration)
      stored = next
      return (next, true)
    }
    if isFresh {
      // `wallDeadline`, not `deadline`: the dispatch clock stops while the Mac is
      // asleep and `Date` does not, so a monotonic timer would hand out a free
      // trial across a lunch break with the lid closed.
      DispatchQueue.main.asyncAfter(wallDeadline: .now() + duration) { expire() }
    }
    return deadline
  }

  /// Stop watching when the window closes.
  private static func expire() {
    // A key entered during the window keeps everything running. The half hour
    // bought the answer it was for; taking the session list away from somebody
    // who has just paid, because a timer they have already satisfied went off,
    // would be indefensible.
    guard !LicenseStore.isLicensed else { return }
    MainActor.assumeIsolated { EntitlementMonitor.shared.apply() }
  }

  static var deadline: Date? { state.withLock { $0 } }

  static var isActive: Bool {
    guard let deadline else { return false }
    return deadline > Date()
  }

  /// Whether a window was opened this launch, expired or not. What the locked
  /// card needs to tell "not tried yet" from "tried, and it ran out" — two states
  /// that want different words and a different button.
  static var hasRun: Bool { deadline != nil }

  static var remaining: TimeInterval {
    guard let deadline else { return 0 }
    return max(0, deadline.timeIntervalSinceNow)
  }

  /// Minutes, rounded up, so a window with forty seconds left reads "1 minute"
  /// rather than "0 minutes" while it is still working.
  static var remainingMinutes: Int { Int(ceil(remaining / 60)) }

  static var remainingText: String {
    let minutes = remainingMinutes
    return minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
  }
}

/// What this Mac may do right now, as one answer with the reason attached.
///
/// Several places ask: the watchers' switch in `EntitlementMonitor`, the popover,
/// the main window and the licence pane. Joining a key and a trial window at each
/// of them separately is how a popover ends up saying "unlicensed" above a session
/// list that is happily updating.
nonisolated enum Entitlement {
  case licensed(License)
  case trial
  case refused(String)

  static var current: Entitlement {
    switch LicenseStore.check {
    case .valid(let license):
      return .licensed(license)
    case .refused(let reason):
      // A key first, always. Someone who has paid must never be told about a
      // trial, and a trial armed before a key was entered must not outrank it.
      return Trial.isActive ? .trial : .refused(reason)
    }
  }

  var isEntitled: Bool {
    if case .refused = self { return false }
    return true
  }
}
