import Foundation

/// Reading a transcript without reading a transcript.
///
/// Transcripts run 1–13MB and over 5,000 lines, and `~/.claude/projects` is 2.8GB
/// on the machine this was measured on. Nothing here may scan a whole file on a
/// change; everything works from the tail.
///
/// `nonisolated` on purpose. The project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it every function here
/// would be main-actor isolated, and the detached deep scan in `SessionWatcher` could
/// not call any of them. **It does not move the work anywhere**: a synchronous
/// `nonisolated` function runs on whichever thread calls it. Keeping a read off the
/// thread drawing the window is the caller's decision, and `SessionWatcher` makes it
/// per read: the 64KB tail stays inline, the whole-file scan goes detached.
nonisolated enum TranscriptTitle {
  /// How much of the end of the file to read. The newest `ai-title` sits a median
  /// 15.3KB from the end (p90 29.6KB); 64KB finds it in 96% of 553 titled
  /// transcripts measured during the spike.
  static let tailBytes = 64 * 1024

  /// The last `tailBytes` of a transcript, and whether the first line in them is a
  /// fragment.
  ///
  /// Shared rather than repeated because more than one thing is read out of these
  /// files now — the title here, and a rate-limit refusal in `TranscriptQuota` — and
  /// they are read on the same events. One read, handed to both parsers, is what
  /// keeps a second reader from doubling the I/O of every transcript write.
  ///
  /// **`droppingFirstLine` is not optional politeness.** A tail read starts
  /// mid-line unless it started at byte zero, and that first fragment is not
  /// parseable JSON; every caller must drop it or hand the decoder garbage.
  static func tail(of url: URL) -> (chunk: Data, droppingFirstLine: Bool)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let chunk = try? handle.readToEnd() else { return nil }
    return (chunk, start > 0)
  }

  /// How much of the start of a transcript holds its opening context reading.
  ///
  /// Only one thing wants it: the session's *opening* figure, everything Claude Code
  /// loaded before the first prompt. The deep scan slices this much off the front of
  /// the buffer it has already read, rather than walking 50MB for an answer that sits
  /// near the top. A slice from byte zero starts on a line boundary by definition, so
  /// it needs no `droppingFirstLine`.
  ///
  /// **256KB, and the number is measured.** Across 30 transcripts over 100KB on
  /// 2026-09-12, the first `assistant` entry sat a median 61.6KB into the file, p90
  /// 98KB, max 193KB — the preamble ahead of it is the queued prompt, attachments and
  /// file-history entries. 256KB covered every one of them with room to spare.
  static let headBytes = 256 * 1024

  /// The last `ai-title` in a buffer of newline-delimited JSON, or nil.
  ///
  /// **Keeps the LAST match, not the first.** Titles are rewritten throughout a
  /// session — up to 267 `ai-title` entries in one transcript, and 289 transcripts
  /// where the title genuinely changed. The typical pattern is a draft title
  /// around line 15, a refined one a line later, then the refined one re-appended
  /// every 15–25 lines; taking the first gets the draft. The spike's
  /// `SessionWatch.swift` has this bug, which is why it is called out here.
  static func newestTitle(inChunk chunk: Data, droppingFirstLine: Bool) -> String? {
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      // Cheap reject before paying for a JSON parse: most lines are not titles.
      guard line.range(of: Data("ai-title".utf8)) != nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        object["type"] as? String == "ai-title",
        let title = object["aiTitle"] as? String, !title.isEmpty
      else { continue }
      return title
    }
    return nil
  }

  /// Whether the newest entry is an assistant `tool_use` with no `tool_result`
  /// answering it — the session is running a tool, or waiting for approval to.
  ///
  /// **Takes a buffer, not a URL**, like every other parser here: the caller has
  /// usually just read this tail for the title, and reading it a second time for this
  /// answer was the one place a transcript write still cost two reads.
  ///
  /// **Best-effort, and the UI says so.** `docs/claude-code-sessions.md` files this
  /// as open question 1: the rule is supported by a snapshot of 14 live sessions
  /// (idle ones ended on `stop_reason: end_turn`, working ones on an unanswered
  /// `tool_use`) but was never verified against a deliberately long tool call. It
  /// exists because pure write-recency reports a session busy with a 90-second
  /// command as idle — one session flipped to idle three times in 2.5 minutes.
  ///
  /// It cannot tell "running a tool" from "waiting for your approval": one session
  /// in that snapshot had sat on an unanswered `tool_use` for 10.5 hours. Telling
  /// those apart needs hooks, which this prototype deliberately does not install.
  static func isAwaitingToolResult(inChunk chunk: Data, droppingFirstLine: Bool) -> Bool {
    // Walk backwards to the newest entry that is a user or assistant turn;
    // everything else (file-history, cost-state, mode, …) is noise for this.
    for line in JSONLines.newestFirst(chunk, droppingFirstLine: droppingFirstLine) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let type = object["type"] as? String
      else { continue }

      switch type {
      case "assistant":
        return contentBlocks(of: object).contains { $0["type"] as? String == "tool_use" }
      case "user":
        // A user turn carrying tool_result blocks is the answer to the assistant's
        // tool_use, so the session is not waiting on one.
        return false
      default:
        continue
      }
    }
    return false
  }

  private static func contentBlocks(of entry: [String: Any]) -> [[String: Any]] {
    guard let message = entry["message"] as? [String: Any] else { return [] }
    return message["content"] as? [[String: Any]] ?? []
  }
}
