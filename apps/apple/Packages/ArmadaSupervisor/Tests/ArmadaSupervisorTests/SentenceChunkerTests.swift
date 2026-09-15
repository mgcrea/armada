import Testing

@testable import ArmadaSupervisor

@Suite("Sentence chunker")
struct SentenceChunkerTests {
  /// Feed deltas in order and collect everything spoken, `finish()` included.
  private func speak(_ deltas: [String]) -> [String] {
    var chunker = SentenceChunker()
    return deltas.flatMap { chunker.append($0) } + chunker.finish()
  }

  @Test("a sentence is released as soon as the character after its stop arrives")
  func streaming() {
    var chunker = SentenceChunker()
    #expect(chunker.append("Two sessions need you. The") == ["Two sessions need you."])
    #expect(chunker.append(" Bastion one is waiting") == [])
    #expect(chunker.finish() == ["The Bastion one is waiting"])
  }

  @Test("a stop with nothing after it waits for the next delta")
  func waitsForWhitespace() {
    var chunker = SentenceChunker()
    #expect(chunker.append("Usage is at 3.") == [])
    #expect(chunker.append("5 percent. Next") == ["Usage is at 3.5 percent."])
  }

  @Test("abbreviations and initials do not end a sentence")
  func abbreviations() {
    #expect(
      speak(["Several, e.g. Bastion and Armada, are idle. Done."])
        == ["Several, e.g. Bastion and Armada, are idle.", "Done."])
    #expect(speak(["Ask J. Smith first. Then"]) == ["Ask J. Smith first.", "Then"])
  }

  @Test("closing quotes and brackets stay with their sentence")
  func closingPunctuation() {
    #expect(
      speak([#"It said "done." Then it stopped."#]) == [#"It said "done.""#, "Then it stopped."])
  }

  @Test("markdown is stripped, link text is kept")
  func markdown() {
    #expect(
      speak(["**Bastion** is `waiting` for [approval](https://example.com/x). "])
        == ["Bastion is waiting for approval."])
    #expect(
      speak(["## Summary\n- first item\n- second item\n1. third"]) == [
        "Summary", "first item", "second item", "third",
      ])
  }

  @Test("fenced code is never read, even while its fence is still open")
  func fences() {
    var chunker = SentenceChunker()
    #expect(chunker.append("Run this:\n```\nmake test\n") == ["Run this:"])
    #expect(chunker.append("```\nThen it passes. ") == ["Then it passes."])
    #expect(speak(["Look:\n```swift\nlet x = 1"]) == ["Look:"])
  }

  @Test("session ids and long hex are removed")
  func ids() {
    #expect(
      speak(["Session 5f401944-82e0-494f-91b0-972f0ae9871b is waiting. "])
        == ["Session is waiting."])
    #expect(speak(["Commit 52e2bcf0a1b2c3 landed (e8dbcbf9ab12cd)."]) == ["Commit landed."])
  }

  @Test("nothing speakable yields nothing")
  func empty() {
    #expect(speak(["?"]) == [])
    #expect(speak(["", "   ", "\n\n"]) == [])
  }
}
