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

  @Test("closing the card once the reply is in stops speech and hides, without interrupting")
  func close() {
    var turn = VoiceTurn(mode: .press)
    _ = run(
      &turn, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One.")])
    #expect(turn.handle(.closed) == [], "the card has no close button while the reply is coming")
    _ = turn.handle(.turnEnded(error: nil))
    #expect(turn.handle(.closed) == [.stopSpeaking, .hide])
    #expect(turn.phase == .idle)
    #expect(turn.handle(.dismissTimerFired) == [])

    var finished = VoiceTurn(mode: .press, speaksReplies: false)
    _ = run(
      &finished, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .turnEnded(error: nil)])
    #expect(finished.handle(.closed) == [.stopSpeaking, .hide])
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

  private static let asked: [VoiceTurn.Event] = [
    .shortcutDown, .speechEnded, .transcriptFinal("start r2"), .sentence("I'd start it."),
    .sentence("Should I go ahead?"), .turnEnded(error: nil),
  ]

  @Test("after a question: once the question is spoken, the microphone opens for the answer")
  func listensAfterQuestion() {
    var turn = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&turn, Self.asked)
    #expect(turn.handle(.speechFinished) == [.startCapture])
    #expect(turn.phase == .listening(finishing: false))
    #expect(turn.listensForAnswer)
    #expect(
      run(&turn, [.speechEnded, .transcriptFinal("yes")]) == [[.finishCapture], [.send("yes")]])
    #expect(!turn.listensForAnswer)
  }

  @Test("after a question: a reply that asks nothing waits to hide as before")
  func noQuestionNoListen() {
    var turn = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(
      &turn,
      [
        .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("Any news?"),
        .sentence("None."), .turnEnded(error: nil),
      ])
    #expect(turn.handle(.speechFinished) == [.scheduleDismiss])
  }

  @Test("after every reply: any reply listens")
  func listensAfterEveryReply() {
    var turn = VoiceTurn(mode: .press, followUp: .afterEveryReply)
    _ = run(
      &turn,
      [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("None."), .speechFinished])
    #expect(turn.handle(.turnEnded(error: nil)) == [.startCapture])
  }

  @Test("hold mode never listens by itself")
  func holdNeverListens() {
    var turn = VoiceTurn(mode: .hold, followUp: .afterEveryReply)
    _ = run(
      &turn,
      [
        .shortcutDown, .shortcutUp, .transcriptFinal("start r2"), .sentence("Go ahead?"),
        .turnEnded(error: nil),
      ])
    #expect(turn.handle(.speechFinished) == [.scheduleDismiss])
  }

  @Test("with speech off, the reply ending opens the microphone")
  func silentListens() {
    var turn = VoiceTurn(mode: .press, speaksReplies: false, followUp: .afterQuestion)
    #expect(run(&turn, Self.asked).last == [.startCapture])
  }

  @Test("silence after a reply closes the card quietly, not with Didn't catch that")
  func silenceHides() {
    var turn = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&turn, Self.asked + [.speechFinished])
    #expect(run(&turn, [.speechEnded, .transcriptFinal("")]) == [[.finishCapture], [.hide]])
    #expect(turn.phase == .idle)

    var pressed = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&pressed, Self.asked + [.speechFinished])
    #expect(run(&pressed, [.shortcutDown, .transcriptFinal(" ")]) == [[.finishCapture], [.hide]])
  }

  @Test("a question after pressing still fails on an empty transcript")
  func pressedStillFails() {
    var turn = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&turn, Self.asked + [.speechFinished, .speechEnded, .transcriptFinal("")])
    _ = run(&turn, [.shortcutDown, .speechEnded])
    #expect(turn.handle(.transcriptFinal("")) == [.scheduleDismiss])
    #expect(turn.phase == .failed(VoiceTurn.emptyTranscriptMessage))
  }

  @Test("a question is recognised past quotes, brackets and emphasis")
  func questionMarks() {
    #expect(VoiceTurn.endsWithQuestion("Should I go ahead?"))
    #expect(VoiceTurn.endsWithQuestion("Should I \"go ahead?\" "))
    #expect(VoiceTurn.endsWithQuestion("**Should I go ahead?**"))
    #expect(VoiceTurn.endsWithQuestion("続けますか？"))
    #expect(!VoiceTurn.endsWithQuestion("Done."))
    #expect(!VoiceTurn.endsWithQuestion("  "))
  }
}
