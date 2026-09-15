import Foundation

/// When a spoken question has ended, decided from the microphone's level alone.
///
/// **Why not `SpeechDetector`.** Speech's own detector reported nothing at all when the
/// 2026-09-15 spike fed it a recorded question, with results requested, so press mode could
/// not rest on it without a measurement on a live microphone. A level threshold is the plain
/// alternative: it needs no model, it is the same on every Mac, and it is testable here.
///
/// **The rules.** Nothing counts until the level first rises above `speechThreshold`: a
/// question that has not started cannot have ended. After that, `silenceDuration` of level
/// below the threshold ends it. `noSpeechTimeout` gives up on a press followed by nothing,
/// and `maximumDuration` ends a question that never pauses, so a noisy room cannot hold the
/// microphone open.
public struct SilenceDetector: Sendable {
  public enum Verdict: Equatable, Sendable {
    case listening
    /// Speech was heard and has stopped.
    case ended
    /// Nothing was said.
    case gaveUp
  }

  public var speechThreshold: Float
  public var silenceDuration: TimeInterval
  public var noSpeechTimeout: TimeInterval
  public var maximumDuration: TimeInterval

  private var startedAt: TimeInterval?
  private var heardSpeech = false
  private var quietSince: TimeInterval?

  public init(
    speechThreshold: Float = -42, silenceDuration: TimeInterval = 1.5,
    noSpeechTimeout: TimeInterval = 6, maximumDuration: TimeInterval = 45
  ) {
    self.speechThreshold = speechThreshold
    self.silenceDuration = silenceDuration
    self.noSpeechTimeout = noSpeechTimeout
    self.maximumDuration = maximumDuration
  }

  /// Feed one level reading, in dBFS, taken at `time` seconds on any monotonic clock.
  public mutating func feed(level: Float, at time: TimeInterval) -> Verdict {
    let start = startedAt ?? time
    startedAt = start
    let loud = level > speechThreshold

    if !heardSpeech {
      if loud {
        heardSpeech = true
      } else {
        return time - start >= noSpeechTimeout ? .gaveUp : .listening
      }
    }
    if time - start >= maximumDuration { return .ended }
    if loud {
      quietSince = nil
      return .listening
    }
    let quiet = quietSince ?? time
    quietSince = quiet
    return time - quiet >= silenceDuration ? .ended : .listening
  }

  /// The RMS level of a buffer of samples in -1...1, in dBFS, floored at -160 for silence.
  public static func level(of samples: some Collection<Float>) -> Float {
    guard !samples.isEmpty else { return -160 }
    let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
    guard meanSquare > 0 else { return -160 }
    return max(-160, 10 * log10(meanSquare))
  }
}
