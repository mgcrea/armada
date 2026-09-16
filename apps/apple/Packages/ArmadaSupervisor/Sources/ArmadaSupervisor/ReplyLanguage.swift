import Foundation

/// The language voice answers in, as Settings ▸ Voice stores it under `armada.voiceReplyLanguage`.
///
/// **The question's language by default**, which is what voice did before this setting existed:
/// the brief says nothing about language, and Claude answers in the language it is asked in. A
/// fixed language is for asking in one language and hearing another, such as a question in French
/// answered in English because the English voice sounds better.
///
/// **Stored as a language code** (`en`, `fr`) and named in English in the instruction, the
/// language the rest of the brief is written in.
public enum ReplyLanguage: Equatable, Sendable {
  case question
  case fixed(String)

  public init(storageValue: String?) {
    guard let value = storageValue, !value.isEmpty else {
      self = .question
      return
    }
    self = .fixed(value)
  }

  public var storageValue: String {
    switch self {
    case .question: ""
    case .fixed(let code): code
    }
  }

  /// The sentence appended to the brief, or nil when the question's language is used.
  public var instruction: String? {
    guard case .fixed(let code) = self else { return nil }
    let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    return "Always reply in \(name), even when the question is asked in another language."
  }
}
