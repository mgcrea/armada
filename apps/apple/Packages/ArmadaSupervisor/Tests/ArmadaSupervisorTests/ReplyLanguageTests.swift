import Testing

@testable import ArmadaSupervisor

@Suite("Reply language")
struct ReplyLanguageTests {
  @Test("nothing stored means the language the question is asked in")
  func defaultsToQuestion() {
    #expect(ReplyLanguage(storageValue: nil) == .question)
    #expect(ReplyLanguage(storageValue: "") == .question)
  }

  @Test("a stored code is a fixed language, and stores back as itself")
  func fixed() {
    #expect(ReplyLanguage(storageValue: "en") == .fixed("en"))
    for value in ["", "en", "fr"] {
      #expect(ReplyLanguage(storageValue: value).storageValue == value)
    }
  }

  @Test("a fixed language is named in English in the instruction, the question's has none")
  func instruction() {
    #expect(ReplyLanguage.question.instruction == nil)
    #expect(
      ReplyLanguage.fixed("en").instruction
        == "Always reply in English, even when the question is asked in another language.")
    #expect(
      ReplyLanguage.fixed("fr").instruction
        == "Always reply in French, even when the question is asked in another language.")
  }
}
