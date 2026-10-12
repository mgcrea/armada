import Foundation

/// When someone starts talking over a spoken reply, decided from the microphone's level alone.
///
/// The microphone it reads has voice processing on, so the reply it plays is cancelled out of
/// it. Measured on 2026-10-12 on a MacBook Pro's own microphone and speakers: a reply that raised
/// the plain microphone about 21 dB above the room raised the processed one about 5 dB above a
/// -62 dBFS room. A voice has to clear `threshold`, well above that, for `hold` seconds
/// together, so a cough or a door is not an answer.
///
/// **`warmUp` is ignored entirely,** counted from the first level fed, which `VoiceCapture` holds
/// back until the reply has started to sound. The echo canceller lets the start of a reply through
/// until it has heard some of it. How long that takes is not measured; neither are `threshold`
/// and `hold` against a voice. All three are first guesses.
///
/// It reports once. A reply is talked over once: after that the microphone belongs to the answer.
public struct VoiceOnset: Sendable {
  public var threshold: Float
  public var hold: TimeInterval
  public var warmUp: TimeInterval

  private var startedAt: TimeInterval?
  private var loudSince: TimeInterval?
  private var reported = false

  public init(threshold: Float = -40, hold: TimeInterval = 0.25, warmUp: TimeInterval = 0.6) {
    self.threshold = threshold
    self.hold = hold
    self.warmUp = warmUp
  }

  /// Feed one level reading, in dBFS, taken at `time` seconds on any monotonic clock. True the
  /// one time a voice has been held long enough.
  public mutating func feed(level: Float, at time: TimeInterval) -> Bool {
    guard !reported else { return false }
    let start = startedAt ?? time
    startedAt = start
    guard time - start >= warmUp - 1e-9, level > threshold else {
      loudSince = nil
      return false
    }
    let since = loudSince ?? time
    loudSince = since
    // A hair of slack here and above, so a span that is a whole number of readings is not lost
    // to rounding.
    guard time - since >= hold - 1e-9 else { return false }
    reported = true
    return true
  }
}
