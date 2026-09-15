import Testing

@testable import ArmadaSupervisor

@Suite("Speech text")
struct SpeechTextTests {
  @Test("phonemes within the limit stay one piece")
  func withinLimit() {
    #expect(PhonemeSplit.pieces("hˈɛlO wˈɜɹld", limit: 20) == ["hˈɛlO wˈɜɹld"])
    #expect(PhonemeSplit.pieces("abcde fghij", limit: 11) == ["abcde fghij"])
  }

  @Test("longer phonemes split at spaces, with no piece over the limit")
  func splitsAtSpaces() {
    let phonemes = Array(repeating: "tˈu", count: 300).joined(separator: " ")
    let pieces = PhonemeSplit.pieces(phonemes, limit: 510)
    #expect(pieces.count == 3)
    #expect(pieces.allSatisfy { $0.count <= 510 })
    #expect(pieces.joined(separator: " ") == phonemes)
  }

  @Test("a run longer than the limit is cut where the limit falls")
  func hardCut() {
    #expect(
      PhonemeSplit.pieces(String(repeating: "ə", count: 25), limit: 10) == [
        String(repeating: "ə", count: 10), String(repeating: "ə", count: 10),
        String(repeating: "ə", count: 5),
      ])
    #expect(PhonemeSplit.pieces("ab cdefghijklm no", limit: 5) == ["ab", "cdefg", "hijkl", "m no"])
  }

  @Test("blank phonemes give no pieces")
  func empty() {
    #expect(PhonemeSplit.pieces("", limit: 10) == [])
    #expect(PhonemeSplit.pieces("   ", limit: 10) == [])
    #expect(PhonemeSplit.pieces("  ab   cd ", limit: 10) == ["ab cd"])
  }

  @Test("a stored voice identifier names the system default, a system voice or Kokoro")
  func choice() {
    #expect(VoiceChoice(storageValue: nil) == .systemDefault)
    #expect(VoiceChoice(storageValue: "") == .systemDefault)
    #expect(
      VoiceChoice(storageValue: "com.apple.voice.premium.en-US.Zoe")
        == .system("com.apple.voice.premium.en-US.Zoe"))
    #expect(VoiceChoice(storageValue: "kokoro:af_heart") == .kokoro("af_heart"))
    #expect(VoiceChoice(storageValue: "kokoro:") == .systemDefault)
  }

  @Test("a choice is stored as the identifier it was read from")
  func roundTrip() {
    for value in ["", "com.apple.voice.premium.en-US.Zoe", "kokoro:af_heart"] {
      #expect(VoiceChoice(storageValue: value).storageValue == value)
    }
  }
}
