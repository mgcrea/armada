import Foundation

/// A transcript as something a person reads, rather than something a watcher samples.
///
/// **Measured before it was written**, on a 6.0MB / 2,166-line Claude Code transcript:
///
/// | | |
/// | --- | --- |
/// | every `text` block, the prose a human is here for | **90KB — 1.5% of the file** |
/// | `tool_result` text | 1.54MB; median 345 bytes, p90 2.4KB |
/// | base64 image payloads | 1.11MB (18%) here, **8.27MB (34%)** of a 24MB one |
/// | `toolUseResult`, a top-level near-copy of every tool result | 46% of all `user`-line bytes |
/// | lines carrying a `uuid` | 1,642 of 2,166 |
///
/// **So it is not a many-rows problem.** Two thousand rows is nothing for any container.
/// The costs are two, and neither is the row count:
///
/// 1. **A single huge string handed to a SwiftUI `Text` is a stall**, because `Text` does
///    not virtualize within a string — it lays the whole thing out to measure its height,
///    on the main actor, again on every width change. Hence `displayCap`: the cut happens
///    when the model is built, not in the view, and what is cut away is replaced by a byte
///    range so the view can ask for the rest.
/// 2. **Half of a large transcript is payload nobody renders**, and a decoder that
///    materializes it pays for it twice — once to build the string, once to free it. Hence
///    the narrow `Decodable` below, whose whole design is the keys it does *not* declare.
///
/// **A correction worth keeping**, because it is the kind that survives into a design
/// otherwise: the largest `tool_result` in the first file measured was 284KB, which looked
/// like a case for capping text hard. It was a base64 screenshot. The cap was never what
/// would have saved it — not declaring `source` is, and the text cap is for the genuinely
/// long tool output that remains, which tops out around 65KB.
///
/// Measured across the 40 largest of 1,886 transcripts on this Mac (2026-09-18): **857MB
/// parsed in 1.02s — 836MB/s**, worst single file 48.5ms for 26.1MB and 3,321 entries, two
/// 50MB transcripts at 47ms each, worst 64KB tail 0.33ms. Fast enough that a transcript
/// needs no offset index to open, which is the finding that kept one out of this file.
///
/// **Not `TranscriptTail`.** That one condenses for a supervisor's token budget and is
/// lossy on purpose. This one is lossy for a *viewport*, which wants different things
/// kept: thinking blocks survive here (see `Options.includeThinking`), tool results keep
/// 2KB rather than 400 characters, and every entry can be reopened at full length.
///
/// `nonisolated` for the reason `TranscriptTitle` gives: the project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a parser that cannot be called off
/// the main actor is a parser that blocks the window. It moves no work by itself — which
/// thread runs it is the caller's choice.
nonisolated enum TranscriptLog {

  /// How much of one block's text is kept for display, **in UTF-8 bytes.**
  ///
  /// **2KB, and the number is measured**: `tool_result` content has a p90 of 2,389
  /// characters, so this keeps roughly nine in ten results whole while the outliers become
  /// 2KB and a byte range. Raising it buys the last 10% at the price of the tail of a very
  /// long distribution, which is the wrong trade for a scrolling view.
  ///
  /// **Bytes rather than Characters, and that is a measurement not a shrug.** On a 3MB
  /// corpus: `String.count` costs 4.25ms against `utf8.count`'s 0.08ms, because it walks
  /// grapheme clusters, and `String(text.prefix(2048))` costs 5.46ms against 0.53ms for a
  /// scalar-aligned UTF-8 prefix. Together they were **half the parse time** of a 24MB
  /// transcript — 40ms of 81ms — for a figure the view then renders as "KB" anyway.
  static let displayCap = 2_048

  /// A tool call's arguments are a header, not content: enough to say which file or which
  /// command, never the body of a patch.
  static let argumentCap = 240

  /// One thing worth drawing: a turn, a thought, a tool call, its result, or a marker.
  ///
  /// **`id` is the line's own `uuid`.** Not the array index: a live session appends to the
  /// tail every few seconds, and index identity makes `ForEach` rediff — and rebuild — the
  /// whole list on every append. 1,642 of 2,166 lines carry one; the rest are entry types
  /// this parser drops anyway, and the few that survive get a synthesized id that is still
  /// stable across re-reads because it is derived from the byte offset.
  struct Entry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
      case user
      case assistant
      case thinking
      case toolUse
      case toolResult
      /// A compaction boundary, an API error, a rate-limit refusal: not a turn, but the
      /// reason the turns around it look the way they do.
      case notice
    }

    let id: String
    let kind: Kind
    /// The timestamp exactly as written, **never parsed here.**
    ///
    /// Parsing 2,000 ISO8601 dates to display thirty is work thrown away, and
    /// `ISO8601DateFormatter` is not cheap. It is also unnecessary for the two things a
    /// transcript view does with time: these strings sort lexicographically, and the day
    /// a row belongs to is `prefix(10)`. The visible rows convert, and only them.
    let at: String?
    /// Cut to `Options.cap`. `truncated` says whether anything was lost.
    let text: String
    /// The tool's name on `.toolUse`, and on the `.toolResult` answering it when the
    /// pairing was visible in this buffer.
    let tool: String?
    let model: String?
    /// The uncut length in UTF-8 bytes, so the view can offer "show all 65 KB" with the
    /// real figure rather than a shrug.
    let fullBytes: Int
    /// Where the line this came from sits **in the file**, and which content block of it
    /// this was. Together they are enough to re-read one entry at full length without an
    /// index and without touching the rest of the file.
    let line: Range<Int>
    let block: Int

    var truncated: Bool { fullBytes > text.utf8.count }
  }

  struct Options: Sendable {
    /// Keep `thinking` blocks.
    ///
    /// **Default on, against `TranscriptTail`'s comment that they are "empty on the models
    /// that write them".** Measured across 25 transcripts on 2026-09-18: 1,432 thinking
    /// blocks, **1,428 of them non-empty**, median 374 characters. They are real content,
    /// and dropping them silently is how a viewer loses the reasoning between a question
    /// and the tool call that answers it.
    var includeThinking = true
    /// Keep subagent turns (`isSidechain`). Off by default: a subagent's conversation is a
    /// conversation of its own and interleaves incomprehensibly with its parent's.
    var includeSidechain = false
    /// Keep `isMeta` entries — injected context, not something anyone typed.
    var includeMeta = false
    var cap = displayCap

    init(
      includeThinking: Bool = true, includeSidechain: Bool = false, includeMeta: Bool = false,
      cap: Int = displayCap
    ) {
      self.includeThinking = includeThinking
      self.includeSidechain = includeSidechain
      self.includeMeta = includeMeta
      self.cap = cap
    }
  }

  // MARK: - Reading

  /// Every entry in a buffer of newline-delimited JSON, oldest first.
  ///
  /// `baseOffset` is where the buffer starts in the file, so `Entry.line` is a file offset
  /// even when this was handed a tail. A tail must also set `droppingFirstLine`, for the
  /// reason every reader here repeats: a read that did not start at byte zero starts
  /// part-way through a line, and that fragment is not JSON.
  static func entries(
    inChunk chunk: Data, droppingFirstLine: Bool, baseOffset: Int = 0,
    options: Options = Options()
  ) -> [Entry] {
    let decoder = JSONDecoder()
    var out: [Entry] = []
    // Roughly one renderable entry per line before filtering; reserving stops the array
    // from doubling a dozen times on a 24MB file.
    out.reserveCapacity(1_024)
    for slice in JSONLines.oldestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      guard let line = try? decoder.decode(Line.self, from: slice) else { continue }
      let range = (baseOffset + slice.startIndex)..<(baseOffset + slice.endIndex)
      append(line, at: range, into: &out, options: options)
    }
    return out
  }

  /// The last `bytes` of a transcript, as entries.
  static func tail(of url: URL, bytes: Int, options: Options = Options()) -> [Entry]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let chunk = try? handle.readToEnd() else { return nil }
    return entries(
      inChunk: chunk, droppingFirstLine: start > 0, baseOffset: Int(start), options: options)
  }

  /// Everything appended since byte `offset`.
  ///
  /// **What following must use, rather than a fixed tail.** A 64KB tail is the right read for
  /// a watcher sampling a file it does not track, but a follower knows exactly where it
  /// stopped, and the difference is not academic: `docs/claude-code-sessions.md` records a
  /// burst of edits appending **~140KB** of `file-history` entries after a single turn. A
  /// follower on a 64KB window would have skipped everything before the last 64KB of that
  /// burst, silently, and the conversation would simply be missing turns.
  ///
  /// `offset` is an entry's `line.upperBound`, which is the index of that line's newline —
  /// a line boundary — so the read needs no `droppingFirstLine` and the empty first line is
  /// skipped by `JSONLines` anyway.
  ///
  /// Returns nil when the file cannot be read, and an empty array when nothing is new.
  static func entries(of url: URL, from offset: Int, options: Options = Options()) -> [Entry]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    // A file that shrank was replaced or truncated; the caller's offsets mean nothing now.
    guard size > UInt64(offset) else { return [] }
    try? handle.seek(toOffset: UInt64(offset))
    guard let chunk = try? handle.readToEnd() else { return nil }
    return entries(
      inChunk: chunk, droppingFirstLine: false, baseOffset: offset, options: options)
  }

  /// Every entry in the file.
  ///
  /// **Call this off the main actor.** 16ms for a 6MB transcript, 31ms for a 24MB one, 47ms
  /// for the two 50MB ones on this Mac. Small, but 47ms is three dropped frames, and the
  /// next transcript is always bigger than the last one measured.
  static func whole(of url: URL, options: Options = Options()) -> [Entry]? {
    guard let chunk = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return entries(inChunk: chunk, droppingFirstLine: false, options: options)
  }

  /// One entry's text at full length, re-read from the file.
  ///
  /// This is what the cut buys: the view holds 2KB and the rest is one seek away. Reads
  /// exactly `entry.line` and nothing else — measured at 1.3–1.7ms for the largest cut
  /// entry in either transcript.
  static func fullText(of entry: Entry, in url: URL) -> String? {
    guard entry.truncated else { return entry.text }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(entry.line.lowerBound))
    guard let data = try? handle.read(upToCount: entry.line.count),
      let line = try? JSONDecoder().decode(Line.self, from: data),
      case .blocks(let blocks) = line.message?.content, entry.block < blocks.count
    else { return nil }
    return blocks[entry.block].readableText(cap: .max)?.text
  }

  // MARK: - The narrow shape
  //
  // **What is not declared here is the point.** `JSONDecoder` on swift-foundation only
  // materializes the keys a `Decodable` asks for, so every key left out is skipped in the
  // scan rather than built and thrown away. Two of them dominate a transcript:
  //
  // - `source.data` on an image block — base64 screenshots, **34% of a 24MB transcript**
  //   (8.27MB across 36 images). An image block is declared with no `source`, so the
  //   payload is never a String.
  // - `toolUseResult`, a top-level near-copy of every tool result: **46% of all user-line
  //   bytes.** Not declared, so not read.
  //
  // Measured against the `JSONSerialization` version this replaced, on the same two files:
  // 2.4x faster (28.1ms against 66.9ms on 24MB) and a footprint delta of 0.00MB against
  // 29.90MB. The memory number is the one that mattered — a whole-file parse used to cost
  // the file's size again in transient Foundation objects.

  private struct Line: Decodable {
    let type: String?
    let uuid: String?
    let timestamp: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let message: Message?
    let compactMetadata: CompactMetadata?
    /// `system` entries carry their text at the top level rather than under `message`.
    let content: String?
  }

  private struct CompactMetadata: Decodable {
    let trigger: String?
    let preTokens: Int?
    let postTokens: Int?
  }

  private struct Message: Decodable {
    let model: String?
    let content: Content?
  }

  /// `content` is an array of blocks, or a bare string.
  ///
  /// **Both, and the rare one is not optional politeness.** Measured across 25 transcripts:
  /// 7,011 arrays to 45 bare strings, every string on a `user` entry. A decoder that
  /// declares only the array form throws on those lines and drops a person's own prompt —
  /// silently, because a thrown line is skipped. The first version of this parser did
  /// exactly that and lost 56 lines of the 24MB file before the counts were compared.
  private enum Content: Decodable {
    case text(String)
    case blocks([Block])

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let text = try? container.decode(String.self) {
        self = .text(text)
      } else {
        self = .blocks(try container.decode([Block].self))
      }
    }
  }

  private struct Block: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    /// The tool's name, on `tool_use`.
    let name: String?
    let input: Arguments?
    /// `tool_result` carries a string 94% of the time and an array of blocks in the rest
    /// (2,145 to 133 across the same 25 transcripts).
    let content: Content?

    /// The readable text of this block, whatever shape it carries it in.
    ///
    /// An image is named rather than decoded — its `source` is not declared anywhere in
    /// this file, so the base64 never becomes a String. A viewer that dropped it silently
    /// would read as a tool that returned nothing.
    func readableText(cap: Int) -> (text: String, full: Int)? {
      if let thinking { return TranscriptLog.cut(thinking, to: cap) }
      if let text { return TranscriptLog.cut(text, to: cap) }
      switch content {
      case .text(let string):
        return TranscriptLog.cut(string, to: cap)
      case .blocks(let parts):
        let joined = parts.compactMap { part -> String? in
          if let text = part.text { return text }
          if part.type == "image" { return "[image]" }
          return nil
        }.joined(separator: "\n")
        return TranscriptLog.cut(joined, to: cap)
      case nil:
        return type == "image" ? ("[image]", 7) : nil
      }
    }
  }

  /// The handful of tool arguments that say *which* file or *which* command.
  ///
  /// Named one by one rather than taken as a dictionary, and that is a memory decision as
  /// much as a display one: `Edit`'s `new_string` and `Write`'s `content` are exactly the
  /// large payloads this parser exists to keep out of the view, and a `[String: String]`
  /// would read every one of them back in.
  private struct Arguments: Decodable {
    let command: String?
    let filePath: String?
    let path: String?
    let pattern: String?
    let query: String?
    let url: String?
    let note: String?

    /// Spelled out rather than taking `JSONDecoder`'s `.convertFromSnakeCase`, which would
    /// apply to every key on every type in this file and make the ones that are already
    /// camelCase — `compactMetadata`, `isSidechain` — stop matching.
    enum CodingKeys: String, CodingKey {
      case command
      case filePath = "file_path"
      case path
      case pattern
      case query
      case url
      case note = "description"
    }

    var summary: String? {
      command ?? filePath ?? path ?? pattern ?? query ?? url ?? note
    }
  }

  // MARK: - One line

  private static func append(
    _ line: Line, at range: Range<Int>, into out: inout [Entry], options: Options
  ) {
    guard let type = line.type else { return }
    switch type {
    case "user", "assistant", "system":
      break
    default:
      return
    }
    if line.isSidechain == true, !options.includeSidechain { return }
    if line.isMeta == true, !options.includeMeta { return }

    let at = line.timestamp
    // The uuid, or something stable derived from where the line sits. Both survive a
    // re-read of the same file, which is all identity has to do here.
    let uuid = line.uuid ?? "@\(range.lowerBound)"

    if type == "system" {
      guard let note = notice(in: line, cap: options.cap) else { return }
      out.append(
        Entry(
          id: uuid, kind: .notice, at: at, text: note.text, tool: nil, model: nil,
          fullBytes: note.full, line: range, block: 0))
      return
    }

    let model = line.message?.model
    let turn: Entry.Kind = type == "assistant" ? .assistant : .user

    switch line.message?.content {
    case .text(let plain):
      guard let cut = cut(plain, to: options.cap) else { return }
      out.append(
        Entry(
          id: uuid, kind: turn, at: at, text: cut.text, tool: nil, model: model,
          fullBytes: cut.full, line: range, block: 0))

    case .blocks(let blocks):
      for (index, block) in blocks.enumerated() {
        // One line becomes several rows, so each needs an id of its own.
        let id = "\(uuid)#\(index)"
        switch block.type {
        case "text":
          guard let cut = block.readableText(cap: options.cap) else { continue }
          out.append(
            Entry(
              id: id, kind: turn, at: at, text: cut.text, tool: nil, model: model,
              fullBytes: cut.full, line: range, block: index))
        case "thinking":
          guard options.includeThinking, let cut = block.readableText(cap: options.cap)
          else { continue }
          out.append(
            Entry(
              id: id, kind: .thinking, at: at, text: cut.text, tool: nil, model: model,
              fullBytes: cut.full, line: range, block: index))
        case "tool_use":
          let summary = cut(block.input?.summary ?? "", to: argumentCap) ?? ("", 0)
          out.append(
            Entry(
              id: id, kind: .toolUse, at: at, text: summary.text, tool: block.name,
              model: model, fullBytes: summary.full, line: range, block: index))
        case "tool_result":
          guard let cut = block.readableText(cap: options.cap) else { continue }
          out.append(
            Entry(
              id: id, kind: .toolResult, at: at, text: cut.text, tool: nil, model: nil,
              fullBytes: cut.full, line: range, block: index))
        default:
          continue
        }
      }

    case nil:
      return
    }
  }

  /// A `system` entry worth a row. Compaction is the one that changes how everything above
  /// it should be read: the context was replaced, so the conversation genuinely restarts.
  private static func notice(in line: Line, cap: Int) -> (text: String, full: Int)? {
    if let metadata = line.compactMetadata {
      let trigger = metadata.trigger ?? "compaction"
      let text =
        "Compacted (\(trigger)): \(metadata.preTokens ?? 0) tokens became \(metadata.postTokens ?? 0)."
      return (text, text.utf8.count)
    }
    if let content = line.content { return cut(content, to: cap) }
    return nil
  }

  /// Trim, drop if empty, and keep at most `cap` **UTF-8 bytes**.
  ///
  /// Returns the uncut byte count beside the cut text, because "truncated" is not something
  /// a view can act on alone — it wants to say how much is missing.
  ///
  /// The cut is backed up to a UTF-8 scalar boundary, so it can never split a multi-byte
  /// character and hand the view a replacement glyph. It can still land inside a grapheme
  /// cluster — between a letter and its combining accent, or inside an emoji sequence —
  /// which costs at most one malformed character at a cut point that already says it is a
  /// cut point. Aligning to grapheme clusters instead is what costs the 53x.
  fileprivate static func cut(_ text: String, to cap: Int) -> (text: String, full: Int)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let view = trimmed.utf8
    let full = view.count
    guard full > cap else { return (trimmed, full) }
    var end = view.index(view.startIndex, offsetBy: cap)
    // 0b10xxxxxx is a continuation byte: walk back until the cut sits on a scalar start.
    while end > view.startIndex, view[end] & 0xC0 == 0x80 { end = view.index(before: end) }
    return (String(decoding: view[view.startIndex..<end], as: UTF8.self), full)
  }
}
