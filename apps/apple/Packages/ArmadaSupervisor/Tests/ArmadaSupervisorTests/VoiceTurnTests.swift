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

  @Test("the stop key cancels a question, interrupts a reply and stops speech, and never asks one")
  func stop() {
    var listening = VoiceTurn(mode: .press)
    _ = listening.handle(.shortcutDown)
    #expect(listening.handle(.stop) == [.cancelCapture, .hide])
    #expect(listening.phase == .idle)
    #expect(listening.handle(.transcriptFinal("late")) == [], "a late transcript is not sent")
    #expect(listening.handle(.stop) == [], "idle, the stop key starts nothing")

    var thinking = VoiceTurn(mode: .press)
    _ = run(&thinking, [.shortcutDown, .speechEnded, .transcriptFinal("hi")])
    #expect(thinking.handle(.stop) == [.interrupt, .hide])

    var streaming = VoiceTurn(mode: .press)
    _ = run(&streaming, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One.")])
    #expect(streaming.handle(.stop) == [.interrupt, .stopSpeaking, .hide])

    var speaking = VoiceTurn(mode: .press)
    _ = run(
      &speaking,
      [
        .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One."),
        .turnEnded(error: nil),
      ])
    #expect(speaking.handle(.stop) == [.stopSpeaking, .hide])
    #expect(speaking.phase == .idle)
  }

  @Test("the stop key is held only while voice listens, thinks or speaks")
  func stoppable() {
    var turn = VoiceTurn(mode: .press)
    #expect(!turn.isStoppable)
    _ = turn.handle(.shortcutDown)
    #expect(turn.isStoppable)
    _ = run(&turn, [.speechEnded, .transcriptFinal("hi")])
    #expect(turn.isStoppable)
    _ = run(&turn, [.sentence("One."), .turnEnded(error: nil)])
    #expect(turn.isStoppable, "still speaking")
    _ = turn.handle(.speechFinished)
    #expect(!turn.isStoppable, "only waiting to hide")

    var silent = VoiceTurn(mode: .press, speaksReplies: false)
    _ = run(&silent, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One.")])
    #expect(silent.isStoppable, "the reply is still coming")
    _ = silent.handle(.turnEnded(error: nil))
    #expect(!silent.isStoppable)

    var failed = VoiceTurn(mode: .hold)
    _ = run(&failed, [.shortcutDown, .shortcutUp, .transcriptFinal("")])
    #expect(!failed.isStoppable)
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
    #expect(
      run(&turn, Self.asked).suffix(3) == [
        [.standBy, .speak("I'd start it.")], [.speak("Should I go ahead?")], [],
      ])
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
    #expect(
      turn.handle(.speechFinished) == [.scheduleDismiss, .cancelCapture],
      "the microphone that stood by through the reply closes")
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

  @Test("the microphone stands by through a reply only when a reply may be answered by voice")
  func listensDuringReply() {
    #expect(VoiceTurn(mode: .press, followUp: .afterQuestion).listensDuringReply)
    #expect(VoiceTurn(mode: .press, followUp: .afterEveryReply).listensDuringReply)
    #expect(!VoiceTurn(mode: .press, followUp: .never).listensDuringReply)
    #expect(!VoiceTurn(mode: .hold, followUp: .afterEveryReply).listensDuringReply)
    #expect(
      !VoiceTurn(mode: .press, speaksReplies: false, followUp: .afterEveryReply)
        .listensDuringReply, "nothing is spoken, so there is nothing to talk over")

    var never = VoiceTurn(mode: .press)
    #expect(
      run(&never, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One.")]).last
        == [.speak("One.")])
    #expect(never.handle(.voiceHeard) == [], "with no microphone standing by, nothing was heard")
  }

  @Test("talking over a reply that is still coming interrupts it and becomes the answer")
  func talkOverStreaming() {
    var turn = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&turn, [.shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("Two of")])
    #expect(turn.handle(.voiceHeard) == [.interrupt, .stopSpeaking, .startCapture])
    #expect(turn.phase == .listening(finishing: false))
    #expect(turn.listensForAnswer)
    #expect(turn.handle(.voiceHeard) == [], "heard once per reply")
    #expect(turn.handle(.sentence("late.")) == [], "the interrupted reply's last words are dropped")
    #expect(
      run(&turn, [.speechEnded, .transcriptFinal("stop")]) == [[.finishCapture], [.send("stop")]])
  }

  @Test("talking over a reply that has arrived only stops the voice")
  func talkOverSpeaking() {
    var turn = VoiceTurn(mode: .press, followUp: .afterEveryReply)
    _ = run(
      &turn,
      [
        .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One."),
        .turnEnded(error: nil),
      ])
    #expect(turn.handle(.voiceHeard) == [.stopSpeaking, .startCapture])
    #expect(turn.listensForAnswer)
    #expect(turn.handle(.speechFinished) == [], "the stopped voice reports nothing")
  }

  @Test("once the reply is spoken, a late voiceHeard changes nothing")
  func voiceHeardLate() {
    var turn = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&turn, Self.asked + [.speechFinished])
    #expect(turn.handle(.voiceHeard) == [])
    #expect(turn.phase == .listening(finishing: false))
  }

  @Test("every other way out of a reply closes the microphone that stood by")
  func standByCloses() {
    let streaming: [VoiceTurn.Event] = [
      .shortcutDown, .speechEnded, .transcriptFinal("hi"), .sentence("One."),
    ]
    var pressed = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&pressed, streaming)
    #expect(pressed.handle(.shortcutDown) == [.interrupt, .stopSpeaking, .hide, .cancelCapture])

    var stopped = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&stopped, streaming)
    #expect(stopped.handle(.stop) == [.interrupt, .stopSpeaking, .hide, .cancelCapture])

    var failed = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&failed, streaming)
    #expect(
      failed.handle(.turnEnded(error: "No.")) == [.stopSpeaking, .scheduleDismiss, .cancelCapture])

    var closed = VoiceTurn(mode: .press, followUp: .afterQuestion)
    _ = run(&closed, streaming + [.turnEnded(error: nil)])
    #expect(closed.handle(.closed) == [.stopSpeaking, .hide, .cancelCapture])
    #expect(closed.handle(.shortcutDown) == [.startCapture], "and the next question opens it again")
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
