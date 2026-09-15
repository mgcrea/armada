import Foundation

/// Streaming reply text in, sentences ready to speak out.
///
/// **Why sentences.** A synthesizer handed a word at a time reads with no intonation, and one
/// handed the whole reply starts only once the last token is in. A sentence is the smallest
/// unit that sounds right, and the first one is ready about a second into the reply.
///
/// **A boundary needs the character after it.** `.`, `!` and `?` end a sentence only when
/// whitespace follows, so "3.5" split across two deltas is never cut at the point, and a
/// sentence still missing its next character waits for the next delta or for `finish()`.
/// A newline always ends one: the brief asks for no lists, and a reply that has one anyway
/// reads better item by item.
///
/// **What is not read aloud.** Fenced code is dropped whole, and held back while its fence is
/// still open. Markdown emphasis, inline-code backticks, headings, bullets and link targets
/// are stripped. Session UUIDs and long hex ids are removed: "session 5f401944-82e0-…" is
/// noise to a listener, and the brief already asks for names instead.
public struct SentenceChunker: Sendable {
  private var buffer = ""

  public init() {}

  /// Add a delta and return every sentence it completed, in order.
  public mutating func append(_ text: String) -> [String] {
    buffer += text
    return drain()
  }

  /// The turn is over: return whatever is left, which may be a sentence with no final stop.
  public mutating func finish() -> [String] {
    var sentences = drain()
    let rest = Self.removingFences(buffer, final: true)
    if let spoken = Self.speakable(rest) { sentences.append(spoken) }
    buffer = ""
    return sentences
  }

  private mutating func drain() -> [String] {
    var sentences: [String] = []
    while true {
      let text = Self.removingFences(buffer, final: false)
      guard let cut = Self.boundary(in: text) else {
        buffer = text
        return sentences
      }
      if let spoken = Self.speakable(String(text[..<cut])) { sentences.append(spoken) }
      buffer = String(text[cut...])
    }
  }

  // MARK: - Boundaries

  static let abbreviations: Set<String> = [
    "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "no", "approx",
  ]

  /// The index just past the first sentence end in `text`, or nil when none is complete yet.
  ///
  /// Only the part before an open code fence is searched, so a fence still streaming never
  /// has a "sentence" cut out of its middle.
  static func boundary(in text: String) -> String.Index? {
    let searchable = text.range(of: "```").map { text[..<$0.lowerBound] } ?? text[...]
    var index = searchable.startIndex
    while index < searchable.endIndex {
      let character = searchable[index]
      let next = searchable.index(after: index)
      if character == "\n" { return next }
      if ".!?".contains(character) {
        var after = next
        while after < searchable.endIndex, "\"'”’)]".contains(searchable[after]) {
          after = searchable.index(after: after)
        }
        if after < searchable.endIndex, searchable[after].isWhitespace,
          !(character == "." && isAbbreviation(before: index, in: searchable))
        {
          return after
        }
      }
      index = next
    }
    return nil
  }

  /// Whether the period at `period` belongs to its word rather than ending a sentence: an
  /// abbreviation, an initial, or the number of a list item at the start of a line.
  private static func isAbbreviation(before period: String.Index, in text: Substring) -> Bool {
    let head = text[..<period]
    let separator = head.lastIndex(where: \.isWhitespace)
    let start = separator.map { head.index(after: $0) } ?? head.startIndex
    let word = head[start...]
    if word.count == 1, word.first?.isUppercase == true { return true }
    if !word.isEmpty, word.allSatisfy(\.isNumber), separator.map({ head[$0] == "\n" }) ?? true {
      return true
    }
    return abbreviations.contains(word.lowercased())
  }

  // MARK: - Cleaning

  /// `text` with every closed code fence removed. With `final`, an unclosed fence and
  /// everything after it go too; without it, they stay for the next delta to close.
  static func removingFences(_ text: String, final: Bool) -> String {
    var result = text.replacing(/```[\s\S]*?```/, with: " ")
    if final, let open = result.range(of: "```") {
      result.removeSubrange(open.lowerBound...)
    }
    return result
  }

  /// The words a listener should hear, or nil when nothing speakable is left.
  static func speakable(_ raw: String) -> String? {
    var text = raw.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
    text = text.replacing(/https?:\/\/\S+/, with: "")
    text = text.replacing(
      /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/, with: "")
    text = text.replacing(
      /\b(?=[0-9a-fA-F]*[0-9])(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{12,}\b/, with: "")
    text = text.replacing(/\*\*|__|`|\*/, with: "")
    text = text.replacing(/^\s*(#{1,6}\s+|[-•]\s+|\d+[.)]\s+|>\s*)/, with: "")
    text = text.replacing(/\(\s*\)/, with: "")
    text = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    text = text.replacing(/\s+([,.;:!?])/) { String($0.output.1) }
    guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return text
  }
}
