import Foundation

/// A sentence's phonemes, cut to the length Kokoro accepts in one call.
///
/// **Why Armada splits.** Kokoro refuses more than 510 phonemes, counted as Swift characters
/// (`KokoroAneVocab.encode` at the pinned FluidAudio). FluidAudio used to split long input
/// itself until #790 removed it, and its splitter is internal. The brief asks for short
/// sentences, so a reply rarely reaches the limit, but a pasted paragraph in the preview does.
///
/// **Cut at spaces**, which separate words in the phoneme string. A word longer than the whole
/// limit is cut where the limit falls rather than dropped.
public enum PhonemeSplit {
  /// `KokoroAneConstants.maxPhonemeLength` at the pinned FluidAudio.
  public static let kokoroLimit = 510

  public static func pieces(_ phonemes: String, limit: Int = kokoroLimit) -> [String] {
    precondition(limit > 0)
    var pieces: [String] = []
    var current = ""
    for word in phonemes.split(separator: " ") {
      if !current.isEmpty, current.count + 1 + word.count <= limit {
        current += " "
        current += word
        continue
      }
      if !current.isEmpty { pieces.append(current) }
      var rest = word
      while rest.count > limit {
        let cut = rest.index(rest.startIndex, offsetBy: limit)
        pieces.append(String(rest[..<cut]))
        rest = rest[cut...]
      }
      current = String(rest)
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
  }
}

/// The voice replies are read in, as Settings ▸ Voice stores it under `armada.voiceIdentifier`.
///
/// **One key for both engines**, so a voice picked before Kokoro existed is still the one used.
/// A system voice is stored by its `AVSpeechSynthesisVoice` identifier, as it always was. A
/// Kokoro voice is stored by its pack name after `kokoro:`, which no system identifier starts
/// with.
public enum VoiceChoice: Equatable, Sendable {
  case systemDefault
  case system(String)
  case kokoro(String)

  static let kokoroPrefix = "kokoro:"

  public init(storageValue: String?) {
    guard let value = storageValue, !value.isEmpty else {
      self = .systemDefault
      return
    }
    guard value.hasPrefix(Self.kokoroPrefix) else {
      self = .system(value)
      return
    }
    let voice = String(value.dropFirst(Self.kokoroPrefix.count))
    self = voice.isEmpty ? .systemDefault : .kokoro(voice)
  }

  public var storageValue: String {
    switch self {
    case .systemDefault: ""
    case .system(let identifier): identifier
    case .kokoro(let voice): Self.kokoroPrefix + voice
    }
  }
}
