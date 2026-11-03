import Foundation

/// How a skill came to run.
///
/// **The model's choice, or the person's.** An automatic use is the model calling the `Skill`
/// tool; a slash use is the person typing `/name`. The split is what tells a skill that
/// should have triggered on its own from one nobody needs.
nonisolated enum SkillKind: Int, Hashable, Sendable {
  case auto = 0
  case slash = 1
}

/// One use of a skill, read from a Claude Code transcript line.
///
/// **Keyed so that a line read twice counts once.** An automatic use takes its `tool_use`
/// id, which a session copied into another folder keeps; a slash use has no id of its own,
/// so it takes its entry's `uuid`. The prefixes keep the two from ever colliding.
nonisolated struct SkillUseEvent: Equatable, Sendable {
  let useID: String
  let kind: SkillKind
  /// The name with any leading `/` and whitespace removed: `superpowers:brainstorming`.
  let skill: String
  let entryUUID: String
  let at: Date
  /// What the skill was asked, cut to `ClaudeSkillLine.excerptLimit`; nil when empty.
  let args: String?
}

/// The skill uses, and the messages the person typed, in a Claude Code transcript line.
///
/// **A slash use is a user entry that opens with the command's tags, nothing else.**
/// Claude Code writes `<command-message>` first for skills and newer commands, and
/// `<command-name>` first for built-ins like `/compact` and older custom commands; both
/// open the content. A message that quotes the tags further in (a harness relaying a
/// request, a person pasting a transcript) is not a use, and neither is the same text in
/// an `api-request-blob` or `attachment` entry, which copies what was sent.
///
/// **A typed message is the person's words, not what Claude Code put in their turn.** Meta
/// entries, tool results, and command tags and output are all written as user entries, and
/// none of them is a reply to a skill.
nonisolated enum ClaudeSkillLine {
  enum Event: Equatable, Sendable {
    case use(SkillUseEvent)
    case human(String)
  }

  static let excerptLimit = 500

  private static let skillMarker = Data(#""Skill""#.utf8)
  private static let commandMarker = Data("<command-".utf8)
  private static let userMarker = Data(#""type":"user""#.utf8)

  /// `wantHuman`: also report a message the person typed (≤ 500 characters).
  static func parse(_ line: Data, wantHuman: Bool) -> [Event] {
    // Cheap rejects first: nearly every line names no skill and is no typed message.
    guard
      line.range(of: skillMarker) != nil || line.range(of: commandMarker) != nil
        || (wantHuman && line.range(of: userMarker) != nil),
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let message = object["message"] as? [String: Any]
    else { return [] }

    switch object["type"] as? String {
    case "assistant":
      return toolUses(in: message, of: object).map(Event.use)
    case "user":
      if let use = slashUse(in: message, of: object) { return [.use(use)] }
      if wantHuman, object["isMeta"] as? Bool != true,
        let text = typedText(in: message).flatMap(excerpt)
      {
        return [.human(text)]
      }
      return []
    default:
      return []
    }
  }

  /// `text` trimmed and cut to `excerptLimit` characters, or nil when nothing is left.
  /// Cut on a `Character`, so an emoji at the limit is kept whole or dropped whole.
  static func excerpt(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(excerptLimit))
  }

  private static func toolUses(in message: [String: Any], of object: [String: Any])
    -> [SkillUseEvent]
  {
    guard let blocks = message["content"] as? [[String: Any]],
      let uuid = object["uuid"] as? String, !uuid.isEmpty,
      let at = (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp)
    else { return [] }
    return blocks.compactMap { block in
      guard block["type"] as? String == "tool_use", block["name"] as? String == "Skill",
        let id = block["id"] as? String, !id.isEmpty,
        let input = block["input"] as? [String: Any],
        let skill = (input["skill"] as? String).flatMap(skillName)
      else { return nil }
      return SkillUseEvent(
        useID: "a:" + id, kind: .auto, skill: skill, entryUUID: uuid, at: at,
        args: (input["args"] as? String).flatMap(excerpt))
    }
  }

  private static func slashUse(in message: [String: Any], of object: [String: Any])
    -> SkillUseEvent?
  {
    guard let content = message["content"] as? String else { return nil }
    let opening = content.drop(while: \.isWhitespace)
    guard opening.hasPrefix("<command-message>") || opening.hasPrefix("<command-name>"),
      let raw = tag("command-name", in: content), !raw.contains("<"),
      let skill = skillName(raw),
      let uuid = object["uuid"] as? String, !uuid.isEmpty,
      let at = (object["timestamp"] as? String).flatMap(UsageSnapshot.parseTimestamp)
    else { return nil }
    return SkillUseEvent(
      useID: "s:" + uuid, kind: .slash, skill: skill, entryUUID: uuid, at: at,
      args: tag("command-args", in: content).flatMap(excerpt))
  }

  /// The text the person typed: a plain string, or the text blocks of a list that holds
  /// no tool result. Nil for command tags and a local command's output.
  private static func typedText(in message: [String: Any]) -> String? {
    let text: String
    if let string = message["content"] as? String {
      text = string
    } else if let blocks = message["content"] as? [[String: Any]],
      !blocks.contains(where: { $0["type"] as? String == "tool_result" })
    {
      text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        .joined(separator: "\n")
    } else {
      return nil
    }
    let opening = text.drop(while: \.isWhitespace)
    guard !opening.hasPrefix("<command-"), !opening.hasPrefix("<local-command-") else {
      return nil
    }
    return text
  }

  /// `name` with whitespace and a leading `/` removed, or nil when nothing is left.
  private static func skillName(_ name: String) -> String? {
    var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.hasPrefix("/") { name.removeFirst() }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  /// What lies between the first `<name>` and the `</name>` after it.
  private static func tag(_ name: String, in text: String) -> String? {
    guard let open = text.range(of: "<\(name)>"),
      let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
    else { return nil }
    return String(text[open.upperBound..<close.lowerBound])
  }
}
