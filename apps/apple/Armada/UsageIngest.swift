import Foundation

/// How far the ledger has read one file, and what it has learned about it on the way.
///
/// Persisted beside the file's figures and committed with them, so a pass interrupted at
/// any point resumes exactly where its last commit left off.
nonisolated struct IngestCursor: Codable, Hashable, Sendable {
  /// The byte after the last whole line read.
  var offset: Int64 = 0
  /// The folder the session started in: the first `cwd` of a Claude transcript, or a Codex
  /// rollout's `session_meta`. A subagent transcript is handed its parent's before reading.
  var cwd: String?
  /// Claude Code writes one line per content block, each repeating the message's usage.
  /// Remembering the last id skips those without asking the store.
  var lastMessageID: String?
  var codexPrevious: CodexCumulative?
  var codexModel: String?
  var isChild = false
  var firstAt: Date?
  var lastAt: Date?
}

/// Tokens a file added, on one day, for one model.
nonisolated struct IngestContribution: Equatable, Sendable {
  let day: Int
  let model: String
  let tokens: TokenTally
  let at: Date
}

/// How far the ledger has read one Claude transcript for skill uses, which can trail the
/// token cursor: a ledger built before skills were counted reads them back from byte zero.
nonisolated struct SkillCursor: Codable, Hashable, Sendable {
  /// The byte after the last whole line read for skills. Stored in its own column, not in
  /// the JSON, so a pass can compare it with the token cursor without decoding.
  var offset: Int64 = 0
  /// Use ids waiting for the person's next message, which is their reply.
  var awaiting: [String] = []

  enum CodingKeys: String, CodingKey { case awaiting }
}

/// One use of a skill a file holds, on the local day it ran.
nonisolated struct SkillContribution: Equatable, Sendable {
  let event: SkillUseEvent
  let day: Int
}

/// Reads whole lines from a chunk of a transcript or rollout, and says what they spent.
///
/// **No I/O and no store.** The indexer hands in bytes starting at the cursor and a
/// `claim` that answers "has this key been counted anywhere before" (and records it), and
/// gets back how many bytes were whole lines. What is left over is the start of a line still
/// being written, and is read again next time.
///
/// **Dedupe is global and first-seen wins.** A resumed, forked or mirrored Claude
/// transcript copies earlier messages under the same ids, with the same timestamps and
/// folder, and a forked Codex rollout replays its parent's totals — so counting per file
/// would count the same work twice.
///
/// **A Claude transcript has two cursors.** Tokens and skill uses are read from the same
/// bytes, each only past its own cursor, so a skill cursor that lags (a backfill) rereads
/// lines whose tokens are already counted without counting them again.
nonisolated enum FileIngest {
  /// `base` is the file offset of `buffer`'s first byte: the lesser of the two cursors.
  /// `tokens` is false for a file whose tokens are not counted, such as an archive copy.
  /// `skill` answers whether a use is new; only a new one in a main transcript waits for
  /// the person's next message, which goes to `reply` with every use waiting for it.
  static func claude(
    _ buffer: Data, base: Int64, cursor: inout IngestCursor, skills: inout SkillCursor,
    tokens: Bool, subagent: Bool, calendar: Calendar, claim: (UInt64) -> Bool,
    sink: (IngestContribution) -> Void, skill: (SkillContribution) -> Bool,
    reply: ([String], String) -> Void
  ) -> Int {
    let consumed = wholeLines(in: buffer) { line, start in
      let position = base + Int64(start)
      if cursor.cwd == nil, let cwd = ClaudeUsageLine.cwd(in: line) { cursor.cwd = cwd }
      if tokens, position >= cursor.offset {
        claudeTokens(line, cursor: &cursor, calendar: calendar, claim: claim, sink: sink)
      }
      if position >= skills.offset {
        claudeSkills(
          line, skills: &skills, subagent: subagent, calendar: calendar, skill: skill,
          reply: reply)
      }
    }
    cursor.offset = max(cursor.offset, base + Int64(consumed))
    skills.offset = max(skills.offset, base + Int64(consumed))
    return consumed
  }

  private static func claudeTokens(
    _ line: Data, cursor: inout IngestCursor, calendar: Calendar, claim: (UInt64) -> Bool,
    sink: (IngestContribution) -> Void
  ) {
    guard let event = ClaudeUsageLine.parse(line), event.messageID != cursor.lastMessageID
    else { return }
    cursor.lastMessageID = event.messageID
    guard claim(StableHash.key(tag: UInt8(ascii: "c"), event.messageID)) else { return }
    note(event.at, in: &cursor)
    sink(
      IngestContribution(
        day: LocalDay.key(event.at, calendar: calendar), model: event.model,
        tokens: event.tokens, at: event.at))
  }

  private static func claudeSkills(
    _ line: Data, skills: inout SkillCursor, subagent: Bool, calendar: Calendar,
    skill: (SkillContribution) -> Bool, reply: ([String], String) -> Void
  ) {
    for event in ClaudeSkillLine.parse(line, wantHuman: !skills.awaiting.isEmpty) {
      switch event {
      case .use(let use):
        let isNew = skill(
          SkillContribution(event: use, day: LocalDay.key(use.at, calendar: calendar)))
        if isNew, !subagent { skills.awaiting.append(use.useID) }
      case .human(let text):
        reply(skills.awaiting, text)
        skills.awaiting = []
      }
    }
  }

  static func codex(
    _ buffer: Data, cursor: inout IngestCursor, calendar: Calendar, claim: (UInt64) -> Bool,
    sink: (IngestContribution) -> Void
  ) -> Int {
    let consumed = wholeLines(in: buffer) { line, _ in
      guard let parsed = CodexUsageLine.parse(line) else { return }
      switch parsed {
      case .meta(let cwd, let isChild):
        if cursor.cwd == nil, !cwd.isEmpty { cursor.cwd = cwd }
        cursor.isChild = isChild
      case .turnContext(let model):
        cursor.codexModel = model
      case .tokenCount(let cumulative, let at):
        let previous = cursor.codexPrevious
        // Always, claimed or not: a replayed total is still the base the next one grows from.
        cursor.codexPrevious = cumulative
        guard claim(cumulative.hashKey), let delta = cumulative.delta(from: previous),
          !delta.isZero
        else { return }
        note(at, in: &cursor)
        sink(
          IngestContribution(
            day: LocalDay.key(at, calendar: calendar), model: cursor.codexModel ?? "unknown",
            tokens: delta, at: at))
      }
    }
    cursor.offset += Int64(consumed)
    return consumed
  }

  private static func note(_ at: Date, in cursor: inout IngestCursor) {
    cursor.firstAt = min(cursor.firstAt ?? at, at)
    cursor.lastAt = max(cursor.lastAt ?? at, at)
  }

  /// Calls `body` with each newline-terminated line and where in `buffer` it starts, and
  /// returns the bytes they covered.
  ///
  /// A last line with no newline is never yielded, even at the end of the file: both
  /// vendors terminate every line they write, so an unterminated one is mid-write.
  private static func wholeLines(in buffer: Data, _ body: (Data, Int) -> Void) -> Int {
    let base = buffer.startIndex
    let count = buffer.count
    var offset = 0
    while offset < count {
      let newline: Int? = buffer.withUnsafeBytes { raw in
        guard let start = raw.baseAddress,
          let hit = memchr(start + offset, 0x0A, count - offset)
        else { return nil }
        return start.distance(to: UnsafeRawPointer(hit))
      }
      guard let newline else { break }
      if newline > offset { body(buffer[(base + offset)..<(base + newline)], offset) }
      offset = newline + 1
    }
    return offset
  }
}
