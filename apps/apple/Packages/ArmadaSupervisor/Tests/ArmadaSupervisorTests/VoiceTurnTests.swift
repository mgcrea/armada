import Testing

@testable import ArmadaSupervisor

@Suite("Voice turn")
struct VoiceTurnTests {
  /// Run events in order and return the effects of each, so a table reads top to bottom.
  private func run(_ turn: inout VoiceTurn, _ events: [VoiceTurn.Event]) -> [[VoiceTurn.Effect]] {
    events.map { turn.handle($0) }
  }

  @Test("press mode: a pause ends the question, the answer is spoken, then the overlay hides")
  func pressFlow() {
    var turn = VoiceTurn(mode: .press)
    let effects = run(
      &turn,
      [
        .shortcutDown, .speechEnded, .transcriptFinal(" who needs me "), .toolUse("x"),
        .sentence("Two do."), .turnEnded(error: nil), .speechFinished, .dismissTimerFired,
      ])
    #expect(
      effects == [
        [.startCapture], [.finishCapture], [.send("who needs me")], [], [.speak("Two do.")], [],
        [.scheduleDismiss], [.hide],
      ])
    #expect(turn.phase == .idle)
  }

  @Test("press mode: a second press ends the question, and release is ignored")
  func pressSecondPress() {
    var turn = VoiceTurn(mode: .press)
    #expect(
      run(&turn, [.shortcutDown, .shortcutUp, .shortcutDown]) == [
        [.startCapture], [], [.finishCapture],
      ])
    #expect(turn.phase == .listening(finishing: true))
  }

  @Test("hold mode: only the release ends the question")
  func hold() {
    var turn = VoiceTurn(mode: .hold)
    #expect(
      run(&turn, [.shortcutDown, .speechEnded, .shortcutDown, .shortcutUp])
        == [[.startCapture], [], [], [.finishCapture]])
  }

  @Test("an empty transcript fails with a short message instead of sending nothing")
  func emptyTranscript() {
    var turn = VoiceTurn(mode: .hold)
    #expect(
      run(&turn, [.shortcutDown, .shortcutUp, .transcriptFinal("  ")])
        == [[.startCapture], [.finishCapture], [.scheduleDismiss]])
    #expect(turn.phase == .failed(VoiceTurn.emptyTranscriptMessage))
    #expect(turn.handle(.dismissTimerFired) == [.hide])
  }

  @Test("pressing while it thinks interrupts the reply and hides")
  func cancelThinking() {
    var turn = VoiceTurn(mode: .press)
    _ = run(&turn, [.shortcutDown, .speechEnded, .transcriptFinal("hi")])
    #expect(turn.handle(.shortcutDown) == [.interrupt, .hide])
    #expect(turn.phase == .idle)
  }

  @Test("pressing while it speaks cuts it off, interrupting only a reply still coming")
  func cancelSpeaking() {
    var streaming = VoiceTurn(mode: .press)
    _ = run(&streaming, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One.")])
    #expect(streaming.handle(.shortcutDown) == [.interrupt, .stopSpeaking, .hide])

    var finished = VoiceTurn(mode: .press)
    _ = run(
      &finished,
      [
        .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One."),
        .turnEnded(error: nil),
      ])
    #expect(finished.handle(.shortcutDown) == [.stopSpeaking, .hide])
  }

  @Test("pressing once the answer is over starts a follow-up instead")
  func followUp() {
    var turn = VoiceTurn(mode: .press)
    _ = run(
      &turn,
      [
        .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One."),
        .turnEnded(error: nil), .speechFinished,
      ])
    #expect(turn.handle(.shortcutDown) == [.startCapture])
    #expect(turn.handle(.dismissTimerFired) == [], "a stale timer must not hide a new question")
  }

  @Test("with speech off, sentences only show and the reply ending schedules the hide")
  func silent() {
    var turn = VoiceTurn(mode: .press, speaksReplies: false)
    #expect(
      run(
        &turn,
        [
          .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One."),
          .turnEnded(error: nil),
        ])
        == [[.startCapture], [.finishCapture], [.send("hi")], [], [.scheduleDismiss]])
  }

  @Test("a reply with no text still ends")
  func noText() {
    var turn = VoiceTurn(mode: .press)
    _ = run(&turn, [.shortcutDown, .speechEnded, .transcriptFinal("hi")])
    #expect(turn.handle(.turnEnded(error: nil)) == [.scheduleDismiss])
  }

  @Test("errors stop speech and show their message; a failure while listening drops the capture")
  func failures() {
    var answering = VoiceTurn(mode: .press)
    _ = run(&answering, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One.")])
    #expect(
      answering.handle(.turnEnded(error: "Claude couldn't sign in.")) == [
        .stopSpeaking, .scheduleDismiss,
      ])
    #expect(answering.phase == .failed("Claude couldn't sign in."))

    var listening = VoiceTurn(mode: .hold)
    _ = listening.handle(.shortcutDown)
    #expect(listening.handle(.failure("No microphone.")) == [.cancelCapture, .scheduleDismiss])

    var idle = VoiceTurn(mode: .press)
    #expect(idle.handle(.failure("Turn on the MCP server.")) == [.scheduleDismiss])
    #expect(idle.handle(.shortcutDown) == [.startCapture], "a press after a failure tries again")
  }
}
