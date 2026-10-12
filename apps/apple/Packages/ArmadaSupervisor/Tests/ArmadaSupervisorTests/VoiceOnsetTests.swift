import Testing

@testable import ArmadaSupervisor

@Suite("Voice onset")
struct VoiceOnsetTests {
  /// Feed one level every 50 ms from `start`, and return the times at which it reported a voice.
  private func heard(_ onset: inout VoiceOnset, _ levels: [Float], from start: Double = 0)
    -> [Double]
  {
    levels.enumerated().compactMap { index, level in
      let time = start + Double(index) * 0.05
      return onset.feed(level: level, at: time) ? time : nil
    }
  }

  @Test("a voice held above the threshold is reported once, after the hold")
  func sustained() {
    var onset = VoiceOnset(threshold: -40, hold: 0.25, warmUp: 0)
    let times = heard(&onset, Array(repeating: -30, count: 20))
    #expect(times == [0.25])
  }

  @Test("a blip shorter than the hold starts the count again")
  func blip() {
    var onset = VoiceOnset(threshold: -40, hold: 0.25, warmUp: 0)
    #expect(heard(&onset, [-30, -30, -30, -55, -30, -30, -30, -30]).isEmpty)
    let early = onset.feed(level: -30, at: 0.4)
    let held = onset.feed(level: -30, at: 0.45)
    #expect(!early)
    #expect(held, "0.25 s after the level came back at 0.2 s")
  }

  @Test("nothing counts while the echo canceller warms up")
  func warmUp() {
    var onset = VoiceOnset(threshold: -40, hold: 0.25, warmUp: 0.6)
    let times = heard(&onset, Array(repeating: -30, count: 30), from: 10)
    #expect(times.count == 1)
    #expect(abs(times[0] - 10.85) < 0.001, "0.6 s of warm-up, then the 0.25 s hold")
  }

  @Test("the residual echo measured on 2026-10-12 never counts as a voice")
  func residualEcho() {
    var onset = VoiceOnset()
    // Voice processing left the spoken reply about 5 dB above a -62 dBFS room.
    #expect(heard(&onset, Array(repeating: -56, count: 200)).isEmpty)
  }
}
