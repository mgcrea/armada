import Testing

@testable import ArmadaSupervisor

@Suite("Silence detector")
struct SilenceDetectorTests {
  private let loud: Float = -20
  private let quiet: Float = -60

  @Test("a press followed by nothing gives up, and never ends early")
  func givesUp() {
    var detector = SilenceDetector()
    #expect(detector.feed(level: quiet, at: 0) == .listening)
    #expect(detector.feed(level: quiet, at: 3) == .listening)
    #expect(detector.feed(level: quiet, at: 6) == .gaveUp)
  }

  @Test("speech then a long enough pause ends the question")
  func ends() {
    var detector = SilenceDetector()
    #expect(detector.feed(level: loud, at: 0) == .listening)
    #expect(detector.feed(level: quiet, at: 1.0) == .listening)
    #expect(detector.feed(level: quiet, at: 2.4) == .listening)
    #expect(detector.feed(level: quiet, at: 2.5) == .ended)
  }

  @Test("speaking again resets the pause")
  func resets() {
    var detector = SilenceDetector()
    _ = detector.feed(level: loud, at: 0)
    _ = detector.feed(level: quiet, at: 1)
    _ = detector.feed(level: loud, at: 2)
    #expect(detector.feed(level: quiet, at: 3) == .listening)
    #expect(detector.feed(level: quiet, at: 4.4) == .listening)
    #expect(detector.feed(level: quiet, at: 4.5) == .ended)
  }

  @Test("a question that never pauses still ends")
  func maximum() {
    var detector = SilenceDetector()
    #expect(detector.feed(level: loud, at: 0) == .listening)
    #expect(detector.feed(level: loud, at: 44) == .listening)
    #expect(detector.feed(level: loud, at: 45) == .ended)
  }

  @Test("level is RMS in dBFS, floored for silence")
  func level() {
    #expect(SilenceDetector.level(of: [Float]()) == -160)
    #expect(SilenceDetector.level(of: [0, 0, 0] as [Float]) == -160)
    #expect(SilenceDetector.level(of: [1, -1] as [Float]) == 0)
    #expect(abs(SilenceDetector.level(of: [0.5, -0.5] as [Float]) - -6.0206) < 0.001)
  }
}
