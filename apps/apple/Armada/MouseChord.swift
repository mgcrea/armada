import CoreGraphics
import Foundation

/// What a button press means once the combos are taken into account.
///
/// **A state machine over numbers, deliberately holding no events.** `MouseTap` owns
/// the `CGEvent`s, the timer and the Accessibility grant; this owns the rule that
/// decides what happens, which is the part that can be wrong in ways nobody sees. It
/// takes a button, the modifiers held with it and a timestamp, and answers in terms
/// the tap can carry out. That is what lets `make unit` walk every branch below
/// without a mouse, a window server or a grant.
///
/// **The cost of a combo is that a press has to wait.** Two buttons never go down in
/// the same instant, so Back + Forward can only be told from Back by waiting to see
/// what follows; and "hold Back, press Forward" cannot be told from Back at all until
/// Back comes back up. So a press that a combo could still claim is held back, and
/// the application gets it late — 70 ms late for a together binding, and on release
/// for an ordered one. A press no combo could claim is never delayed, which is what
/// keeps a Mac with no combo bound behaving exactly as it did before.
///
/// **The modifiers held when the first button goes down decide everything.** They
/// select which combos can claim the press, and they are what the combo is matched
/// against when the second button arrives. Letting the second press re-decide would
/// mean a press already held back could turn out to belong to a combo that would
/// never have held it.
nonisolated struct MouseChord {
  /// How long half a together combo waits for the other half. Long enough for two
  /// buttons a thumb rolls across, short enough that a plain Back does not feel late.
  static let window: TimeInterval = 0.070

  /// What to do with a press that was held back and is now settled.
  enum Settled: Equatable {
    /// It was a binding of its own after all — ⌥ Back, with the combo unclaimed.
    case fire(MouseBinding)
    /// It was nobody's: give it back to the application, down and, if it has already
    /// arrived, up.
    case replay
  }

  /// What to do with the event that just arrived.
  enum Action: Equatable {
    case pass
    case swallow
    /// Keep it back and start the window. The token comes back in `windowExpired`,
    /// so a timer for a hold that has already been settled is ignored.
    case hold(token: Int)
    case fire(MouseBinding)
  }

  /// One answer: what becomes of the press being held, and what becomes of the event
  /// that arrived. Both halves can happen at once — an unrelated button settles the
  /// held press and still reaches the application.
  struct Decision: Equatable {
    var settled: Settled?
    var action: Action?

    init(settled: Settled? = nil, action: Action? = nil) {
      self.settled = settled
      self.action = action
    }
  }

  /// A press held back, waiting to find out what it was.
  private struct Held {
    let button: Int
    let flags: CGEventFlags
    let at: TimeInterval
    let token: Int
  }

  private enum State {
    case idle
    case held(Held)
    /// A combo has fired and its first button is still down, so the other button
    /// fires it again rather than reaching the application.
    case running(anchor: Int, flags: CGEventFlags)
  }

  var bindings: [MouseBinding]

  private var state: State = .idle
  private var tokens = 0

  init(bindings: [MouseBinding]) {
    self.bindings = bindings
  }

  /// A press arriving.
  ///
  /// **`posted` is a press another application sent rather than the mouse, and combos
  /// never touch one.** It is not held, it does not complete a combo, and it does not
  /// repeat one. Cadence holds and replays Back and Forward the same way this does,
  /// and each app recognised only its own replays: a press Armada replayed, Cadence
  /// held and replayed with its own mark, Armada held again, and so on for ever —
  /// every replay carrying the screen position of the original click, so the pointer
  /// stayed pinned there. A press that has already been through someone else's hold
  /// has been decided; the only thing left for this one to do with it is let it go.
  /// It can still fire a single binding, so a mouse remapper that posts its buttons
  /// keeps working with those.
  mutating func press(
    button: Int, flags: CGEventFlags, at time: TimeInterval, posted: Bool = false
  ) -> Decision {
    let flags = flags.intersection(MouseBinding.watchedFlags)

    if case .running(let anchor, let anchorFlags) = state {
      // Not part of the run, and not allowed to end it: the anchor's press was
      // swallowed, so its release has to be too.
      if posted {
        return Decision(action: single(button: button, flags: flags).map { .fire($0) } ?? .pass)
      }
      if button != anchor,
        let binding = ordered(anchor: anchor, second: button, flags: anchorFlags)
      {
        return Decision(action: .fire(binding))
      }
      // The anchor pressed again without a release, or a button this pair has no
      // binding for. The run is over either way; fall through and treat this press
      // on its own.
      state = .idle
    }

    var settled: Settled?
    if case .held(let held) = state {
      if !posted, held.button != button,
        let binding = combo(first: held, second: button, at: time)
      {
        state = .running(anchor: held.button, flags: held.flags)
        return Decision(action: .fire(binding))
      }
      // Not the other half. The held press is whatever it would have been without
      // the combo — including when this *is* the same button again, which only
      // happens when its release was lost.
      settled = settle(held)
      state = .idle
    }

    let holds = !posted && wantsHold(button: button, flags: flags)
    if let binding = single(button: button, flags: flags), !holds {
      return Decision(settled: settled, action: .fire(binding))
    }
    if holds {
      tokens += 1
      state = .held(Held(button: button, flags: flags, at: time, token: tokens))
      return Decision(settled: settled, action: .hold(token: tokens))
    }
    return Decision(settled: settled, action: .pass)
  }

  mutating func release(button: Int, flags: CGEventFlags, at time: TimeInterval) -> Decision {
    switch state {
    case .held(let held) where held.button == button:
      // A click shorter than the wait, or an ordered combo that never came. The tap
      // holds the release too, so a replay gives the application both halves at once.
      state = .idle
      return Decision(settled: settle(held), action: .swallow)
    case .running(let anchor, _) where anchor == button:
      state = .idle
      return Decision(action: .swallow)
    default:
      return Decision()
    }
  }

  /// The window is up. A hold that no ordered combo could still claim settles here;
  /// one that could stays, until the button comes back up.
  mutating func windowExpired(token: Int) -> Decision {
    guard case .held(let held) = state, held.token == token else { return Decision() }
    guard !hasOrdered(anchor: held.button, flags: held.flags) else { return Decision() }
    state = .idle
    return Decision(settled: settle(held))
  }

  /// The tap is stopping, macOS disabled it, or the bindings changed under it.
  /// Whatever was held has to be let go, or an application is left with a button down
  /// and no button up.
  mutating func reset() -> Settled? {
    defer { state = .idle }
    guard case .held(let held) = state else { return nil }
    return settle(held)
  }

  /// Whether a press is being held back, which is the only state where the tap has an
  /// event copy to look after.
  var isHolding: Bool {
    if case .held = state { return true }
    return false
  }

  // MARK: - Matching

  private func settle(_ held: Held) -> Settled {
    if let binding = single(button: held.button, flags: held.flags) { return .fire(binding) }
    return .replay
  }

  private func single(button: Int, flags: CGEventFlags) -> MouseBinding? {
    bindings.first { $0.button == button && $0.modifiers.flags == flags }
  }

  /// Whether some combo could still claim a press of this button with these
  /// modifiers. This is the whole cost of the feature, so it is asked before anything
  /// is delayed.
  private func wantsHold(button: Int, flags: CGEventFlags) -> Bool {
    bindings.contains { binding in
      binding.modifiers.flags == flags && binding.comboStarts(with: button)
    }
  }

  private func hasOrdered(anchor: Int, flags: CGEventFlags) -> Bool {
    bindings.contains { binding in
      binding.modifiers.flags == flags && binding.orderedAnchor == anchor
    }
  }

  /// The combo a second button completes: together while the window is open, ordered
  /// once it has passed.
  private func combo(first: Held, second: Int, at time: TimeInterval) -> MouseBinding? {
    guard MouseBinding.comboPair == [first.button, second] else { return nil }
    if time - first.at <= Self.window,
      let binding = bindings.first(where: {
        $0.button == MouseBinding.backAndForward && $0.modifiers.flags == first.flags
      })
    {
      return binding
    }
    return ordered(anchor: first.button, second: second, flags: first.flags)
  }

  private func ordered(anchor: Int, second: Int, flags: CGEventFlags) -> MouseBinding? {
    guard MouseBinding.comboPair == [anchor, second] else { return nil }
    return bindings.first { $0.orderedAnchor == anchor && $0.modifiers.flags == flags }
  }
}
