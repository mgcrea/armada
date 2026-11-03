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
/// id, which every copy of a session keeps. A slash use has no id of its own, and its
/// entry's `uuid` will not do: a fork or a branch copies the line with the same timestamp
/// and folder but a new `uuid` (and a new `sessionId`). So it is keyed on the instant in
/// milliseconds, the line's `cwd` normalised, and the name (`ClaudeSkillLine.slashID`). The
/// indexer also counts it once when its `uuid` was seen under another key: the same entry
/// can be written again with a different `cwd`. The prefixes keep the two kinds from ever
/// colliding.
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
/// **A typed message is the person's words, not what Claude Code put in their turn.** Claude
/// Code writes a lot of its own text as user entries, and none of it is a reply to a skill
/// (background-task notifications far outnumber typed messages in a busy session). So a
/// message is refused when any of these holds:
/// - it is `isMeta` or `isCompactSummary`;
/// - it answers a tool (`tool_result`);
/// - `origin.kind` or `turnOrigin` is present and is not `human`. That is how a task
///   notification, a coordinator, or a message from another session is marked;
/// - nothing is left once every text block that opens with a tag is dropped. Every tag
///   Claude Code injects opens a block: `<command-…>`, `<local-command-…>`,
///   `<task-notification>`, `<system-reminder>`, and VS Code's `<ide_opened_file>`. That last
///   one shares an entry with the person's own block, which is why the rule works one block
///   at a time. The rule also catches the tags older versions wrote without an `origin`. A
///   `<` that is not followed by a letter, `/` or `!`, as in `<3`, opens no tag.
///
/// `[Request interrupted by user]` stays: it is the person pressing Esc, the plainest
/// pushback a skill gets.
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
      if wantHuman, isTyped(object), let text = typedText(in: message).flatMap(excerpt)
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
    // The line's own folder, never the indexer's: the id has to come from the line alone.
    let cwd = object["cwd"] as? String ?? ""
    return SkillUseEvent(
      useID: slashID(at: at, cwd: cwd, skill: skill), kind: .slash,
      skill: skill, entryUUID: uuid, at: at,
      args: tag("command-args", in: content).flatMap(excerpt))
  }

  /// A slash use's key: the instant in whole milliseconds, the line's folder normalised and
  /// the name, never the uuid, which a fork or branch copy gets anew. The instant rather
  /// than its spelling, so `…:00.000Z` and `…:00Z` are one key.
  static func slashID(at: Date, cwd: String, skill: String) -> String {
    let milliseconds = Int64((at.timeIntervalSince1970 * 1000).rounded())
    return "s:\(milliseconds)|\(ProjectPath.normalize(cwd))|\(skill)"
  }

  /// Whether the entry's flags leave it as something the person typed.
  private static func isTyped(_ object: [String: Any]) -> Bool {
    guard object["isMeta"] as? Bool != true, object["isCompactSummary"] as? Bool != true
    else { return false }
    if let origin = object["origin"] as? [String: Any], let kind = origin["kind"] as? String,
      kind != "human"
    {
      return false
    }
    if let turnOrigin = object["turnOrigin"] as? String, turnOrigin != "human" { return false }
    return true
  }

  /// The text the person typed: a plain string, or the text blocks of a list that holds
  /// no tool result, with every block that opens with an injected tag left out. Nil when
  /// nothing is left.
  private static func typedText(in message: [String: Any]) -> String? {
    let texts: [String]
    if let string = message["content"] as? String {
      texts = [string]
    } else if let blocks = message["content"] as? [[String: Any]],
      !blocks.contains(where: { $0["type"] as? String == "tool_result" })
    {
      texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    } else {
      return nil
    }
    let typed = texts.filter { !opensWithTag($0) }
    return typed.isEmpty ? nil : typed.joined(separator: "\n")
  }

  /// Whether `text`, after leading whitespace, opens with `<` and then a letter, `/` or `!`,
  /// the way a tag does. `<3` or `<= 5` is something a person typed.
  private static func opensWithTag(_ text: String) -> Bool {
    let opening = text.drop(while: \.isWhitespace)
    guard opening.first == "<", let next = opening.dropFirst().first else { return false }
    return next.isLetter || next == "/" || next == "!"
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
