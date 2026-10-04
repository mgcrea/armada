import Foundation

/// Holds the power assertion `KeepAwake` describes, and gives it back.
///
/// On its own tick rather than the watchers', for the reason `PromptCacheNotifier`
/// gives: the condition has to be re-read when nothing is written, because the
/// `.runningTool` cap expires in silence. Thirty seconds is nothing against an idle
/// timer measured in minutes, either way: a turn that starts is covered long before
/// the Mac would have slept, and one that ends hands sleep back half a minute late.
///
/// A refused licence needs no check here. `EntitlementMonitor` stops the watchers,
/// every count goes to zero, and the assertion goes with them on the next tick.
@MainActor
final class KeepAwakeController {
  static let shared = KeepAwakeController()
  static let interval: TimeInterval = 30

  private var timer: DispatchSourceTimer?
  private var activity: NSObjectProtocol?
  /// What `activity` was taken with, so a change of rung swaps the assertion rather
  /// than keeping the old one until the work stops.
  private var held: ProcessInfo.ActivityOptions?

  func start() {
    guard timer == nil else { return }
    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now(), repeating: Self.interval)
    tick.setEventHandler { MainActor.assumeIsolated { self.evaluate() } }
    tick.resume()
    timer = tick
  }

  /// Re-reads at once. The settings pane calls this, so a rung chosen while an agent
  /// is working shows up in `pmset -g assertions` before the person goes to look.
  func evaluate() {
    let rung =
      UserDefaults.standard.string(forKey: KeepAwake.defaultsKey).flatMap(KeepAwake.init)
      ?? .off
    let sessions = Accounts.shared.all.flatMap(\.sessions.sessions)
    let working = KeepAwake.isWorking(
      claudeWriting: sessions.count { $0.state == .working },
      claudeToolCalls: sessions.filter { $0.state == .runningTool }.map(\.lastWrite),
      codexWorking: CodexAccounts.shared.workingCount,
      grokWorking: GrokAccounts.shared.workingCount,
      now: Date())
    hold(working ? rung.options : nil)
  }

  private func hold(_ options: ProcessInfo.ActivityOptions?) {
    guard options != held else { return }
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = options.map {
      // The reason is what `pmset -g assertions` prints beside Armada's name, so it
      // says why rather than what.
      ProcessInfo.processInfo.beginActivity(options: $0, reason: "An agent session is working")
    }
    held = options
  }
}
