import Foundation

/// Reading a transcript without reading a transcript.
///
/// Transcripts run 1–13MB and over 5,000 lines, and `~/.claude/projects` is 2.8GB
/// on the machine this was measured on. Nothing here may scan a whole file on a
/// change; everything works from the tail.
enum TranscriptTitle {
  /// How much of the end of the file to read. The newest `ai-title` sits a median
  /// 15.3KB from the end (p90 29.6KB); 64KB finds it in 96% of 553 titled
  /// transcripts measured during the spike.
  static let tailBytes = 64 * 1024

  /// The title Claude Code shows for this session, or nil.
  ///
  /// **Keeps the LAST match, not the first.** Titles are rewritten throughout a
  /// session — up to 267 `ai-title` entries in one transcript, and 289 transcripts
  /// where the title genuinely changed. The typical pattern is a draft title
  /// around line 15, a refined one a line later, then the refined one re-appended
  /// every 15–25 lines; taking the first gets the draft. The spike's
  /// `SessionWatch.swift` has this bug, which is why it is called out here.
  ///
  /// `fullScanFallback` covers the ~4% of transcripts that stopped re-appending
  /// titles long ago (p99 is 4MB from the end, max 13MB). Off by default for the
  /// hot path; the watcher turns it on once per file and caches the answer.
  static func newestTitle(at url: URL, fullScanFallback: Bool = false) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let tail = try? handle.readToEnd() else { return nil }

    // A tail read starts mid-line unless it started at byte zero; that first
    // partial line is not parseable JSON and must not be handed to the decoder.
    if let title = newestTitle(inChunk: tail, droppingFirstLine: start > 0) {
      return title
    }
    guard fullScanFallback, start > 0 else { return nil }

    try? handle.seek(toOffset: 0)
    guard let whole = try? handle.readToEnd() else { return nil }
    return newestTitle(inChunk: whole, droppingFirstLine: false)
  }

  /// The last `ai-title` in a buffer of newline-delimited JSON.
  static func newestTitle(inChunk chunk: Data, droppingFirstLine: Bool) -> String? {
    var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
    if droppingFirstLine, !lines.isEmpty { lines.removeFirst() }

    for line in lines.reversed() {
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
  static func isAwaitingToolResult(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return false }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let tail = try? handle.readToEnd() else { return false }

    var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
    if start > 0, !lines.isEmpty { lines.removeFirst() }

    // Walk backwards to the newest entry that is a user or assistant turn;
    // everything else (file-history, cost-state, mode, …) is noise for this.
    for line in lines.reversed() {
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
