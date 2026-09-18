import CoreGraphics
import CryptoKit
import Foundation

/// Unit checks for the parts of Armada that are pure functions of their input.
///
/// A standalone `swiftc` binary rather than an XCTest bundle, for the reason
/// `scripts/license-check.swift` gives: the Xcode project has no test target, and
/// adding one means hand-editing project.pbxproj. The files under test are compiled
/// unmodified beside this driver, with the app target's own concurrency settings.
///
/// **What is covered is what fails silently.** Every parser here reads an
/// undocumented vendor file and returns nil on anything it does not recognise, so a
/// regression renders as an empty row rather than an error; a sort that is not a total
/// order renders as rows that swap places on a tick; and a forecast that reads the
/// wrong clock is a caption that is merely wrong.
///
/// Run with `make unit`.
@main
struct UnitCheck {
  static var failures = 0
  static var checks = 0

  static func main() {
    jsonLines()
    transcriptTitle()
    transcriptContext()
    transcriptLog()
    transcriptQuota()
    contextWindow()
    usageForecast()
    dayWeights()
    workingHours()
    sessionOrder()
    changelog()
    hostWindow()
    codexRollout()
    grokFiles()
    panelVisibility()
    licenseKey()
    projects()
    usageLedger()
    usageLines()
    usageIngest()
    projectStats()
    launchScript()
    newAccount()
    addedHomes()
    editorLaunch()
    claudeTrust()
    messageHook()
    mouseChord()
    modifierHold()
    mouseSentKey()

    print("")
    if failures == 0 {
      print("  \(checks) checks passed")
    } else {
      print("  \(failures) of \(checks) checks FAILED")
      exit(1)
    }
  }

  // MARK: - Harness

  static func section(_ title: String) {
    print("\n\(title)")
  }

  static func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() {
      print("  ok   \(label)")
    } else {
      print("  FAIL \(label)")
      failures += 1
    }
  }

  static func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    checks += 1
    if actual == expected {
      print("  ok   \(label)")
    } else {
      print("  FAIL \(label)")
      print("         got \(actual), expected \(expected)")
      failures += 1
    }
  }

  static func close(_ a: Double?, _ b: Double, within tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
  }

  /// Newline-joined, the way a transcript is written.
  static func ndjson(_ lines: [String], trailingNewline: Bool = true) -> Data {
    Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8)
  }

  static func strings(_ lines: some Sequence<Data>) -> [String] {
    lines.map { String(decoding: $0, as: UTF8.self) }
  }

  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  static let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }()

  static func date(_ iso: String) -> Date {
    UsageSnapshot.parseTimestamp(iso)!
  }

  static func parisDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
    paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  // MARK: - JSONLines

  /// The reader behind the transcript pane.
  ///
  /// Everything checked here fails silently in the app: a line that throws during decode is
  /// skipped, so a shape this parser does not expect renders as a conversation with a hole
  /// in it rather than as an error. The three that actually bit during the measuring —
  /// string `content`, base64 images, and a cut landing mid-character — each have a case.
  static func transcriptLog() {
    section("TranscriptLog")

    func entries(_ lines: [String], options: TranscriptLog.Options = .init())
      -> [TranscriptLog.Entry]
    {
      TranscriptLog.entries(
        inChunk: Data(lines.joined(separator: "\n").utf8), droppingFirstLine: false,
        options: options)
    }

    let turn = """
      {"type":"user","uuid":"u1","timestamp":"2026-09-18T10:00:00.000Z",\
      "message":{"role":"user","content":[{"type":"text","text":"why is it slow"}]}}
      """
    let reply = """
      {"type":"assistant","uuid":"a1","timestamp":"2026-09-18T10:00:01.000Z",\
      "message":{"role":"assistant","model":"claude-opus-5","content":[\
      {"type":"thinking","thinking":"weighing it up"},\
      {"type":"text","text":"because of the images"},\
      {"type":"tool_use","name":"Bash","input":{"command":"du -sh .","description":"size"}}]}}
      """
    let result = """
      {"type":"user","uuid":"u2","message":{"role":"user","content":[\
      {"type":"tool_result","content":"3.5G\\t."}]}}
      """

    let conversation = entries([turn, reply, result])
    expectEqual(
      "a turn, a thought, a reply, a call and its result",
      conversation.map(\.kind), [.user, .thinking, .assistant, .toolUse, .toolResult])
    expectEqual("the model rides on the assistant's blocks", conversation[2].model, "claude-opus-5")
    expectEqual("a tool call is named", conversation[3].tool, "Bash")
    expectEqual(
      "and summarised by the argument that says which, not by its whole input",
      conversation[3].text, "du -sh .")
    expectEqual(
      "one line becomes several rows with ids of their own",
      Set(conversation.map(\.id)).count, conversation.count)
    expectEqual(
      "the timestamp is passed through unparsed", conversation[0].at, "2026-09-18T10:00:00.000Z")

    // The shape that made the first JSONDecoder version drop 56 lines of a 24MB file.
    let bare = """
      {"type":"user","uuid":"u3","message":{"role":"user","content":"just a string"}}
      """
    expectEqual(
      "content as a bare string is a turn, not a dropped line",
      entries([bare]).map(\.text), ["just a string"])

    // 34% of a 24MB transcript. The payload must never become a String.
    let image = """
      {"type":"user","uuid":"u4","message":{"role":"user","content":[{"type":"tool_result",\
      "content":[{"type":"image","source":{"type":"base64","media_type":"image/png",\
      "data":"iVBORw0KGgoAAAANSUhEUg"}}]}]}}
      """
    expectEqual(
      "an image is named, never decoded", entries([image]).map(\.text), ["[image]"])

    // A sidechain is a conversation of its own; meta is injected context nobody typed.
    let sidechain = """
      {"type":"assistant","uuid":"s1","isSidechain":true,\
      "message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}
      """
    let meta = """
      {"type":"user","uuid":"m1","isMeta":true,\
      "message":{"role":"user","content":[{"type":"text","text":"injected"}]}}
      """
    check("subagent and meta turns are left out by default", entries([sidechain, meta]).isEmpty)
    expectEqual(
      "and come back when asked for",
      entries([sidechain, meta], options: .init(includeSidechain: true, includeMeta: true)).count,
      2)
    check(
      "thinking can be left out",
      entries([reply], options: .init(includeThinking: false)).allSatisfy { $0.kind != .thinking })

    // Entry types that are most of a transcript's lines and none of its conversation.
    let noise = [
      #"{"type":"ai-title","aiTitle":"Why it is slow"}"#,
      #"{"type":"file-history-snapshot","snapshot":{"a":1}}"#,
      #"{"type":"attachment","attachment":{"type":"model"}}"#,
      #"{"type":"queue-operation","operation":"add"}"#,
    ]
    check(
      "titles, snapshots, attachments and queue operations are not conversation",
      entries(noise).isEmpty)

    let compact = """
      {"type":"system","uuid":"c1","compactMetadata":{"trigger":"manual",\
      "preTokens":497468,"postTokens":17143}}
      """
    let boundary = entries([compact])
    expectEqual("a compaction is a notice", boundary.map(\.kind), [.notice])
    check(
      "and says what it did",
      boundary[0].text == "Compacted (manual): 497468 tokens became 17143.")

    // The cut, which is the whole reason this file exists.
    let long = String(repeating: "x", count: 5_000)
    let big = """
      {"type":"user","uuid":"u5","message":{"role":"user","content":[\
      {"type":"tool_result","content":"\(long)"}]}}
      """
    let cut = entries([big])
    expectEqual("a long result is cut to the cap", cut[0].text.utf8.count, 2_048)
    expectEqual("and reports its uncut size in bytes", cut[0].fullBytes, 5_000)
    check("and says it was cut", cut[0].truncated)
    check("a short one is not", conversation[4].truncated == false)
    expectEqual(
      "the cap is a setting", entries([big], options: .init(cap: 100))[0].text.utf8.count, 100)

    // A cut landing inside a multi-byte character must not produce a replacement glyph.
    let accented = String(repeating: "é", count: 2_000)  // two bytes each
    let unicode = """
      {"type":"user","uuid":"u6","message":{"role":"user","content":[\
      {"type":"tool_result","content":"\(accented)"}]}}
      """
    let trimmed = entries([unicode], options: .init(cap: 101))[0]
    check("a cut backs up to a scalar boundary", trimmed.text.utf8.count == 100)
    check("so no character is broken", !trimmed.text.contains("\u{FFFD}"))

    // The byte range is what makes "show all" possible without an index.
    let file = FileManager.default.temporaryDirectory
      .appending(path: "armada-unit-\(UUID().uuidString).jsonl")
    let text = ([turn, reply, big].joined(separator: "\n") + "\n")
    try? Data(text.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    if let whole = TranscriptLog.whole(of: file) {
      expectEqual("a file reads to the same entries as its buffer", whole.count, 5)
      let cutEntry = whole.first { $0.truncated }
      check("the cut entry is found again", cutEntry != nil)
      if let cutEntry {
        expectEqual(
          "and reopens at full length from its byte range",
          TranscriptLog.fullText(of: cutEntry, in: file)?.count, 5_000)
        check(
          "its range really is where the line sits",
          Data(text.utf8)[cutEntry.line].starts(with: Data(#"{"type":"user""#.utf8)))
      }
      // A tail must not report an offset relative to the window it read.
      if let tail = TranscriptLog.tail(of: file, bytes: 200) {
        check(
          "a tail's ranges are file offsets, not window offsets",
          tail.allSatisfy { $0.line.lowerBound >= 0 && $0.line.upperBound <= text.utf8.count })
        check(
          "and a tail's entries reopen too",
          tail.filter(\.truncated).allSatisfy { TranscriptLog.fullText(of: $0, in: file) != nil })
      }
    } else {
      check("a file reads", false)
    }

    check("an empty buffer yields nothing", entries([]).isEmpty)
    check("a line that is not JSON is skipped", entries(["{not json", turn]).count == 1)
  }

  static func jsonLines() {
    section("JSONLines")
    let plain = Data("a\nb\nc".utf8)
    expectEqual(
      "newest first over a whole buffer",
      strings(JSONLines.newestFirst(plain, droppingFirstLine: false)), ["c", "b", "a"])
    expectEqual(
      "oldest first over a whole buffer",
      strings(JSONLines.oldestFirst(plain, droppingFirstLine: false)), ["a", "b", "c"])

    let tail = Data("gment\"}\nb\nc\n".utf8)
    expectEqual(
      "the leading fragment is dropped newest first",
      strings(JSONLines.newestFirst(tail, droppingFirstLine: true)), ["c", "b"])
    expectEqual(
      "and oldest first",
      strings(JSONLines.oldestFirst(tail, droppingFirstLine: true)), ["b", "c"])

    expectEqual(
      "empty lines are never yielded",
      strings(JSONLines.newestFirst(Data("\n\na\n\n\nb\n\n".utf8), droppingFirstLine: false)),
      ["b", "a"])
    expectEqual(
      "a buffer opening on a newline still loses its first non-empty line",
      strings(JSONLines.oldestFirst(Data("\nwhole\nnext".utf8), droppingFirstLine: true)),
      ["next"])
    check(
      "a lone fragment yields nothing",
      Array(JSONLines.newestFirst(Data("fragment".utf8), droppingFirstLine: true)).isEmpty)
    check(
      "an empty buffer yields nothing",
      Array(JSONLines.oldestFirst(Data(), droppingFirstLine: false)).isEmpty
        && Array(JSONLines.newestFirst(Data(), droppingFirstLine: true)).isEmpty)

    // Indices that do not start at zero, which is what `prefix` and `dropFirst` return.
    let slice = Data("skip\nA\nB\nC".utf8).dropFirst(5)
    expectEqual(
      "a slice is walked from its own start",
      strings(JSONLines.oldestFirst(slice, droppingFirstLine: false)), ["A", "B", "C"])
    expectEqual(
      "and from its own end",
      strings(JSONLines.newestFirst(slice, droppingFirstLine: true)), ["C", "B"])

    // Against the split-and-drop every caller used to do, on buffers of every shape.
    var generator = SplitMix(seed: 42)
    var agrees = true
    for _ in 0..<300 {
      let bytes = (0..<Int(generator.next() % 40)).map { _ in
        generator.next() % 4 == 0 ? UInt8(0x0A) : UInt8(97 + generator.next() % 3)
      }
      let buffer = Data(bytes)
      for drop in [false, true] {
        var expected = buffer.split(separator: 0x0A, omittingEmptySubsequences: true)
          .map { Data($0) }
        if drop, !expected.isEmpty { expected.removeFirst() }
        let forward = JSONLines.oldestFirst(buffer, droppingFirstLine: drop).map { Data($0) }
        let backward = JSONLines.newestFirst(buffer, droppingFirstLine: drop).map { Data($0) }
        if forward != expected || backward != Array(expected.reversed()) { agrees = false }
      }
    }
    check("agrees with split-and-drop on 600 generated buffers", agrees)
  }

  // MARK: - TranscriptTitle

  static func transcriptTitle() {
    section("TranscriptTitle")
    let titled = ndjson([
      #"{"type":"ai-title","aiTitle":"Draft"}"#,
      #"{"type":"user","message":{"content":"hi"}}"#,
      #"{"type":"ai-title","aiTitle":"Refined"}"#,
      #"{"type":"ai-title","aiTitle":""}"#,
      #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#,
    ])
    expectEqual(
      "the last title wins, and an empty one is skipped",
      TranscriptTitle.newestTitle(inChunk: titled, droppingFirstLine: false), "Refined")

    let firstOnly = ndjson([
      #"{"type":"ai-title","aiTitle":"In the fragment"}"#, #"{"type":"user"}"#,
    ])
    expectEqual(
      "a title on a tail's first line is not trusted",
      TranscriptTitle.newestTitle(inChunk: firstOnly, droppingFirstLine: true), nil as String?)
    expectEqual(
      "the same line read from byte zero is",
      TranscriptTitle.newestTitle(inChunk: firstOnly, droppingFirstLine: false), "In the fragment")
    let broken = ndjson([
      #"tle","aiTitle":"half a line"}"#, #"{"type":"ai-title","aiTitle":"Whole"}"#,
    ])
    expectEqual(
      "a fragment is skipped, not parsed",
      TranscriptTitle.newestTitle(inChunk: broken, droppingFirstLine: true), "Whole")

    // The shapes are real: Claude Code keeps writing AI titles after a rename.
    let renamed = ndjson([
      #"{"type":"ai-title","aiTitle":"Before the rename"}"#,
      #"{"type":"custom-title","customTitle":"Competitive brief for apps"}"#,
      #"{"type":"ai-title","aiTitle":"New session"}"#,
    ])
    expectEqual(
      "a custom title outranks a newer AI one",
      TranscriptTitle.newestTitle(inChunk: renamed, droppingFirstLine: false),
      "Competitive brief for apps")
    let renamedTwice = ndjson([
      #"{"type":"custom-title","customTitle":"First name"}"#,
      #"{"type":"ai-title","aiTitle":"Between"}"#,
      #"{"type":"custom-title","customTitle":"Second name"}"#,
    ])
    expectEqual(
      "the newest custom title wins",
      TranscriptTitle.newestTitle(inChunk: renamedTwice, droppingFirstLine: false), "Second name")
    let fork = ndjson([
      #"{"type":"user","message":{"content":"hi"}}"#,
      #"{"type":"custom-title","customTitle":"Fill PDF templates (fork)"}"#,
    ])
    expectEqual(
      "a fork, which has no AI title",
      TranscriptTitle.newestTitle(inChunk: fork, droppingFirstLine: false),
      "Fill PDF templates (fork)")
    let emptyCustom = ndjson([
      #"{"type":"ai-title","aiTitle":"Kept"}"#, #"{"type":"custom-title","customTitle":""}"#,
    ])
    expectEqual(
      "an empty custom title falls back to the AI one",
      TranscriptTitle.newestTitle(inChunk: emptyCustom, droppingFirstLine: false), "Kept")
    let mentioned = ndjson([
      #"{"type":"ai-title","aiTitle":"Real"}"#,
      #"{"type":"user","message":{"content":"what is a custom-title entry?"}}"#,
    ])
    expectEqual(
      "a user line that mentions custom-title is not one",
      TranscriptTitle.newestTitle(inChunk: mentioned, droppingFirstLine: false), "Real")

    let toolUse = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1"}]}}"#
    let toolResult =
      #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#
    let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#
    let noise = #"{"type":"file-history-snapshot"}"#
    check(
      "an unanswered tool_use under later noise is awaiting",
      TranscriptTitle.isAwaitingToolResult(
        inChunk: ndjson([text, toolUse, noise]), droppingFirstLine: false))
    check(
      "an answered one is not",
      !TranscriptTitle.isAwaitingToolResult(
        inChunk: ndjson([toolUse, toolResult, noise]), droppingFirstLine: false))
    check(
      "a turn that ends on text is not",
      !TranscriptTitle.isAwaitingToolResult(
        inChunk: ndjson([toolUse, toolResult, text]), droppingFirstLine: false))
    check(
      "a tool_use only in the fragment is not trusted",
      !TranscriptTitle.isAwaitingToolResult(
        inChunk: ndjson([toolUse, noise]), droppingFirstLine: true))
  }

  // MARK: - TranscriptContext

  static func assistant(
    input: Int = 2, creation: Int = 1_000, read: Int, block: Int, at: String,
    model: String = "claude-opus-5"
  ) -> String {
    #"{"type":"assistant","apiBlockIndex":\#(block),"timestamp":"\#(at)","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(creation),"cache_read_input_tokens":\#(read),"output_tokens":7}}}"#
  }

  static func transcriptContext() {
    section("TranscriptContext")
    // The six requests measured in `TranscriptContext.series`'s comment, each written
    // three times over as blocks 0, 1 and 2 carrying an identical `usage`.
    let measured = [379_344, 383_213, 384_317, 386_716, 388_217, 389_013]
    var lines: [String] = []
    for (index, total) in measured.enumerated() {
      let at = String(format: "2026-09-12T10:00:%02d.000Z", index * 10)
      for block in 0..<3 {
        lines.append(assistant(read: total - 1_002, block: block, at: at))
      }
    }
    let buffer = ndjson(lines)
    let series = TranscriptContext.series(inChunk: buffer, droppingFirstLine: false)
    expectEqual("one reading per request, not one per block", series.map(\.total), measured)
    let growth = ContextGrowth(series: series)
    expectEqual("about 1.9k tokens per request", growth?.tokensPerRequest, 1_933)
    check(
      "per second, over the requests' own timestamps",
      close(growth?.tokensPerSecond, Double(389_013 - 379_344) / 50))
    expectEqual(
      "the newest reading sums all three input fields",
      TranscriptContext.newestReading(inChunk: buffer, droppingFirstLine: false)?.total, 389_013)
    expectEqual(
      "the baseline is the first reading in the head",
      TranscriptContext.baseline(inChunk: buffer)?.loadedAtStart, 379_344)

    let lateBlocks = ndjson([
      assistant(read: 388_011, block: 1, at: "2026-09-12T10:01:00Z"),
      assistant(read: 388_011, block: 2, at: "2026-09-12T10:01:00Z"),
    ])
    check(
      "a tail holding only blocks 1 and 2 has no series",
      TranscriptContext.series(inChunk: lateBlocks, droppingFirstLine: false).isEmpty)
    expectEqual(
      "but still has a current reading",
      TranscriptContext.newestReading(inChunk: lateBlocks, droppingFirstLine: false)?.total,
      389_013)

    let falling = TranscriptContext.series(
      inChunk: ndjson([
        assistant(read: 388_011, block: 0, at: "2026-09-12T10:00:00Z"),
        assistant(read: 58_998, block: 0, at: "2026-09-12T10:00:10Z"),
      ]), droppingFirstLine: false)
    check("no growth rate across a compaction", ContextGrowth(series: falling) == nil)

    let incomplete = ndjson([#"{"type":"assistant","message":{"usage":{"input_tokens":2}}}"#])
    check(
      "a usage missing its cache fields is no reading, rather than a zero",
      TranscriptContext.newestReading(inChunk: incomplete, droppingFirstLine: false) == nil)

    let models = ndjson([
      #"{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5[1m]"}}}"#,
      assistant(read: 10, block: 0, at: "2026-09-12T10:00:00Z"),
      #"{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-sonnet-5"}}}"#,
    ])
    expectEqual(
      "the newest model attachment wins",
      TranscriptContext.newestModelID(inChunk: models, droppingFirstLine: false),
      "claude-sonnet-5")

    let boundaries = ndjson([
      #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-12T09:00:00Z","compactMetadata":{"trigger":"auto","preTokens":150000}}"#,
      #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-12T11:00:00Z","compactMetadata":{"trigger":"manual","preTokens":390000,"postTokens":41000}}"#,
      assistant(read: 40_000, block: 0, at: "2026-09-12T11:00:05Z"),
    ])
    let compaction = TranscriptContext.newestCompaction(
      inChunk: boundaries, droppingFirstLine: false)
    check(
      "the newest compaction is found, with both of its figures",
      compaction?.wasManual == true && compaction?.preTokens == 390_000
        && compaction?.postTokens == 41_000)
  }

  // MARK: - TranscriptQuota

  static func transcriptQuota() {
    section("TranscriptQuota, and the cache's milliseconds")
    let refused =
      #"{"type":"assistant","timestamp":"2026-09-11T10:44:34.121Z","quotaLimits":{"status":"rejected","resetsAt":1789124400,"rateLimitType":"five_hour"},"error":"rate_limit"}"#
    let hit = TranscriptQuota.newestHit(
      inChunk: ndjson([#"{"type":"user"}"#, refused]), droppingFirstLine: false)
    expectEqual(
      "resetsAt is read as seconds", hit?.resetsAt, Date(timeIntervalSince1970: 1_789_124_400))
    check(
      "which lands in 2026, not in 1970 or the year 58000",
      hit.map { utc.component(.year, from: $0.resetsAt) } == 2026)
    expectEqual("the window is named", hit?.length, UsageWindowLength.fiveHour)

    let reported = refused.replacingOccurrences(of: "rejected", with: "allowed")
    check(
      "a window that merely reported itself is not a hit",
      TranscriptQuota.newestHit(inChunk: ndjson([reported]), droppingFirstLine: false) == nil)
    let unknown = refused.replacingOccurrences(of: "five_hour", with: "fortnightly")
    let unattributed = TranscriptQuota.newestHit(
      inChunk: ndjson([unknown]), droppingFirstLine: false)
    check(
      "an unknown window is a hit attributed to nothing",
      unattributed != nil && unattributed?.length == nil)
    let later = refused.replacingOccurrences(of: "10:44:34.121Z", with: "12:01:00.000Z")
    expectEqual(
      "the newest of two refusals wins",
      TranscriptQuota.newestHit(inChunk: ndjson([refused, later]), droppingFirstLine: false)?.at,
      date("2026-09-11T12:01:00.000Z"))

    let snapshot = UsageSnapshot.decode(root: [
      "cachedUsageUtilization": [
        "fetchedAtMs": 1_789_124_400_000.0,
        "utilization": [
          "five_hour": ["utilization": 17, "resets_at": "2026-09-10T23:00:00.431496+00:00"]
        ],
      ]
    ])
    expectEqual(
      "the cache's fetchedAtMs is read as milliseconds", snapshot?.fetchedAt,
      Date(timeIntervalSince1970: 1_789_124_400))
    check(
      "and its six-digit fractional resets_at parses",
      snapshot?.fiveHour?.utilization == 17 && snapshot?.fiveHour?.resetsAt != nil)
  }

  // MARK: - ContextWindow

  static func contextWindow() {
    section("ContextWindow.resolve")
    let session = ContextWindow.resolve(
      sessionModelID: "claude-opus-5[1m]", accountModelID: "sonnet",
      messageModelID: "claude-opus-5", observedTotal: 50_000)
    check(
      "the session's own record wins, and its suffix means 1M",
      session.limit == 1_000_000 && session.source == .sessionModel("claude-opus-5[1m]")
        && session.displayModelID == "claude-opus-5[1m]")

    let account = ContextWindow.resolve(
      sessionModelID: nil, accountModelID: "opus[1m]", messageModelID: "claude-opus-5",
      observedTotal: 50_000)
    check(
      "then the account's default, which is never shown as the session's model",
      account.limit == 1_000_000 && account.source == .accountDefault("opus[1m]")
        && account.displayModelID == nil)

    let assumed = ContextWindow.resolve(
      sessionModelID: nil, accountModelID: nil, messageModelID: "claude-opus-5",
      observedTotal: 200_000)
    check(
      "then the transcript's bare id, at 200k, even when exactly full",
      assumed.limit == 200_000 && assumed.source == .assumed("claude-opus-5"))

    let unknown = ContextWindow.resolve(
      sessionModelID: nil, accountModelID: nil, messageModelID: nil, observedTotal: 0)
    check("and nothing at all is 200k", unknown.limit == 200_000 && unknown.source == .unknown)

    let observed = ContextWindow.resolve(
      sessionModelID: nil, accountModelID: nil, messageModelID: "claude-opus-5",
      observedTotal: 389_013)
    check(
      "a reading past the resolved window raises it to 1M",
      observed.limit == 1_000_000 && observed.source == .observed)
    let beyond = ContextWindow.resolve(
      sessionModelID: "claude-opus-5[1m]", accountModelID: nil, messageModelID: nil,
      observedTotal: 1_200_000)
    check(
      "and past 1M, to the reading itself",
      beyond.limit == 1_200_000 && beyond.source == .observed)
  }

  // MARK: - UsageForecast

  static func usageForecast() {
    section("UsageForecast")
    // A five-hour window, 10:00 to 15:00.
    let reset = date("2026-09-14T15:00:00Z")
    func fiveHour(_ used: Int, asOf: String?, now: String, resetsAt: Date? = reset)
      -> UsageForecast?
    {
      UsageForecast(
        window: UsageWindow(utilization: used, resetsAt: resetsAt), length: .fiveHour,
        profile: .even, asOf: asOf.map(date), now: date(now), calendar: utc)
    }

    check(
      "no reset time, no forecast",
      fiveHour(50, asOf: "2026-09-14T12:30:00Z", now: "2026-09-14T12:30:00Z", resetsAt: nil)
        == nil)
    check(
      "no reading time, no forecast",
      fiveHour(50, asOf: nil, now: "2026-09-14T12:30:00Z") == nil)
    check(
      "a reading written after its window had reset",
      fiveHour(17, asOf: "2026-09-14T15:02:37Z", now: "2026-09-14T15:03:00Z") == nil)
    check(
      "a window that has reset since the reading",
      fiveHour(50, asOf: "2026-09-14T14:50:00Z", now: "2026-09-14T15:01:00Z") == nil)
    check(
      "a reading from before the window began",
      fiveHour(50, asOf: "2026-09-14T09:59:00Z", now: "2026-09-14T10:02:00Z") == nil)
    check(
      "a reading older than a tenth of the window",
      fiveHour(50, asOf: "2026-09-14T12:00:00Z", now: "2026-09-14T12:31:00Z") == nil)
    check(
      "one just inside that",
      fiveHour(50, asOf: "2026-09-14T12:00:00Z", now: "2026-09-14T12:29:00Z") != nil)
    let early = fiveHour(5, asOf: "2026-09-14T10:20:00Z", now: "2026-09-14T10:20:00Z")
    check(
      "under a tenth of the window elapsed still has a pace",
      close(early?.expected, 20.0 / 300) && close(early?.deltaPoints, 5 - 100 * 20.0 / 300))
    check(
      "but no projection, and nothing projected from it",
      early != nil && early?.projected == nil && early?.exhaustsAt == nil)

    let even = fiveHour(50, asOf: "2026-09-14T12:30:00Z", now: "2026-09-14T12:30:00Z")
    check(
      "half spent at half time projects 100%, and does not run out",
      close(even?.projected, 1) && even?.exhaustsAt == nil)
    let hot = fiveHour(75, asOf: "2026-09-14T12:30:00Z", now: "2026-09-14T12:30:00Z")
    check(
      "three quarters spent at half time runs out two thirds of the way in",
      close(
        hot?.exhaustsAt?.timeIntervalSince(date("2026-09-14T13:20:00Z")), 0, within: 0.001))
    check(
      "and says so first", hot?.verdict == .exhausting(hot?.exhaustsAt ?? .distantPast))

    // Weekly, a fifth spent. Far from the real clock on purpose: the forfeit is
    // reported only when the reset is within a day of the forecast's own `now`.
    let weeklyNow = date("2030-01-10T12:00:00Z")
    func weekly(resetsIn hours: Double) -> UsageForecast? {
      UsageForecast(
        window: UsageWindow(
          utilization: 20, resetsAt: weeklyNow.addingTimeInterval(hours * 3600)),
        length: .sevenDay, profile: .even, asOf: weeklyNow, now: weeklyNow, calendar: utc)
    }
    let closing = weekly(resetsIn: 12)
    check(
      "a weekly window half a day from reset, mostly unspent, is forfeiting",
      closing.map {
        if case .forfeiting = $0.verdict { return true }
        return false
      } == true)
    check(
      "the same reading two days out is on pace, by the forecast's clock",
      weekly(resetsIn: 48)?.verdict == .onPace)

    // Two hours into a weekly window: the first day, far under a tenth of the week.
    func firstDay(used: Int) -> UsageForecast? {
      UsageForecast(
        window: UsageWindow(
          utilization: used, resetsAt: weeklyNow.addingTimeInterval(166 * 3600)),
        length: .sevenDay, profile: .even, asOf: weeklyNow, now: weeklyNow, calendar: utc)
    }
    let burst = firstDay(used: 15)
    check(
      "a first day well past its pace says ahead, and does not claim it will run out",
      burst?.exhaustsAt == nil
        && burst.map {
          if case .ahead = $0.verdict { return true }
          return false
        } == true)
    check(
      "a quiet first day is on pace rather than forfeiting a week it has barely begun",
      firstDay(used: 1)?.verdict == .onPace)

    // A week from Monday 00:00, worked 09:00 to 17:00 and nothing outside that: 56
    // working hours, four of them gone by 13:00 on the Monday.
    let officeWeek = PaceProfile(
      days: .even, hours: WorkingHours(start: 9, end: 17, outside: 0))
    let mondayLunch = date("2030-01-07T13:00:00Z")
    let office = UsageForecast(
      window: UsageWindow(utilization: 5, resetsAt: date("2030-01-14T00:00:00Z")),
      length: .sevenDay, profile: officeWeek, asOf: mondayLunch, now: mondayLunch,
      calendar: utc)
    check("working hours shape the weekly pace", close(office?.expected, 4.0 / 56))
    let session = UsageForecast(
      window: UsageWindow(utilization: 5, resetsAt: date("2030-01-07T15:00:00Z")),
      length: .fiveHour, profile: officeWeek, asOf: mondayLunch, now: mondayLunch,
      calendar: utc)
    check("and leave the five-hour window alone", close(session?.expected, 3.0 / 5))
  }

  // MARK: - DayWeights

  static func dayWeights() {
    section("DayWeights")
    // Sunday first, Foundation's numbering: Monday at 1, Tuesday at 0.5.
    let weekdays = PaceProfile(days: DayWeights(values: [0, 1, 0.5, 1, 1, 1, 0]))
    let mondayNight = date("2026-09-14T22:00:00Z")
    expectEqual(
      "across midnight, each side at its own day's weight",
      weekdays.consumed(
        from: mondayNight, to: mondayNight.addingTimeInterval(4 * 3600), calendar: utc),
      2 * 3600 + 0.5 * 2 * 3600)

    // 2026-03-29, a Sunday, is 23 hours long in Paris; 2026-10-25 is 25.
    let springSaturday = parisDate(2026, 3, 28, 12)
    let springMonday = parisDate(2026, 3, 30, 12)
    expectEqual(
      "even weights across the spring change count real seconds",
      PaceProfile.even.consumed(from: springSaturday, to: springMonday, calendar: paris),
      47 * 3600)
    let sundayOnly = PaceProfile(days: DayWeights(values: [1, 0, 0, 0, 0, 0, 0]))
    expectEqual(
      "the short Sunday carries 23 hours of weight",
      sundayOnly.consumed(from: springSaturday, to: springMonday, calendar: paris), 23 * 3600)
    expectEqual(
      "the long one 25",
      sundayOnly.consumed(
        from: parisDate(2026, 10, 24, 12), to: parisDate(2026, 10, 26, 12), calendar: paris),
      25 * 3600)
    expectEqual(
      "segments end at local midnight on both sides of the change",
      PaceProfile(days: DayWeights(values: [0, 1, 0, 0, 0, 0, 1])).consumed(
        from: springSaturday, to: springMonday, calendar: paris),
      24 * 3600)

    expectEqual(
      "the inverse walks the same short day",
      PaceProfile.even.date(
        reaching: 47 * 3600, from: parisDate(2026, 3, 28, 0), limit: parisDate(2026, 4, 4, 0),
        calendar: paris),
      parisDate(2026, 3, 30, 0))
    expectEqual(
      "and steps over a zero-weight Sunday rather than dividing by it",
      PaceProfile(days: DayWeights(values: [0, 1, 1, 1, 1, 1, 1])).date(
        reaching: 2 * 3600, from: date("2026-09-12T23:00:00Z"),
        limit: date("2026-09-19T00:00:00Z"), calendar: utc),
      date("2026-09-14T01:00:00Z"))
    expectEqual(
      "a target past the limit is never reached",
      PaceProfile.even.date(
        reaching: 10 * 3600, from: mondayNight, limit: mondayNight.addingTimeInterval(3600),
        calendar: utc),
      nil as Date?)

    check("an all-zero profile degrades to even", DayWeights(stored: "0,0,0,0,0,0,0") == .even)
    check("so does a short one", DayWeights(stored: "100,50") == .even)
    expectEqual(
      "a stored profile round-trips",
      DayWeights(stored: "25,100,100,50,100,100,25").stored, "25,100,100,50,100,100,25")
  }

  // MARK: - WorkingHours

  static func workingHours() {
    section("WorkingHours")
    let officeHours = WorkingHours(start: 9, end: 17, outside: 0.5)
    let monday = date("2026-09-14T00:00:00Z")
    let tuesday = date("2026-09-15T00:00:00Z")
    expectEqual(
      "a day is its working hours at full weight and the rest at the outside weight",
      PaceProfile(days: .even, hours: officeHours).consumed(
        from: monday, to: tuesday, calendar: utc),
      8 * 3600 + 0.5 * 16 * 3600)

    // Monday at 1, Tuesday at 0.5, and a shift from 22:00 to 02:00 with nothing outside it.
    let lateShift = PaceProfile(
      days: DayWeights(values: [0, 1, 0.5, 1, 1, 1, 0]),
      hours: WorkingHours(start: 22, end: 2, outside: 0))
    expectEqual(
      "a range across midnight counts its small hours at the next day's weight",
      lateShift.consumed(
        from: date("2026-09-14T12:00:00Z"), to: date("2026-09-15T12:00:00Z"), calendar: utc),
      2 * 3600 + 0.5 * 2 * 3600)

    // 02:00 does not exist on 2026-03-29 in Paris, and happens twice on 2026-10-25.
    expectEqual(
      "a start hour the spring change skips begins at 03:00",
      PaceProfile(days: .even, hours: WorkingHours(start: 2, end: 12, outside: 0)).consumed(
        from: parisDate(2026, 3, 29, 0), to: parisDate(2026, 3, 30, 0), calendar: paris),
      9 * 3600)
    expectEqual(
      "and the autumn change's repeated hour is worked twice",
      PaceProfile(days: .even, hours: WorkingHours(start: 1, end: 4, outside: 0)).consumed(
        from: parisDate(2026, 10, 25, 0), to: parisDate(2026, 10, 26, 0), calendar: paris),
      4 * 3600)

    expectEqual(
      "the inverse steps over a night weighted to nothing",
      PaceProfile(days: .even, hours: WorkingHours(start: 9, end: 17, outside: 0)).date(
        reaching: 2 * 3600, from: date("2026-09-14T16:00:00Z"),
        limit: date("2026-09-21T00:00:00Z"), calendar: utc),
      date("2026-09-15T10:00:00Z"))
    expectEqual(
      "boundaries fall at both ends of the working hours and at midnight",
      PaceProfile(days: .even, hours: officeHours).boundaries(
        from: monday, to: tuesday, calendar: utc),
      [date("2026-09-14T09:00:00Z"), date("2026-09-14T17:00:00Z"), tuesday])
    expectEqual(
      "and only at midnight when every hour counts the same",
      PaceProfile.even.boundaries(from: monday, to: tuesday, calendar: utc), [tuesday])

    check("the default counts every hour the same", WorkingHours.flat.isFlat)
    check(
      "so does a range that starts where it ends",
      WorkingHours(start: 9, end: 9, outside: 0).isFlat)
    check("anything unparseable is the default", WorkingHours(stored: "9,x") == .flat)
    expectEqual("a stored range round-trips", WorkingHours(stored: "9,20,10").stored, "9,20,10")
    expectEqual(
      "and is clamped on the way in", WorkingHours(stored: "-3,30,150").stored, "0,23,100")
  }

  // MARK: - SessionOrder

  static func sessionOrder() {
    section("SessionOrder")
    let base = date("2026-09-14T10:00:00Z")

    // Collisions on every key but the id, and activity inside one bucket.
    var items: [FakeItem] = []
    for index in 0..<24 {
      // Two checkouts share the folder name "api", as `~/work/api` and `~/oss/api` do.
      let path = ["/work/api", "/oss/api", "/work/web"][index % 3]
      items.append(
        FakeItem(
          id: "s\(index)",
          displayName: ["api", "Api", "web", "armada-2", "armada-10"][index % 5],
          projectName: (path as NSString).lastPathComponent,
          projectPath: path,
          startedAt: index % 4 == 0 ? nil : base.addingTimeInterval(Double(index % 3) * 60),
          lastActivity: base.addingTimeInterval(Double(index % 5) * 20),
          stateKey: ["waiting", "working", "idle"][index % 3],
          stateLabel: ["Waiting", "Working", "Idle"][index % 3],
          stateRank: index % 3,
          contextTokens: index % 2 == 0 ? index * 1_000 : nil))
    }

    var generator = SplitMix(seed: 7)
    for sort in SessionSort.allCases {
      let reference = SessionOrder.sorted(items, by: sort).map(\.id)
      var total = true
      for _ in 0..<20 {
        if SessionOrder.sorted(items.shuffled(using: &generator), by: sort).map(\.id) != reference {
          total = false
        }
      }
      check("sorting by \(sort.rawValue) is a total order", total)
    }
    for grouping in SessionGrouping.allCases {
      func layout(_ input: [FakeItem]) -> [String] {
        SessionOrder.arrange(input, sort: .activity, grouping: grouping).map {
          "\($0.id):" + $0.items.map(\.id).joined(separator: ",")
        }
      }
      let reference = layout(items)
      let stable = (0..<20).allSatisfy { _ in layout(items.shuffled(using: &generator)) == reference
      }
      check("grouping by \(grouping.rawValue) is the same from any input order", stable)
    }

    let quiet = FakeItem(
      id: "quiet", startedAt: base.addingTimeInterval(-600),
      lastActivity: base.addingTimeInterval(50))
    let fresh = FakeItem(
      id: "fresh", startedAt: base.addingTimeInterval(-300),
      lastActivity: base.addingTimeInterval(10))
    let latest = FakeItem(
      id: "latest", startedAt: base.addingTimeInterval(-900),
      lastActivity: base.addingTimeInterval(65))
    expectEqual(
      "activity inside one minute falls back to newest started, so rows hold still",
      SessionOrder.sorted([quiet, fresh, latest], by: .activity).map(\.id),
      ["latest", "fresh", "quiet"])

    expectEqual(
      "names compare numerically, armada-2 before armada-10",
      SessionOrder.sorted(
        [FakeItem(id: "b", displayName: "armada-10"), FakeItem(id: "a", displayName: "armada-2")],
        by: .name
      ).map(\.displayName),
      ["armada-2", "armada-10"])

    let byProject = SessionOrder.sorted(items, by: .project).map(\.projectPath)
    let apis = byProject.filter { $0.hasSuffix("/api") }
    check(
      "two checkouts sharing a folder name stay contiguous",
      Array(byProject.prefix(apis.count)) == apis
        && apis == apis.sorted()
        && Set(apis).count == 2)

    let projectGroups = SessionOrder.group(items, by: .project)
    expectEqual(
      "project sections run by title, then path",
      projectGroups.map(\.id), ["/oss/api", "/work/api", "/work/web"])
    expectEqual(
      "state sections run by triage rank",
      SessionOrder.group(items, by: .state).map(\.id), ["waiting", "working", "idle"])
    let flat = SessionOrder.group(items, by: .none)
    check(
      "no grouping is one group holding everything", flat.count == 1 && flat[0].items.count == 24)
    check(
      "a section with no readings totals nil, not zero",
      SessionGroup(id: "x", title: "x", subtitle: nil, items: [FakeItem(id: "n")]).contextTokens
        == nil)
  }

  // MARK: - Changelog

  static func changelog() {
    section("Changelog.isVersion")
    check("1.10.0 is newer than 1.9.0", Changelog.isVersion("1.10.0", newerThan: "1.9.0"))
    check("and not the other way round", !Changelog.isVersion("1.9.0", newerThan: "1.10.0"))
    check("a version is not newer than itself", !Changelog.isVersion("1.0.0", newerThan: "1.0.0"))
    check(
      "a missing component counts as zero",
      !Changelog.isVersion("1.0", newerThan: "1.0.0")
        && Changelog.isVersion("1.0.1", newerThan: "1.0"))
    check("something unparseable is not newer", !Changelog.isVersion("next", newerThan: "0.0.1"))
  }

  // MARK: - HostWindow

  static func hostWindow() {
    section("HostWindow.mentions")
    check(
      "a folder named as a word of its own",
      HostWindow.mentions("Menubar icon halo border — armada — Skitrust", "armada"))
    check("inside brackets", HostWindow.mentions("[armada] main", "armada"))
    check("as the whole title", HostWindow.mentions("armada", "armada"))
    check("not as the stem of a longer folder", !HostWindow.mentions("armada-old — Code", "armada"))
    check("not as a file name", !HostWindow.mentions("armada.ts — web", "armada"))
    check(
      "not inside a word",
      !HostWindow.mentions("armadas", "armada") && !HostWindow.mentions("my_armada", "armada"))
    check(
      "a later whole-word mention still counts",
      HostWindow.mentions("armada-old, then armada", "armada"))
    check("an empty folder matches nothing", !HostWindow.mentions("anything", ""))

    // The names are VS Code's own, read off live tabs on 2026-09-15.
    section("HostWindow.tabLabel")
    check(
      "a short title, with the editor group after it",
      HostWindow.tabLabel(
        "Settings sidebar reorder, Editor Group 1", names: "Settings sidebar reorder"))
    check(
      "a short title, with nothing after it",
      HostWindow.tabLabel("iPadOS support", names: "iPadOS support"))
    check(
      "a long title, cut at an ellipsis",
      HostWindow.tabLabel(
        "Session list popover but…, Editor Group 1",
        names: "Session list popover button and ordering"))
    check(
      "a cut that keeps the space before the ellipsis",
      HostWindow.tabLabel(
        "Armada supervisor agent …", names: "Armada supervisor agent architecture"))
    check(
      "a title with commas of its own",
      HostWindow.tabLabel(
        "Talk to Armada: a shortcut, a spoken question, Editor Group 2",
        names: "Talk to Armada: a shortcut, a spoken question"))
    check(
      "not a longer tab for a shorter title",
      !HostWindow.tabLabel("Settings sidebar reorder, Editor Group 1", names: "Settings sidebar"))
    check(
      "not a tab shown in full for a longer title",
      !HostWindow.tabLabel("iPadOS support", names: "iPadOS support for balise"))
    check(
      "not a cut that is the whole title",
      !HostWindow.tabLabel("Session list popover but…", names: "Session list popover but"))
    check(
      "not a cut that differs",
      !HostWindow.tabLabel("Session list popover but…", names: "Session sort menu and grouping"))
    check("an empty title matches nothing", !HostWindow.tabLabel("", names: ""))
  }

  // MARK: - CodexRollout

  static func panelVisibility() {
    section("PanelVisibility")
    let claude = "/Users/me/.claude"
    let grok = "/Users/me/.grok"
    let hidden = PanelVisibility.setting(grok, shown: false, in: "")
    check(
      "hiding stores the id, and nothing else is hidden",
      PanelVisibility.hidden(stored: hidden) == [grok])
    check(
      "hiding twice stores it once",
      PanelVisibility.setting(grok, shown: false, in: hidden) == hidden)
    let both = PanelVisibility.setting(claude, shown: false, in: hidden)
    check(
      "showing one again leaves the other hidden",
      PanelVisibility.hidden(stored: PanelVisibility.setting(grok, shown: true, in: both))
        == [claude])
    check("nothing stored hides nothing", PanelVisibility.hidden(stored: "").isEmpty)

    section("MenuBarHalo with Grok")
    check(
      "a working Grok session lights the default halo",
      MenuBarHalo.working.isLit(
        claudeWorking: 0, claudeBlocked: 0, codexWorking: 0, codexAwaitingInput: 0,
        grokWorking: 1))
    check(
      "an idle open Grok session lights only the widest rung",
      !MenuBarHalo.blocked.isLit(
        claudeWorking: 0, claudeBlocked: 0, codexWorking: 0, codexAwaitingInput: 0,
        grokAwaitingInput: 1)
        && MenuBarHalo.waiting.isLit(
          claudeWorking: 0, claudeBlocked: 0, codexWorking: 0, codexAwaitingInput: 0,
          grokAwaitingInput: 1)
    )
  }

  static func grokFiles() {
    section("GrokFiles")
    // Shapes from grok 1.0.34, 2026-09-17. See docs/grok-sessions.md.
    let active = GrokFiles.activeSessions(
      Data(
        #"[{"session_id":"01A0AED0-C99B-7CD1-A1AC-B6FD20AC67A6","pid":1623,"cwd":"/work/cadence","opened_at":"2026-09-17T10:01:54.041918Z"},{"session_id":"x","pid":0}]"#
          .utf8))
    check(
      "active sessions keep a real pid, lowercase the id, and drop the rest",
      active == [
        GrokFiles.ActiveSession(
          sessionId: "01a0aed0-c99b-7cd1-a1ac-b6fd20ac67a6", pid: 1623, cwd: "/work/cadence")
      ])

    let summary = GrokFiles.summary(
      Data(
        #"{"info":{"id":"01a0af67-f521-75d2-b771-920a03e5fdf9","cwd":"/work/armada"},"session_summary":"","created_at":"2026-09-17T12:47:00.906515Z","last_active_at":"2026-09-17T12:47:11.224707Z","current_model_id":"grok-4.6","generated_title":"French Greeting"}"#
          .utf8))
    check(
      "a TUI summary gives its title, model, folder and six-digit dates",
      summary?.title == "French Greeting" && summary?.model == "grok-4.6"
        && summary?.projectName == "armada" && summary?.kind == nil
        && summary?.createdAt != nil && summary?.updatedAt != nil)
    let headless = GrokFiles.summary(
      Data(#"{"info":{"id":"a","cwd":"/w/p"},"session_summary":"","session_kind":"headless"}"#.utf8)
    )
    check(
      "an empty session_summary is no title, and headless is read",
      headless?.title == nil && headless?.kind == "headless")

    func tail(_ updates: [String]) -> GrokFiles.UpdatesTail {
      GrokFiles.updatesTail(
        Data(
          updates.map { #"{"timestamp":1789648307,"method":"m","params":{"update":\#($0)}}"# }
            .joined(separator: "\n").utf8), droppingFirstLine: false)
    }
    let prompt = #"{"sessionUpdate":"user_message_chunk"}"#
    let tool = #"{"sessionUpdate":"tool_call_update","status":"completed"}"#
    let stopHook = #"{"sessionUpdate":"hook_execution","event_name":"stop"}"#
    let completed = #"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#
    let endHook = #"{"sessionUpdate":"hook_execution","event_name":"session_end"}"#
    let background = #"{"sessionUpdate":"background_tasks","tasks":[]}"#
    let promptHook = #"{"sessionUpdate":"hook_execution","event_name":"user_prompt_submit"}"#
    check(
      "a tool call with no turn_completed is a running turn", tail([prompt, tool]).isTurnRunning)
    check(
      "hooks after turn_completed do not reopen the turn",
      !tail([prompt, tool, stopHook, completed, endHook, stopHook, background]).isTurnRunning)
    check(
      "a prompt hook after a finished turn opens the next",
      tail([prompt, completed, promptHook]).isTurnRunning)
    check(
      "another turn_ update also ends a turn",
      !tail([prompt, #"{"sessionUpdate":"turn_cancelled"}"#]).isTurnRunning)
    check(
      "the timestamp is epoch seconds",
      tail([prompt]).lastEventAt == Date(timeIntervalSince1970: 1_789_648_307))

    let usage = GrokFiles.usage(
      Data(
        #"{"sessionId":"a","session":{"totalTokens":72175,"costUsdTicks":196472400,"turnCount":2}}"#
          .utf8))
    check(
      "usage.json gives tokens, turns and dollars from ticks",
      usage?.totalTokens == 72175 && usage?.turnCount == 2
        && abs((usage?.costUSD ?? 0) - 0.01964724) < 1e-9)
    let context = GrokFiles.context(
      Data(#"{"turnCount":2,"contextTokensUsed":11790,"contextWindowTokens":500000}"#.utf8))
    expectEqual(
      "signals.json gives the context Grok measured", context,
      GrokFiles.Context(used: 11790, window: 500000))
    let billing =
      (try? JSONSerialization.jsonObject(
        with: Data(
          #"{"config":{"creditUsagePercent":13.4,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-15T21:25:12.584887+00:00","end":"2026-09-22T21:25:12.584887+00:00"},"onDemandCap":{"val":0},"isUnifiedBillingUser":true,"billingPeriodEnd":"2026-09-22T21:25:12.584887+00:00"},"subscription_tier":"X Premium"}"#
            .utf8))) as? [String: Any] ?? [:]
    let limits = GrokFiles.limits(billing, observedAt: Date(timeIntervalSince1970: 0))
    check(
      "the billing answer is a weekly window with its reset and tier",
      limits?.utilization == 13 && limits?.length == .sevenDay && limits?.tier == "X Premium"
        && limits?.resetsAt == UsageSnapshot.parseTimestamp("2026-09-22T21:25:12.584887+00:00")
        && limits?.asSnapshot.sevenDay?.utilization == 13 && limits?.asSnapshot.fiveHour == nil)
    let monthly = GrokFiles.limits(
      [
        "config": [
          "creditUsagePercent": 40, "currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY"],
        ]
      ],
      observedAt: .now)
    check(
      "a monthly allowance has no weekly window to pace",
      monthly?.period == "monthly" && monthly?.length == nil && monthly?.window(.sevenDay) == nil)
    check(
      "no credit percentage is no reading",
      GrokFiles.limits(["config": [:]], observedAt: .now) == nil)
    check(
      "session directories are UUIDs",
      GrokFiles.isSessionId("01a0af59-ee50-7b73-a473-2f2bcf56012e")
        && !GrokFiles.isSessionId("session_search.sqlite"))
  }

  static func codexRollout() {
    section("CodexRollout")
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "armada-unit-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func write(_ name: String, _ text: String) -> URL {
      let url = directory.appending(path: name, directoryHint: .notDirectory)
      try? Data(text.utf8).write(to: url)
      return url
    }

    let sessionID = "0199aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let meta =
      #"{"timestamp":"2026-09-11T05:01:34.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/work/armada","originator":"codex_cli_rs","cli_version":"0.40.0"}}"#
    let turn =
      #"{"timestamp":"2026-09-11T05:01:35.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#

    let short = CodexRollout.meta(at: write("short.jsonl", meta + "\n" + turn))
    check(
      "a short file keeps its last line, and with it the model",
      short?.sessionId == sessionID && short?.model == "gpt-5-codex")
    check(
      "with a trailing newline as well",
      CodexRollout.meta(at: write("newline.jsonl", meta + "\n" + turn + "\n"))?.model
        == "gpt-5-codex")
    check(
      "a file that is only its session_meta is still a session",
      CodexRollout.meta(at: write("alone.jsonl", meta))?.cwd == "/work/armada")

    let message = String(repeating: "x", count: 1_000)
    var long = meta + "\n" + turn + "\n"
    while long.utf8.count < CodexRollout.headBytes + 4_096 {
      long +=
        #"{"timestamp":"2026-09-11T05:02:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"\#(message)"}}"#
        + "\n"
    }
    let longURL = write("long.jsonl", long)
    let truncated = CodexRollout.meta(at: longURL)
    check(
      "a file longer than the head read still parses its head",
      truncated?.model == "gpt-5-codex" && truncated?.startedAt != nil)
    expectEqual(
      "and its tail is read from the newest whole line",
      CodexRollout.tail(at: longURL)?.lastEventType, "agent_message")
  }

  // MARK: - Projects

  static func projects() {
    section("ProjectPath")
    expectEqual(
      "a trailing slash is dropped", ProjectPath.normalize("/work/armada/"), "/work/armada")
    expectEqual("but the root keeps its only slash", ProjectPath.normalize("/"), "/")
    expectEqual(
      "dot segments are resolved without touching the disk",
      ProjectPath.normalize("/work/./armada/apps/.."), "/work/armada")

    check("a folder contains itself", ProjectPath.contains("/work/armada", "/work/armada"))
    check("and anything below it", ProjectPath.contains("/work/armada", "/work/armada/apps/apple"))
    check(
      "but not a sibling whose name starts the same way",
      !ProjectPath.contains("/work/armada", "/work/armada-old"))
    check(
      "whichever side carries a trailing slash",
      ProjectPath.contains("/work/armada/", "/work/armada")
        && ProjectPath.contains("/work/armada", "/work/armada/apps/"))
    check("the root contains everything", ProjectPath.contains("/", "/work"))

    let nested = [
      ProjectPath.Candidate(id: "outer", keys: ["/work/armada"]),
      ProjectPath.Candidate(id: "inner", keys: ["/work/armada/apps/website"]),
      ProjectPath.Candidate(id: "linked", keys: ["/Users/me/link", "/Volumes/data/real"]),
    ]
    expectEqual(
      "the deepest project wins",
      ProjectPath.deepest(for: "/work/armada/apps/website/src", in: nested), "inner")
    expectEqual(
      "whatever order the candidates come in",
      ProjectPath.deepest(for: "/work/armada/apps/website", in: Array(nested.reversed())), "inner")
    expectEqual(
      "a subfolder only the outer project holds is the outer one's",
      ProjectPath.deepest(for: "/work/armada/apps/apple", in: nested), "outer")
    expectEqual(
      "a worktree inside a repository counts for the repository",
      ProjectPath.deepest(for: "/work/armada/.claude/worktrees/feature", in: nested), "outer")
    expectEqual(
      "a second key, the resolved path, matches too",
      ProjectPath.deepest(for: "/Volumes/data/real/src", in: nested), "linked")
    expectEqual(
      "a folder outside every project has none",
      ProjectPath.deepest(for: "/work/other", in: nested), nil as String?)

    check("/tmp is temporary", ProjectPath.isTemporary("/tmp/scratch"))
    check(
      "and so is the /private/tmp it resolves to",
      ProjectPath.isTemporary("/private/tmp/claude-501/x/scratchpad"))
    check("a home folder is not", !ProjectPath.isTemporary("/Users/me/work"))

    section("ProjectsFile")
    let added = date("2026-09-14T13:00:00Z")
    let saved = [
      Project(
        id: "A", path: "/work/armada", name: nil, agent: .claude(accountID: "/Users/me/.claude"),
        addedAt: added),
      Project(
        id: "B", path: "/work/site", name: "Marketing", agent: .codex(homeID: "/Users/me/.codex"),
        addedAt: added),
      Project(
        id: "C", path: "/work/cadence", name: nil, agent: .grok(homeID: "/Users/me/.grok"),
        addedAt: added),
    ]
    let data = try? ProjectsFile.encode(saved)
    expectEqual("a list round-trips", data.flatMap { try? ProjectsFile.decode($0) }, saved)
    check(
      "with short keys and unescaped slashes, since people open this file",
      data.map { String(decoding: $0, as: UTF8.self).contains(#""p":"/work/armada""#) } == true)
    check(
      "a file from a newer build is refused rather than read as empty",
      (try? ProjectsFile.decode(Data(#"{"v":2,"projects":[]}"#.utf8))) == nil)
    expectEqual("an unnamed project is called after its folder", saved[0].displayName, "armada")
    expectEqual("a named one by its name", saved[1].displayName, "Marketing")
    check(
      "a Grok Build project is stored as grok",
      data.map { String(decoding: $0, as: UTF8.self).contains(#""g":"grok""#) } == true)
  }

  // MARK: - Usage ledger

  static func claudeLine(
    id: String, model: String = "claude-opus-5", input: Int = 2, write: Int? = 100,
    read: Int? = 1_000, output: Int = 50, at: String = "2026-09-14T10:00:00.000Z",
    cwd: String = "/work/armada", session: String = "s1"
  ) -> String {
    var usage = #""input_tokens":\#(input),"output_tokens":\#(output)"#
    if let write { usage += #","cache_creation_input_tokens":\#(write)"# }
    if let read { usage += #","cache_read_input_tokens":\#(read)"# }
    return
      #"{"type":"assistant","cwd":"\#(cwd)","sessionId":"\#(session)","timestamp":"\#(at)","message":{"id":"\#(id)","model":"\#(model)","usage":{\#(usage)}}}"#
  }

  static func codexTokens(
    _ input: Int, cached: Int, output: Int, reasoning: Int = 0, at: String
  ) -> String {
    #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}}}}"#
  }

  static func usageLedger() {
    section("StableHash and LocalDay")
    expectEqual(
      "FNV-1a of nothing is its offset basis", StableHash.fnv1a64([UInt8]()),
      0xcbf2_9ce4_8422_2325)
    expectEqual(
      "and of \"a\" the published value, the same in every process",
      StableHash.fnv1a64(Array("a".utf8)), 0xaf63_dc4c_8601_ec8c)
    expectEqual(
      "a day is the local one", LocalDay.key(date("2026-09-13T23:30:00Z"), calendar: paris),
      20_260_914)
    expectEqual(
      "in UTC the same instant is the day before",
      LocalDay.key(date("2026-09-13T23:30:00Z"), calendar: utc), 20_260_913)
    expectEqual(
      "stepping back across a month", LocalDay.adding(-6, to: 20_260_903, calendar: utc),
      20_260_828)
  }

  static func usageLines() {
    section("Usage lines")
    let event = ClaudeUsageLine.parse(Data(claudeLine(id: "msg_1").utf8))
    check(
      "an assistant line is one event with its four token kinds",
      event?.messageID == "msg_1"
        && event?.tokens == TokenTally(fresh: 2, cacheWrite: 100, cacheRead: 1_000, output: 50))
    expectEqual(
      "missing cache fields count as zero rather than dropping the message",
      ClaudeUsageLine.parse(Data(claudeLine(id: "m", write: nil, read: nil).utf8))?.tokens.total,
      52)
    check(
      "a synthetic message is not usage",
      ClaudeUsageLine.parse(Data(claudeLine(id: "m", model: "<synthetic>").utf8)) == nil)
    check(
      "nor is a line without a message id",
      ClaudeUsageLine.parse(
        Data(
          #"{"type":"assistant","timestamp":"2026-09-14T10:00:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
            .utf8)) == nil)
    check(
      "nor a user line that mentions usage",
      ClaudeUsageLine.parse(Data(#"{"type":"user","message":{"content":"\"usage\""}}"#.utf8))
        == nil)

    let tokens = CodexUsageLine.parse(
      Data(
        codexTokens(1_000, cached: 800, output: 40, reasoning: 10, at: "2026-09-14T10:00:00Z")
          .utf8))
    if case .tokenCount(let cumulative, _) = tokens {
      expectEqual(
        "Codex input includes the cached part, so fresh is the rest",
        cumulative.delta(from: nil),
        TokenTally(fresh: 200, cacheWrite: 0, cacheRead: 800, output: 40, reasoning: 10))
    } else {
      check("a token_count line parses", false)
    }
    check(
      "a token_count with no info yet is nothing",
      CodexUsageLine.parse(
        Data(
          #"{"timestamp":"2026-09-14T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#
            .utf8)) == nil)
    check(
      "turn_context carries the model",
      CodexUsageLine.parse(
        Data(#"{"type":"turn_context","payload":{"model":"gpt-5.4","cwd":"/work"}}"#.utf8))
        == .turnContext(model: "gpt-5.4"))
    check(
      "session_meta carries the folder and whether it is a subagent",
      CodexUsageLine.parse(
        Data(
          #"{"type":"session_meta","payload":{"id":"x","cwd":"/work","parent_thread_id":"p"}}"#
            .utf8)) == .meta(cwd: "/work", isChild: true))
  }

  /// Feeds `buffers` to an ingest one after another, carrying what it did not consume, the
  /// way the indexer's chunked reads do. Totals per day.
  static func ingest(
    _ buffers: [Data], seen: inout Set<UInt64>, cursor: inout IngestCursor, codex: Bool = false
  ) -> [Int: TokenTally] {
    var totals: [Int: TokenTally] = [:]
    var pending = Data()
    for buffer in buffers {
      pending.append(buffer)
      let used =
        codex
        ? FileIngest.codex(
          pending, cursor: &cursor, calendar: utc, claim: { seen.insert($0).inserted },
          sink: { totals[$0.day, default: TokenTally()] += $0.tokens })
        : FileIngest.claude(
          pending, cursor: &cursor, calendar: utc, claim: { seen.insert($0).inserted },
          sink: { totals[$0.day, default: TokenTally()] += $0.tokens })
      pending = Data(pending.dropFirst(used))
    }
    return totals
  }

  static func sum(_ totals: [Int: TokenTally]) -> TokenTally {
    totals.values.reduce(TokenTally(), +)
  }

  static func usageIngest() {
    section("FileIngest")
    let opening =
      #"{"type":"user","cwd":"/work/armada","sessionId":"s1","timestamp":"2026-09-13T23:29:00.000Z"}"#
    let first = (0..<3).map { _ in claudeLine(id: "msg_a", at: "2026-09-13T23:30:00.000Z") }
    // The agent's shell `cd`s: later lines carry a subfolder, and the session still belongs
    // to the folder it started in.
    let second = (0..<3).map { _ in
      claudeLine(
        id: "msg_b", output: 70, at: "2026-09-14T00:30:00.000Z", cwd: "/work/armada/apps/apple")
    }
    let whole = ndjson([opening] + first + second)

    var seen: Set<UInt64> = []
    var cursor = IngestCursor()
    let once = ingest([whole], seen: &seen, cursor: &cursor)
    expectEqual(
      "each message counts once, on its own day", once,
      [
        20_260_913: TokenTally(fresh: 2, cacheWrite: 100, cacheRead: 1_000, output: 50),
        20_260_914: TokenTally(fresh: 2, cacheWrite: 100, cacheRead: 1_000, output: 70),
      ])
    expectEqual("the session belongs to the folder it started in", cursor.cwd, "/work/armada")
    expectEqual("the cursor ends after the last whole line", cursor.offset, Int64(whole.count))

    var splitsAgree = true
    for split in 1..<whole.count {
      var splitSeen: Set<UInt64> = []
      var splitCursor = IngestCursor()
      let parts = [Data(whole.prefix(split)), Data(whole.dropFirst(split))]
      if ingest(parts, seen: &splitSeen, cursor: &splitCursor) != once
        || splitCursor.offset != Int64(whole.count)
      {
        splitsAgree = false
      }
    }
    check("the same totals whichever byte a read stops at", splitsAgree)

    var partialSeen: Set<UInt64> = []
    var partialCursor = IngestCursor()
    _ = ingest(
      [whole + Data(claudeLine(id: "msg_c").utf8.prefix(40))], seen: &partialSeen,
      cursor: &partialCursor)
    expectEqual(
      "a line still being written is left for the next read", partialCursor.offset,
      Int64(whole.count))

    // A resumed or mirrored transcript copies msg_b under a new session id, then goes on.
    let mirror = ndjson(
      [#"{"type":"bridge-session","sessionId":"s2"}"#]
        + (0..<2).map { _ in
          claudeLine(id: "msg_b", output: 70, at: "2026-09-14T00:30:00.000Z", session: "s2")
        }
        + [claudeLine(id: "msg_d", output: 5, at: "2026-09-14T01:00:00.000Z", session: "s2")])
    func both(_ one: Data, _ two: Data) -> TokenTally {
      var shared: Set<UInt64> = []
      var oneCursor = IngestCursor()
      var twoCursor = IngestCursor()
      let a = ingest([one], seen: &shared, cursor: &oneCursor)
      let b = ingest([two], seen: &shared, cursor: &twoCursor)
      return sum(a) + sum(b)
    }
    let forward = both(whole, mirror)
    expectEqual("a message copied into a second transcript counts once", forward.output, 125)
    expectEqual("whichever transcript is read first", both(mirror, whole), forward)

    section("FileIngest, Codex")
    let meta =
      #"{"timestamp":"2026-09-14T09:00:00.000Z","type":"session_meta","payload":{"id":"p","cwd":"/work/armada"}}"#
    let turn =
      #"{"timestamp":"2026-09-14T09:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}"#
    let history = [(1_000, 800, 40), (2_500, 2_000, 90), (4_000, 3_500, 150), (6_000, 5_000, 200)]
      .enumerated().map { index, tuple in
        codexTokens(
          tuple.0, cached: tuple.1, output: tuple.2, at: "2026-09-14T09:0\(index + 1):00.000Z")
      }
    let parent = ndjson([meta, turn] + history)
    let forkMeta = meta.replacingOccurrences(
      of: #""id":"p""#, with: #""id":"f","forked_from_id":"p""#)
    let fork = ndjson(
      [forkMeta, turn] + history
        + [codexTokens(7_000, cached: 5_900, output: 260, at: "2026-09-14T10:00:00.000Z")])
    var codexSeen: Set<UInt64> = []
    var parentCursor = IngestCursor()
    var forkCursor = IngestCursor()
    let parentTotal = sum(ingest([parent], seen: &codexSeen, cursor: &parentCursor, codex: true))
    let forkTotal = sum(ingest([fork], seen: &codexSeen, cursor: &forkCursor, codex: true))
    expectEqual("a rollout adds up to its last cumulative total", parentTotal.total, 6_200)
    expectEqual(
      "a fork adds only what came after the history it replayed", forkTotal.total, 1_060)
    expectEqual("the folder comes from session_meta", forkCursor.cwd, "/work/armada")

    let falling = ndjson([
      meta, turn,
      codexTokens(1_000, cached: 0, output: 0, at: "2026-09-14T09:01:00.000Z"),
      codexTokens(500, cached: 0, output: 0, at: "2026-09-14T09:02:00.000Z"),
      codexTokens(800, cached: 0, output: 0, at: "2026-09-14T09:03:00.000Z"),
    ])
    var fallingSeen: Set<UInt64> = []
    var fallingCursor = IngestCursor()
    expectEqual(
      "a total that goes down restarts the count rather than subtracting",
      sum(ingest([falling], seen: &fallingSeen, cursor: &fallingCursor, codex: true)).total,
      1_300)

    let switched = ndjson([
      meta, turn,
      codexTokens(1_000, cached: 0, output: 0, at: "2026-09-14T09:01:00.000Z"),
      #"{"timestamp":"2026-09-14T09:01:30.000Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
      codexTokens(1_600, cached: 0, output: 0, at: "2026-09-14T09:02:00.000Z"),
    ])
    var modelSeen: Set<UInt64> = []
    var modelCursor = IngestCursor()
    var models: [String: Int] = [:]
    _ = FileIngest.codex(
      switched, cursor: &modelCursor, calendar: utc, claim: { modelSeen.insert($0).inserted },
      sink: { models[$0.model, default: 0] += $0.tokens.total })
    expectEqual(
      "each delta goes to the model of the turn it came from", models,
      ["gpt-5.4": 1_000, "gpt-5.4-mini": 600])
  }

  static func projectStats() {
    section("ProjectStats")
    func row(
      _ day: Int, _ cwd: String, _ model: String = "claude-opus-5", account: String = "/a",
      vendor: UsageVendor = .claude, output: Int
    ) -> UsageRow {
      UsageRow(
        day: day, cwd: cwd, account: account, vendor: vendor, model: model,
        tokens: TokenTally(output: output))
    }
    func session(
      _ id: String, _ cwd: String, lastAt: String, vendor: UsageVendor = .claude,
      isChild: Bool = false
    ) -> UsageSessionRow {
      UsageSessionRow(
        account: "/a", vendor: vendor, sessionID: id, cwd: cwd,
        firstAt: date(lastAt).addingTimeInterval(-600), lastAt: date(lastAt), isChild: isChild)
    }
    let ledger = UsageLedgerSnapshot(
      generation: 1,
      rows: [
        row(20_260_914, "/work/armada", output: 1),
        // Six days before today: the oldest day inside seven.
        row(20_260_908, "/work/armada/apps/apple", output: 10),
        row(20_260_907, "/work/armada", output: 100),
        row(
          20_260_801, "/work/armada", "gpt-5.4", account: "/codex", vendor: .codex, output: 1_000),
        row(20_260_914, "/work/armada/apps/website", output: 10_000),
        row(20_260_914, "/work/armada-old", output: 100_000),
      ],
      sessions: [
        session("s1", "/work/armada", lastAt: "2026-09-14T10:00:00Z"),
        session("s2", "/work/armada/apps/apple", lastAt: "2026-09-01T10:00:00Z"),
        session(
          "c1", "/work/armada", lastAt: "2026-09-14T09:00:00Z", vendor: .codex, isChild: true),
      ],
      earliestDay: 20_260_801, firstPassDone: true)
    let stats = ProjectStats.compute(
      projects: [
        ProjectPath.Candidate(id: "outer", keys: ["/work/armada"]),
        ProjectPath.Candidate(id: "inner", keys: ["/work/armada/apps/website"]),
      ],
      ledger: ledger, today: date("2026-09-14T12:00:00Z"), calendar: utc)
    expectEqual(
      "seven days counts today and the six before it", stats["outer"]?.tokens[.week]?.output, 11)
    expectEqual("thirty days", stats["outer"]?.tokens[.month]?.output, 111)
    expectEqual("all time", stats["outer"]?.tokens[.all]?.output, 1_111)
    expectEqual(
      "a nested project's tokens are its own, not its parent's",
      stats["inner"]?.tokens[.all]?.output, 10_000)
    check(
      "a sibling folder sharing the name as a prefix counts for neither",
      stats.values.allSatisfy { ($0.tokens[.all]?.output ?? 0) < 100_000 })
    expectEqual(
      "sessions in the window, subagents not counted", stats["outer"]?.sessions[.week], 1)
    expectEqual("sessions all time", stats["outer"]?.sessions[.all], 2)
    expectEqual(
      "last active is the newest session's", stats["outer"]?.lastActive,
      date("2026-09-14T10:00:00Z"))
    expectEqual(
      "split by model, largest first", stats["outer"]?.byModel.map(\.key),
      ["gpt-5.4", "claude-opus-5"])
    expectEqual(
      "and by folder, relative to the project", stats["outer"]?.byFolder.map(\.key).sorted(),
      ["", "apps/apple"])
  }

  // MARK: - LaunchScript

  static func launchScript() {
    section("LaunchScript")
    expectEqual(
      "a quote is closed, escaped and reopened", LaunchScript.quoted("it's"), #"'it'\''s'"#)
    expectEqual(
      "and nothing inside single quotes expands", LaunchScript.quoted("$HOME `x`"),
      "'$HOME `x`'")
    let prompt = LaunchScript.promptLines(file: "/tmp/a b/prompt.txt")
    expectEqual(
      "the message is read from its file, which is removed before the agent starts",
      prompt.setup, [#"prompt="$(<'/tmp/a b/prompt.txt')""#, #"rm -f '/tmp/a b/prompt.txt'"#])
    expectEqual(
      "and passed as one word the shell does not split or glob", prompt.argument, #""$prompt""#)
  }

  // MARK: - NewAccount

  static func newAccount() {
    section("NewAccount.check")
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let taken = "/Users/someone/.claude-work"
    func named(_ typed: String) -> NewAccount.Check {
      NewAccount.check(typed, for: .claude, home: home) {
        $0.path(percentEncoded: false) == taken + "/"
      }
    }
    expectEqual("nothing typed is not an error", named(""), .empty)
    expectEqual("nor is only whitespace", named("  "), .empty)
    expectEqual(
      "a plain name becomes a sibling folder", named("acme"), .ready(folderName: ".claude-acme"))
    expectEqual(
      "surrounding whitespace is dropped", named(" acme "), .ready(folderName: ".claude-acme"))
    expectEqual("the prefix is forgiven", named("claude-acme"), .ready(folderName: ".claude-acme"))
    expectEqual("with its dot too", named(".claude-acme"), .ready(folderName: ".claude-acme"))
    expectEqual(
      "dots, dashes and underscores inside", named("a.b-c_d"), .ready(folderName: ".claude-a.b-c_d")
    )
    check("the prefix alone is refused", isRefused(named("claude-")))
    check("an existing folder is refused", isRefused(named("work")))
    check("a leading dash is refused", isRefused(named("-rf")))
    check("a leading dot is refused", isRefused(named("..")))
    check("a slash is refused", isRefused(named("a/b")))
    check("a space inside is refused", isRefused(named("my work")))
    check("a quote is refused", isRefused(named("it's")))
    check("a non-ASCII letter is refused", isRefused(named("équipe")))
    check("a shell expansion is refused", isRefused(named("$HOME")))
    expectEqual(
      "forty characters are enough",
      named(String(repeating: "a", count: 40)),
      .ready(folderName: ".claude-" + String(repeating: "a", count: 40)))
    check("forty-one are not", isRefused(named(String(repeating: "a", count: 41))))
  }

  static func addedHomes() {
    section("NewAccount, other agents")
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    func named(_ typed: String, _ vendor: NewAccount.Vendor) -> NewAccount.Check {
      NewAccount.check(typed, for: vendor, home: home) { _ in false }
    }
    expectEqual("Codex gets its own stem", named("acme", .codex), .ready(folderName: ".codex-acme"))
    expectEqual(
      "and forgives its own prefix", named("codex-acme", .codex), .ready(folderName: ".codex-acme"))
    expectEqual("Grok Build likewise", named(".grok-acme", .grok), .ready(folderName: ".grok-acme"))
    expectEqual(
      "another agent's prefix is kept as part of the name", named("claude-acme", .codex),
      .ready(folderName: ".codex-claude-acme"))

    section("AddedHomes")
    let suite = "armada.unit-check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    AddedHomes.add("/h/.codex-a", for: .codex, in: defaults)
    AddedHomes.add("/h/.codex-a", for: .codex, in: defaults)
    AddedHomes.add("/h/.codex-b", for: .codex, in: defaults)
    expectEqual(
      "a home is remembered once, in order", AddedHomes.paths(for: .codex, in: defaults),
      ["/h/.codex-a", "/h/.codex-b"])
    expectEqual("and per agent", AddedHomes.paths(for: .grok, in: defaults), [])
    AddedHomes.remove("/h/.codex-a", for: .codex, in: defaults)
    expectEqual(
      "and forgotten on request", AddedHomes.paths(for: .codex, in: defaults), ["/h/.codex-b"])

    section("CodexHome.discoverAll, GrokHome.discoverAll with added homes")
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "armada-unit-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: root) }
    func make(_ relative: String) {
      let url = root.appending(path: relative)
      try? fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if relative.hasSuffix("/") {
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      } else {
        fileManager.createFile(atPath: url.path(percentEncoded: false), contents: Data("{}".utf8))
      }
    }
    make(".codex/sessions/")
    make(".codex-fresh/version.json")
    make(".codex-empty/")
    make(".codex-unlisted/sessions/")
    make(".grok-work/version.json")
    make(".grok-work/sessions/")
    make(".grok-other/user-settings.json")
    make(".grok-other/sessions/")
    func path(_ name: String) -> String { root.appending(path: name).path(percentEncoded: false) }
    let codex = CodexHome.discoverAll(
      environment: [:], home: root,
      added: [path(".codex-fresh"), path(".codex-empty"), path(".codex-missing")]
    ).map { URL(filePath: $0.path).lastPathComponent }
    expectEqual(
      "an added Codex home counts with version.json alone; nothing is found by its name",
      codex, [".codex", ".codex-fresh"])
    let grok = GrokHome.discoverAll(
      environment: [:], home: root, added: [path(".grok-work"), path(".grok-other")]
    ).map { URL(filePath: $0.path).lastPathComponent }
    expectEqual("an added Grok home still has to be xAI's", grok, [".grok-work"])
  }

  static func isRefused(_ check: NewAccount.Check) -> Bool {
    if case .refused = check { return true }
    return false
  }

  // MARK: - EditorLaunch

  static func editorLaunch() {
    section("EditorLaunch.shellEnvironment")
    let marker = EditorLaunch.environmentMarker
    var output = Data("Welcome back!\nPATH=/not/this\n\(marker)".utf8)
    output.append(Data("PATH=/opt/homebrew/bin:/usr/bin\0NOTE=two\nlines\0EQ=a=b\0".utf8))
    let shell = EditorLaunch.shellEnvironment(output)
    expectEqual(
      "what a profile prints before the marker is not read",
      shell?["PATH"], "/opt/homebrew/bin:/usr/bin")
    expectEqual("a value keeps its newline", shell?["NOTE"], "two\nlines")
    expectEqual("and an equals sign after the first", shell?["EQ"], "a=b")
    check(
      "no marker is no environment", EditorLaunch.shellEnvironment(Data("PATH=/x\0".utf8)) == nil)

    section("EditorLaunch.windowEnvironment")
    let base = [
      "PATH": "/opt/homebrew/bin", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "SHLVL": "2",
      "VSCODE_IPC_HOOK_CLI": "/tmp/x", "CLAUDECODE": "1", "HOME": "/Users/me",
    ]
    let custom = EditorLaunch.windowEnvironment(shell: base, configDirectory: "/Users/me/.claude-b")
    expectEqual(
      "another account's folder is stated", custom["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-b")
    expectEqual("the shell's PATH is kept", custom["PATH"], "/opt/homebrew/bin")
    check(
      "the shell's own and VS Code's variables are dropped",
      custom["SHLVL"] == nil && custom["VSCODE_IPC_HOOK_CLI"] == nil && custom["CLAUDECODE"] == nil)
    let standard = EditorLaunch.windowEnvironment(shell: base, configDirectory: nil)
    check(
      "the default folder unsets what a profile exported", standard["CLAUDE_CONFIG_DIR"] == nil)

    section("EditorLaunch.hostsAgree")
    check("no windows agree with anything", EditorLaunch.hostsAgree([], configDirectory: "/a"))
    check(
      "every default window agrees with the default",
      EditorLaunch.hostsAgree([nil, ""], configDirectory: nil))
    check(
      "a trailing slash is the same folder",
      EditorLaunch.hostsAgree(["/Users/me/.claude-b/"], configDirectory: "/Users/me/.claude-b"))
    check(
      "one window on another account is enough to refuse",
      !EditorLaunch.hostsAgree([nil, "/Users/me/.claude-b"], configDirectory: nil))
    check(
      "and a default window refuses a custom account",
      !EditorLaunch.hostsAgree([nil], configDirectory: "/Users/me/.claude-b"))

    section("EditorLaunch.windowAgrees")
    let silhouette = EditorLaunch.ExtensionHost(
      configDirectory: nil, folder: "/Users/me/Projects/silhouette")
    let contour = EditorLaunch.ExtensionHost(
      configDirectory: "/Users/me/.claude-b", folder: "/Users/me/Projects/contour")
    let untraced = EditorLaunch.ExtensionHost(configDirectory: "/Users/me/.claude-b", folder: nil)
    check(
      "another window's account does not matter once the project's is found",
      EditorLaunch.windowAgrees(
        [silhouette, contour, untraced], folder: "/Users/me/Projects/silhouette/",
        configDirectory: nil))
    check(
      "the project's own window on another account refuses",
      !EditorLaunch.windowAgrees(
        [silhouette, contour], folder: "/Users/me/Projects/contour", configDirectory: nil))
    check(
      "a window not found falls back to every host",
      !EditorLaunch.windowAgrees(
        [silhouette, untraced], folder: "/Users/me/Projects/armada", configDirectory: nil))
    check(
      "and every host agreeing is still enough",
      EditorLaunch.windowAgrees(
        [untraced], folder: "/Users/me/Projects/armada", configDirectory: "/Users/me/.claude-b/"))

    section("EditorLaunch.hostStorages")
    let exthostLog = """
      2026-09-15 10:53:06.335 [info] Extension host with pid 74130 started
      2026-09-15 10:53:06.335 [info] Skipping acquiring lock for /Users/me/Library/Application Support/Code/User/workspaceStorage/2a5aabf5f6b4d17ed931fec20b4c7124.
      2026-09-15 10:53:06.362 [info] ExtensionService#_doActivateExtension vscode.git, startup: true
      2026-09-15 15:09:17.809 [info] Extension host with pid 60747 started
      2026-09-15 15:09:17.809 [info] Skipping acquiring lock for /Users/me/Library/Application Support/Code/User/workspaceStorage/88d27e154ede36be86209016cf4fd2e2.
      2026-09-15 15:09:18.000 [info] something mentioning /User/workspaceStorage/ffff later
      2026-09-15 16:00:00.000 [info] Extension host with pid 61000 started
      """
    expectEqual(
      "each host of a reloaded window keeps its own storage, and only its first",
      EditorLaunch.hostStorages(log: exthostLog),
      [74130: "2a5aabf5f6b4d17ed931fec20b4c7124", 60747: "88d27e154ede36be86209016cf4fd2e2"])

    section("EditorLaunch.workspaceFolder")
    expectEqual(
      "a folder window's path, decoded",
      EditorLaunch.workspaceFolder(Data(#"{ "folder": "file:///Users/me/My%20App" }"#.utf8)),
      "/Users/me/My App")
    expectEqual(
      "a multi-root workspace is no folder",
      EditorLaunch.workspaceFolder(
        Data(#"{ "workspace": "file:///Users/me/a.code-workspace" }"#.utf8)), nil)

    section("EditorLaunch.settingsSetConfigDirectory")
    check(
      "the setting naming the folder is found",
      EditorLaunch.settingsSetConfigDirectory(
        #"{ "claudeCode.environmentVariables": [{ "name": "CLAUDE_CONFIG_DIR", "value": "/x" }] }"#)
    )
    check(
      "other variables in the setting are not",
      !EditorLaunch.settingsSetConfigDirectory(
        #"{ "claudeCode.environmentVariables": [{ "name": "DEBUG", "value": "1" }] }"#))

    section("EditorLaunch.openURL")
    expectEqual(
      "a fresh tab carries no session",
      EditorLaunch.openURL(scheme: "vscode", prompt: nil)?.absoluteString,
      "vscode://anthropic.claude-code/open")
    expectEqual(
      "and the message is encoded",
      EditorLaunch.openURL(scheme: "vscode", prompt: "fix a&b #1")?.absoluteString,
      "vscode://anthropic.claude-code/open?prompt=fix%20a%26b%20%231")
    check(
      "the input holds the message, line breaks read back as spaces",
      EditorLaunch.inputHolds("fix the\u{a0}build  now", prompt: "fix the build\nnow"))
    check(
      "not a placeholder, a longer message or nothing",
      !EditorLaunch.inputHolds("⌘ Esc to focus or unfocus Claude", prompt: "fix")
        && !EditorLaunch.inputHolds("fix it", prompt: "fix")
        && !EditorLaunch.inputHolds(nil, prompt: "fix")
        && !EditorLaunch.inputHolds("", prompt: " "))
    check(
      "extension folders of any version",
      EditorLaunch.isClaudeExtension("anthropic.claude-code-2.1.273-darwin-arm64")
        && !EditorLaunch.isClaudeExtension("anthropic.claude-codex-1.0"))

    section("EditorLaunch.processArguments")
    var bytes: [UInt8] = []
    withUnsafeBytes(of: Int32(2)) { bytes += $0 }
    bytes += Array("/Applications/Code Helper\0\0\0".utf8)
    bytes += Array(
      "helper\0--type=utility\0A=1\0VSCODE_CRASH_REPORTER_PROCESS_TYPE=extensionHost\0\0junk\0".utf8
    )
    let parsed = EditorLaunch.processArguments(bytes)
    expectEqual(
      "the arguments, without the executable path", parsed?.arguments, ["helper", "--type=utility"])
    expectEqual(
      "the environment after them", parsed?.environment["VSCODE_CRASH_REPORTER_PROCESS_TYPE"],
      "extensionHost")
    check("and nothing past its end", parsed?.environment.count == 2)
    check("too short to hold a count", EditorLaunch.processArguments([1, 0]) == nil)
  }

  // MARK: - MessageHook

  /// The button-combo state machine: what is held back, what fires, what the
  /// application still gets. Every rule here costs a real Back press something, so
  /// each one is pinned rather than left to the tap to demonstrate by hand.
  static func mouseChord() {
    section("MouseChord: holds, combos and what reaches the app")

    let back = 3
    let forward = 4
    let together = MouseBinding(
      modifiers: .none, button: MouseBinding.backAndForward, action: .focusNextWaiting)
    let ordered = MouseBinding(
      modifiers: .none, button: MouseBinding.backThenForward, action: .focusNextSession)
    let single = MouseBinding(modifiers: .option, button: back, action: .showArmada)
    let optionTogether = MouseBinding(
      modifiers: .option, button: MouseBinding.backAndForward, action: .showArmada)
    let none: CGEventFlags = []
    let option: CGEventFlags = [.maskAlternate]

    func chord(_ bindings: [MouseBinding]) -> MouseChord { MouseChord(bindings: bindings) }

    // Nothing to claim the press: today's behaviour, and the one that must not change
    // for a Mac with no combo bound.
    var plain = chord([single])
    expectEqual(
      "an unbound press passes at once", plain.press(button: back, flags: none, at: 0),
      MouseChord.Decision(action: .pass))
    expectEqual(
      "a single binding still fires", plain.press(button: back, flags: option, at: 1),
      MouseChord.Decision(action: .fire(single)))

    // A combo can claim it, so it waits.
    var both = chord([together, ordered])
    expectEqual(
      "a press a combo could claim is held", both.press(button: back, flags: none, at: 0),
      MouseChord.Decision(action: .hold(token: 1)))
    expectEqual(
      "the other button inside the window is the together combo",
      both.press(button: forward, flags: none, at: 0.05),
      MouseChord.Decision(action: .fire(together)))

    var late = chord([together, ordered])
    _ = late.press(button: back, flags: none, at: 0)
    expectEqual(
      "after the window, with the button still down, it is the ordered combo",
      late.press(button: forward, flags: none, at: 0.3),
      MouseChord.Decision(action: .fire(ordered)))
    expectEqual(
      "and it fires again on each further press",
      late.press(button: forward, flags: none, at: 0.9),
      MouseChord.Decision(action: .fire(ordered)))
    expectEqual(
      "releasing the anchor is swallowed, not replayed",
      late.release(button: back, flags: none, at: 1.0),
      MouseChord.Decision(action: .swallow))
    expectEqual(
      "and the run is over: the next press is held again",
      late.press(button: back, flags: none, at: 1.1),
      MouseChord.Decision(action: .hold(token: 2)))

    // A click shorter than the window. The application gets its Back, late.
    var quick = chord([together, ordered])
    _ = quick.press(button: back, flags: none, at: 0)
    expectEqual(
      "a click inside the window settles as a replay on release",
      quick.release(button: back, flags: none, at: 0.02),
      MouseChord.Decision(settled: .replay, action: .swallow))

    // No ordered combo starts with this button, so there is nothing left to wait for.
    var togetherOnly = chord([together])
    _ = togetherOnly.press(button: back, flags: none, at: 0)
    expectEqual(
      "the window expiring settles a together-only hold",
      togetherOnly.windowExpired(token: 1), MouseChord.Decision(settled: .replay))
    expectEqual(
      "an ordered hold outlives the window",
      chordAfterWindow(bindings: [together, ordered], button: back),
      MouseChord.Decision())

    // A hold that settles into the button's own binding rather than a replay.
    var withSingle = chord([optionTogether, single])
    _ = withSingle.press(button: back, flags: option, at: 0)
    expectEqual(
      "a hold whose button has a single binding settles into it, not a replay",
      withSingle.windowExpired(token: 1), MouseChord.Decision(settled: .fire(single)))

    // Modifiers gate the wait, or a ⌥ combo would delay every bare Back on the Mac.
    var modified = chord([optionTogether])
    expectEqual(
      "a combo bound to a modifier never holds a bare press",
      modified.press(button: back, flags: none, at: 0), MouseChord.Decision(action: .pass))

    // A release macOS hid: the stale hold is settled by that button's next press.
    var stale = chord([together, ordered])
    _ = stale.press(button: back, flags: none, at: 0)
    expectEqual(
      "a second press of a held button settles the first",
      stale.press(button: back, flags: none, at: 5),
      MouseChord.Decision(settled: .replay, action: .hold(token: 2)))

    // An unrelated button while a press is held: the held one settles, the new one is
    // not the tap's business.
    var other = chord([together, ordered])
    _ = other.press(button: back, flags: none, at: 0)
    expectEqual(
      "an unrelated press settles the held one and passes",
      other.press(button: 2, flags: none, at: 0.01),
      MouseChord.Decision(settled: .replay, action: .pass))

    // Switching the feature off, or macOS disabling the tap, mid-hold.
    var reset = chord([together, ordered])
    _ = reset.press(button: back, flags: none, at: 0)
    expectEqual("a reset settles what was held", reset.reset(), MouseChord.Settled.replay)
    expectEqual("and leaves nothing behind", reset.reset(), nil)

    // A press another application posted — Cadence's replay of a press it held. Holding
    // it again is what made the two apps bounce one press between them for ever,
    // pinning the pointer to where it was clicked.
    var posted = chord([together, ordered])
    expectEqual(
      "a posted press is never held, even when a combo could claim it",
      posted.press(button: back, flags: none, at: 0, posted: true),
      MouseChord.Decision(action: .pass))
    var postedSingle = chord([single, optionTogether])
    expectEqual(
      "a posted press still fires a single binding",
      postedSingle.press(button: back, flags: option, at: 0, posted: true),
      MouseChord.Decision(action: .fire(single)))
    var postedSecond = chord([together, ordered])
    _ = postedSecond.press(button: back, flags: none, at: 0)
    expectEqual(
      "a posted press of the other button completes no combo",
      postedSecond.press(button: forward, flags: none, at: 0.3, posted: true),
      MouseChord.Decision(settled: .replay, action: .pass))

    var postedMidRun = chord([together, ordered])
    _ = postedMidRun.press(button: back, flags: none, at: 0)
    _ = postedMidRun.press(button: forward, flags: none, at: 0.3)
    _ = postedMidRun.press(button: forward, flags: none, at: 0.5, posted: true)
    expectEqual(
      "a posted press does not end a run, so the anchor's release is still swallowed",
      postedMidRun.release(button: back, flags: none, at: 0.6),
      MouseChord.Decision(action: .swallow))

    // A real F-key carries fn, and a Carbon hot key — Cadence's dictation shortcut —
    // ignores one that does not, so a posted F17 without it reaches the front app
    // as an unhandled key instead: a beep.
    let sending = MouseBinding(modifiers: .option, button: back, action: .f17)
    expectEqual(
      "a sent F-key carries fn alongside the modifiers it is sent with",
      sending.keystrokeFlags, [.maskAlternate, .maskSecondaryFn])
    var bare = sending
    bare.sentModifiers = MouseModifiers.none
    expectEqual(
      "and carries fn when sent with no modifier", bare.keystrokeFlags, [.maskSecondaryFn])

    // A stale timer, from a hold that has already been settled some other way.
    var stopped = chord([together, ordered])
    _ = stopped.press(button: back, flags: none, at: 0)
    _ = stopped.release(button: back, flags: none, at: 0.01)
    expectEqual(
      "a timer for a settled hold does nothing", stopped.windowExpired(token: 1),
      MouseChord.Decision())
  }

  /// What a "Send a key" binding actually sends: the modifier you hold, or one chosen
  /// for it. The row names the chord to bind in the other app, so the two must agree.
  static func mouseSentKey() {
    section("MouseBinding: the modifier a key is sent with")

    var binding = MouseBinding(
      modifiers: .option, button: MouseBinding.backThenForward, action: .f16)
    expectEqual("as held by default", binding.sentModifiers, nil)
    expectEqual("as held sends the trigger's own", binding.sentFlags, [.maskAlternate])
    expectEqual("and the row says so", binding.actionLabel, "Send ⌥F16")

    binding.sentModifiers = .command
    expectEqual("a chosen modifier replaces the held one", binding.sentFlags, [.maskCommand])
    expectEqual("and the row names it", binding.actionLabel, "Send ⌘F16")

    binding.sentModifiers = MouseModifiers.none
    expectEqual("no modifier sends the bare key", binding.sentFlags, [])
    expectEqual("and the row reads bare", binding.actionLabel, "Send F16")

    binding.action = .focusNextSession
    expectEqual(
      "Armada's own commands ignore it", binding.actionLabel, "Focus next session")

    // A list saved before the field existed.
    let old =
      #"[{"id":"4825754D-7A60-4B85-8C5A-86358BE49C9D","modifiers":"none","button":-2,"action":"f15"}]"#
    let decoded = try? JSONDecoder().decode([MouseBinding].self, from: Data(old.utf8))
    expectEqual("a binding saved before this decodes", decoded?.count, 1)
    expectEqual("and sends as held", decoded?.first?.sentModifiers, nil)
  }

  /// The modifiers Armada holds down while a trigger is held. VS Code's window picker
  /// opens on ⌘F15 and picks when ⌘ comes *up*, so a ⌘ that only ever rode along as
  /// a flag left the picker open for good; these pin the key-down, the key-up, and
  /// that nothing is left down.
  static func modifierHold() {
    section("ModifierHold: the modifier a sent key is held with")
    let command: CGEventFlags = [.maskCommand]
    let back = 3
    let forward = 4

    var hold = ModifierHold()
    expectEqual(
      "the first fire presses the modifier the hand is not holding",
      hold.fire(sent: command, physical: [], releasedBy: [back]),
      [ModifierHold.Event(key: 0x37, down: true, flags: command)])
    expectEqual(
      "a repeat inside the run presses nothing more",
      hold.fire(sent: command, physical: [], releasedBy: [back]), [])
    expectEqual(
      "releasing the other button lets nothing go", hold.release(button: forward), [])
    expectEqual(
      "releasing the held button lets it go, and that is what picks the window",
      hold.release(button: back), [ModifierHold.Event(key: 0x37, down: false, flags: [])])
    expectEqual("and nothing is left down", hold.reset(), [])

    var asHeld = ModifierHold()
    expectEqual(
      "a modifier the hand is already holding is never pressed again",
      asHeld.fire(sent: command, physical: command, releasedBy: [back]), [])

    var bare = ModifierHold()
    expectEqual(
      "a key sent bare presses nothing", bare.fire(sent: [], physical: [], releasedBy: [back]), [])

    var pair = ModifierHold()
    expectEqual(
      "a pair goes down in order, each carrying what is down so far",
      pair.fire(sent: [.maskCommand, .maskShift], physical: [], releasedBy: [back]),
      [
        ModifierHold.Event(key: 0x38, down: true, flags: [.maskShift]),
        ModifierHold.Event(key: 0x37, down: true, flags: [.maskShift, .maskCommand]),
      ])
    expectEqual(
      "and comes up in reverse",
      pair.reset(),
      [
        ModifierHold.Event(key: 0x37, down: false, flags: [.maskShift]),
        ModifierHold.Event(key: 0x38, down: false, flags: []),
      ])

    var changed = ModifierHold()
    _ = changed.fire(sent: command, physical: [], releasedBy: [back])
    expectEqual(
      "a fire with a different modifier lets the old one go first",
      changed.fire(sent: [.maskAlternate], physical: [], releasedBy: [back]),
      [
        ModifierHold.Event(key: 0x37, down: false, flags: []),
        ModifierHold.Event(key: 0x3A, down: true, flags: [.maskAlternate]),
      ])

    var stopped = ModifierHold()
    _ = stopped.fire(sent: command, physical: [], releasedBy: [back])
    expectEqual(
      "a reset — the tap stopping — lets go of everything",
      stopped.reset(), [ModifierHold.Event(key: 0x37, down: false, flags: [])])
  }

  /// A hold that has outlived its window, for a check that only cares that the
  /// expiry did nothing.
  static func chordAfterWindow(bindings: [MouseBinding], button: Int) -> MouseChord.Decision {
    var chord = MouseChord(bindings: bindings)
    _ = chord.press(button: button, flags: [], at: 0)
    return chord.windowExpired(token: 1)
  }
  static func messageHook() {
    section("MessageHook: the settings edit")
    let script = "/Users/me/Library/Application Support/io.mgcrea.armada/hooks/deliver-message.zsh"
    let command = MessageHook.command(script: script, inbox: "/Users/me/inbox")
    func parsed(_ edit: MessageHook.Edit) -> [String: Any]? {
      guard case .edited(let data) = edit else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func stop(_ root: [String: Any]?) -> [[String: Any]]? {
      (root?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
    }
    func commands(_ group: [String: Any]?) -> [String] {
      (group?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }
    func text(_ edit: MessageHook.Edit) -> String? {
      if case .edited(let data) = edit { return String(decoding: data, as: UTF8.self) }
      return nil
    }
    func refused(_ edit: MessageHook.Edit) -> Bool {
      if case .refused = edit { return true }
      return false
    }

    let fresh = MessageHook.installing(nil, command: command, script: script)
    check(
      "a missing file becomes one Stop entry", commands(stop(parsed(fresh))?.first) == [command])
    let entry = (stop(parsed(fresh))?.first?["hooks"] as? [[String: Any]])?.first
    check(
      "the entry is an asyncRewake command with the long timeout",
      entry?["asyncRewake"] as? Bool == true
        && entry?["timeout"] as? Int == MessageHook.timeoutSeconds
        && entry?["type"] as? String == "command")

    let busy = #"""
      {
        "effortLevel": "high",
        "cost": 0.30000000000000004,
        "hooks": {
          "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard"}]}],
          "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
        }
      }
      """#
    let added = MessageHook.installing(Data(busy.utf8), command: command, script: script)
    check(
      "ours goes first in Stop, and the person's Stop and PreToolUse hooks stay",
      commands(stop(parsed(added))?.first) == [command]
        && commands(stop(parsed(added))?.last) == ["say done"]
        && ((parsed(added)?["hooks"] as? [String: Any])?["PreToolUse"] as? [Any])?.count == 1)
    check(
      "a float JSONSerialization cannot write back is left as it was",
      text(added)?.contains("0.30000000000000004") == true)

    let addedData = Data((text(added) ?? "").utf8)
    expectEqual(
      "installing again changes nothing",
      MessageHook.installing(addedData, command: command, script: script), .unchanged)
    expectEqual(
      "removing it gives back the original bytes",
      text(MessageHook.removing(addedData, script: script)), busy)

    let pretty = "{\n  \"effortLevel\": \"high\",\n  \"env\": {}\n}\n"
    let prettyAdded = MessageHook.installing(Data(pretty.utf8), command: command, script: script)
    check(
      "into a file laid out one member per line, hooks gets a line of its own",
      text(prettyAdded)?.hasPrefix("{\n  \"hooks\": ") == true
        && text(prettyAdded)?.contains("},\n  \"effortLevel\"") == true)
    expectEqual(
      "and removing it gives back the original bytes",
      text(MessageHook.removing(Data((text(prettyAdded) ?? "").utf8), script: script)), pretty)

    let freshData = Data((text(fresh) ?? "").utf8)
    check(
      "removing the only hook takes hooks with it",
      parsed(MessageHook.removing(freshData, script: script)).map { $0.isEmpty } == true)

    let onlyStop = #"{"env": {"A": "1"}, "hooks": {"Stop": []}}"#
    let intoEmpty = MessageHook.installing(Data(onlyStop.utf8), command: command, script: script)
    check(
      "an empty Stop list takes the entry", commands(stop(parsed(intoEmpty))?.first) == [command])

    let old = MessageHook.command(script: script, inbox: "/Users/me/old-inbox")
    let outdated = MessageHook.installing(
      Data((text(MessageHook.installing(nil, command: old, script: script)) ?? "").utf8),
      command: command, script: script)
    check(
      "an older command for the same script is replaced, not doubled",
      stop(parsed(outdated))?.count == 1 && commands(stop(parsed(outdated))?.first) == [command])

    let shared =
      #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}, "#
      + #"{"type": "command", "command": "f='\#(script)'; exit 0"}]}]}}"#
    let unshared = MessageHook.removing(Data(shared.utf8), script: script)
    check(
      "a handler sharing a group with the person's is removed alone",
      commands(stop(parsed(unshared))?.first) == ["say done"])

    check(
      "settings that are not an object are refused",
      refused(MessageHook.installing(Data("[1]".utf8), command: command, script: script))
        && refused(
          MessageHook.installing(Data(#"{"hooks": 3}"#.utf8), command: command, script: script))
    )
    check(
      "isInstalled sees exactly this command",
      MessageHook.isInstalled(addedData, command: command)
        && !MessageHook.isInstalled(addedData, command: old))

    section("MessageHook: the script")
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory.appending(
      path: "armada-hook-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }
    let scriptURL = scratch.appending(path: MessageHook.scriptName)
    let inbox = scratch.appending(path: "inbox", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
    try? Data(MessageHook.script.utf8).write(to: scriptURL)

    let syntax = Process()
    syntax.executableURL = URL(filePath: "/bin/zsh")
    syntax.arguments = ["-n", scriptURL.path(percentEncoded: false)]
    try? syntax.run()
    syntax.waitUntilExit()
    expectEqual("the script parses", syntax.terminationStatus, 0)

    let session = "11111111-2222-4333-8444-555555555555"
    func run(_ hookInput: String, deliver message: String?, after: TimeInterval = 0.4) -> (
      status: Int32, stderr: String
    ) {
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = [
        "-c",
        MessageHook.command(
          script: scriptURL.path(percentEncoded: false), inbox: inbox.path(percentEncoded: false)),
      ]
      let input = Pipe()
      let errors = Pipe()
      process.standardInput = input
      process.standardError = errors
      try? process.run()
      input.fileHandleForWriting.write(Data(hookInput.utf8))
      try? input.fileHandleForWriting.close()
      Thread.sleep(forTimeInterval: after)
      if let message {
        let file = inbox.appending(path: session).appending(path: "0001-test.msg")
        try? Data(message.utf8).write(to: file)
      }
      let deadline = Date().addingTimeInterval(5)
      while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      let text = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
      return (process.isRunning ? -1 : process.terminationStatus, text)
    }
    let delivered = run(
      #"{"session_id":"\#(session.uppercased())","hook_event_name":"Stop"}"#,
      deliver: "run the tests")
    check(
      "a message for this session is printed and exits 2",
      delivered.status == 2 && delivered.stderr.contains("run the tests"))
    check(
      "the message is gone once delivered",
      (try? fileManager.contentsOfDirectory(
        atPath: inbox.appending(path: session).path(percentEncoded: false)))?
        .contains { $0.hasSuffix(".msg") || $0.contains(".msg.") } == false)
    let noSession = run(#"{"hook_event_name":"Stop"}"#, deliver: nil, after: 0)
    expectEqual("input with no session id exits 0 at once", noSession.status, 0)
    let grok = run(
      #"{"hookEventName":"stop","sessionId":"\#(session)","hook_event_name":"Stop","session_id":"\#(session)"}"#,
      deliver: nil, after: 0)
    expectEqual("Grok Build's input, which also has session_id, exits 0 at once", grok.status, 0)

    let missing = Process()
    missing.executableURL = URL(filePath: "/bin/sh")
    missing.arguments = [
      "-c", MessageHook.command(script: "/nonexistent/deliver.zsh", inbox: "/tmp"),
    ]
    try? missing.run()
    missing.waitUntilExit()
    expectEqual("a missing script exits 0, which Claude Code ignores", missing.terminationStatus, 0)
  }

  // MARK: - ClaudeTrust

  static func claudeTrust() {
    section("ClaudeTrust.trusting")
    func edit(_ json: String, _ folder: String = "/work/armada") -> ClaudeTrust.Edit {
      ClaudeTrust.trusting(Data(json.utf8), folder: folder)
    }
    func text(_ edit: ClaudeTrust.Edit) -> String? {
      if case .edited(let data) = edit { return String(decoding: data, as: UTF8.self) }
      return nil
    }
    func root(_ edit: ClaudeTrust.Edit) -> [String: Any]? {
      guard case .edited(let data) = edit else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func entry(_ edit: ClaudeTrust.Edit, _ folder: String = "/work/armada") -> [String: Any]? {
      (root(edit)?["projects"] as? [String: Any])?[folder] as? [String: Any]
    }
    func trusted(_ edit: ClaudeTrust.Edit, _ folder: String = "/work/armada") -> Bool {
      entry(edit, folder)?["hasTrustDialogAccepted"] as? Bool == true
    }
    func refused(_ edit: ClaudeTrust.Edit) -> Bool {
      if case .refused = edit { return true }
      return false
    }

    // Floats JSONSerialization does not write back as they were, a brace and the field's own
    // name inside a string, and a sibling whose name starts the same.
    let template = #"""
      {
        "lastCost": 0.30000000000000004,
        "note": "a } and \"hasTrustDialogAccepted\": false, in a string",
        "projects": {
          "/work/armada-old": {
            "hasTrustDialogAccepted": false
          },
          "/work/armada": {
            "allowedTools": [],
            "hasTrustDialogAccepted": FLAG,
            "costUSD": 1.2345678901234567
          }
        }
      }
      """#
    let untrusted = template.replacingOccurrences(of: "FLAG", with: "false")
    let expected = template.replacingOccurrences(of: "FLAG", with: "true")
    expectEqual(
      "an untrusted entry has its false made true, and no other byte moves",
      text(edit(untrusted)), expected)
    expectEqual("a trusted entry is left alone", edit(expected), .alreadyTrusted)
    check(
      "a sibling whose name starts the same is not the one trusted",
      entry(edit(untrusted), "/work/armada-old")?["hasTrustDialogAccepted"] as? Bool == false)

    let partial = edit(#"{"projects": {"/work/armada": {"allowedTools": ["Bash(ls)"]}}}"#)
    check(
      "an entry without the field gains it and keeps what it had",
      trusted(partial) && entry(partial)?["allowedTools"] as? [String] == ["Bash(ls)"])

    let missing = edit(#"{"projects": {"/elsewhere": {"hasTrustDialogAccepted": true}}}"#)
    check(
      "a missing entry is written whole, as Claude Code writes one",
      trusted(missing) && entry(missing)?["allowedTools"] as? [String] == []
        && entry(missing)?["mcpServers"] as? [String: Any] != nil
        && entry(missing)?["hasClaudeMdExternalIncludesApproved"] as? Bool == false)
    check("beside the entries already there", trusted(missing, "/elsewhere"))
    check("into an empty projects", trusted(edit(#"{"projects": {}}"#)))

    let signedIn = edit(#"{"oauthAccount": {"emailAddress": "someone@example.com"}, "n": 1}"#)
    check(
      "projects is added when the file has none, and the sign-in stays",
      trusted(signedIn)
        && (root(signedIn)?["oauthAccount"] as? [String: String])?["emailAddress"]
          == "someone@example.com"
    )
    check("an empty object gains projects", trusted(edit("{}")))

    let escaped = #"{"projects": {"\/work\/café": {"hasTrustDialogAccepted": true}}}"#
    expectEqual(
      "a key is compared decoded, escapes and all", edit(escaped, "/work/caf\u{E9}"),
      .alreadyTrusted)
    check(
      "but scalar for scalar, as JavaScript compares it: a decomposed é is another folder",
      edit(escaped, "/work/cafe\u{301}") != .alreadyTrusted)
    check(
      "a folder with a quote in its name is written as a JSON string",
      trusted(edit("{}", #"/work/a"b"#), #"/work/a"b"#))

    check("an array is refused", refused(edit("[]")))
    check("projects that is not an object is refused", refused(edit(#"{"projects": []}"#)))
    check(
      "an entry that is not an object is refused",
      refused(edit(#"{"projects": {"/work/armada": true}}"#)))
    check("a truncated file is refused", refused(edit(#"{"projects": {"#)))
    check("anything after the object is refused", refused(edit("{} {}")))

    section("ClaudeTrust.ensure")
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appending(
      path: "armada-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
    let project = directory.appending(path: "armada", directoryHint: .isDirectory)
    let link = directory.appending(path: "link", directoryHint: .notDirectory)
    try! fileManager.createDirectory(at: project, withIntermediateDirectories: true)
    try! fileManager.createSymbolicLink(at: link, withDestinationURL: project)
    defer { try? fileManager.removeItem(at: directory) }
    let projectPath = project.path(percentEncoded: false)
    let key = ClaudeTrust.key(for: projectPath)

    expectEqual(
      "a folder is keyed by its resolved path",
      ClaudeTrust.key(for: link.path(percentEncoded: false)), key)
    expectEqual("with no trailing slash", ClaudeTrust.key(for: projectPath + "/"), key)

    func skipped(_ outcome: ClaudeTrust.Outcome) -> Bool {
      if case .skipped = outcome { return true }
      return false
    }
    func contents(_ url: URL) -> String {
      (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    func mode(_ url: URL) -> Int? {
      (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)))?[
        .posixPermissions]
        as? Int
    }

    let config = directory.appending(path: ".claude.json", directoryHint: .notDirectory)
    check(
      "a missing file is skipped",
      skipped(ClaudeTrust.ensure(folder: projectPath, configFile: config)))
    check("and not created", !fileManager.fileExists(atPath: config.path(percentEncoded: false)))

    let original = #"{"oauthAccount": {"emailAddress": "someone@example.com"}, "projects": {}}"#
    fileManager.createFile(
      atPath: config.path(percentEncoded: false), contents: Data(original.utf8),
      attributes: [.posixPermissions: 0o600])
    let lock = config.path(percentEncoded: false) + ".lock"
    mkdir(lock, 0o755)
    check(
      "a held lock is waited on briefly, then skipped",
      skipped(
        ClaudeTrust.ensure(folder: projectPath, configFile: config, lockBudget: .milliseconds(60))))
    expectEqual("without touching the file", contents(config), original)
    check("or the lock", fileManager.fileExists(atPath: lock))
    rmdir(lock)

    expectEqual(
      "a free lock and an untrusted folder is written",
      ClaudeTrust.ensure(folder: link.path(percentEncoded: false), configFile: config), .trusted)
    check(
      "under the resolved folder",
      trusted(.edited(Data(contents(config).utf8)), key))
    expectEqual("keeping the file's permissions", mode(config), 0o600)
    check("and releasing the lock", !fileManager.fileExists(atPath: lock))
    expectEqual(
      "a second launch finds it trusted",
      ClaudeTrust.ensure(folder: projectPath, configFile: config), .alreadyTrusted)

    let real = directory.appending(path: "dotfiles-claude.json", directoryHint: .notDirectory)
    let symlinked = directory.appending(path: "symlinked.json", directoryHint: .notDirectory)
    fileManager.createFile(atPath: real.path(percentEncoded: false), contents: Data("{}".utf8))
    try! fileManager.createSymbolicLink(at: symlinked, withDestinationURL: real)
    expectEqual(
      "a symlinked file is written through",
      ClaudeTrust.ensure(folder: projectPath, configFile: symlinked), .trusted)
    check(
      "and stays a symlink",
      (try? fileManager.destinationOfSymbolicLink(atPath: symlinked.path(percentEncoded: false)))
        != nil && trusted(.edited(Data(contents(real).utf8)), key))
    let leftovers =
      ((try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []).filter { $0.hasSuffix(".tmp") }
    expectEqual("no temporary file is left behind", leftovers, [])
  }

  // MARK: - LicenseKey

  static func licenseKey() {
    section("LicenseKey.check")
    let signing = Curve25519.Signing.PrivateKey()
    let trusted = base64Url(signing.publicKey.rawRepresentation)

    func mint(
      _ claims: String, prefix: String = "arm1", by key: Curve25519.Signing.PrivateKey? = nil
    ) -> String {
      let payload = base64Url(Data(claims.utf8))
      let signature = try! (key ?? signing).signature(for: Data(payload.utf8))
      return "\(prefix).\(payload).\(base64Url(signature))"
    }
    func refusal(
      _ key: String?, major: Int = 1, revoked: Set<String> = [], publicKey: String? = nil
    ) -> String? {
      let result = LicenseKey.check(
        key, major: major, revoked: revoked, publicKey: publicKey ?? trusted)
      if case .refused(let reason) = result { return reason }
      return nil
    }

    let claims =
      #"{"id":"lic_test","email":"someone@example.com","major":1,"issuedAt":"2026-09-14T09:00:00Z"}"#
    let good = mint(claims)
    let parts = good.split(separator: ".").map(String.init)

    expectEqual(
      "a key signed by the trusted key is valid",
      LicenseKey.check(good, major: 1, revoked: [], publicKey: trusted).license?.email,
      "someone@example.com")
    expectEqual("surrounding whitespace is forgiven", refusal("  \n\(good)\n"), nil as String?)
    expectEqual("no key", refusal(nil), "no licence key")
    expectEqual("a blank key", refusal("  \n"), "no licence key")
    expectEqual("two parts", refusal("arm1.onlytwo"), "expected three dot-separated parts")
    expectEqual(
      "a bad prefix is named", refusal(mint(claims, prefix: "arm2")), "unknown key format 'arm2'")
    expectEqual("an empty payload", refusal("arm1..\(parts[2])"), "empty payload or signature")
    expectEqual(
      "not base64url", refusal("arm1.***.***"), "payload or signature is not base64url")

    let forged = claims.replacingOccurrences(of: "someone@", with: "anyone@")
    expectEqual(
      "a tampered payload",
      refusal("arm1.\(base64Url(Data(forged.utf8))).\(parts[2])"), "signature does not match")
    var flipped = base64UrlDecode(parts[2])!
    flipped[0] ^= 0x01
    expectEqual(
      "a tampered signature",
      refusal("arm1.\(parts[1]).\(base64Url(flipped))"), "signature does not match")
    expectEqual(
      "a key signed by some other key",
      refusal(mint(claims, by: Curve25519.Signing.PrivateKey())), "signature does not match")
    expectEqual(
      "an unsigned payload that is not even JSON is refused on its signature, before any parse",
      refusal("arm1.\(base64Url(Data("not json".utf8))).\(base64Url(Data(count: 64)))"),
      "signature does not match")
    expectEqual(
      "a correctly signed payload that is not a licence",
      refusal(mint(#"{"hello":"world"}"#)), "payload is not a licence")
    expectEqual(
      "a revoked licence", refusal(good, revoked: ["lic_test"]), "licence lic_test was revoked")
    expectEqual(
      "a forgery naming a revoked id is refused on its signature",
      refusal("arm1.\(base64Url(Data(forged.utf8))).\(parts[2])", revoked: ["lic_test"]),
      "signature does not match")
    expectEqual(
      "the wrong major", refusal(good, major: 2), "key covers 1.x, this build is 2.x")
    expectEqual(
      "a build with no key compiled in", refusal(good, publicKey: ""),
      "this build has no signing key compiled in")
    expectEqual(
      "the key compiled into Armada parses, and did not sign this one",
      { () -> String? in
        if case .refused(let reason) = LicenseKey.check(good, major: 1, revoked: []) {
          return reason
        }
        return nil
      }(), "signature does not match")
  }

  static func base64Url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func base64UrlDecode(_ text: String) -> Data? {
    var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    while padded.count % 4 != 0 { padded.append("=") }
    return Data(base64Encoded: padded)
  }
}

/// The smallest session the list can sort: every key settable, nothing observed.
nonisolated struct FakeItem: SessionListItem {
  let id: String
  var displayName = "session"
  var projectName = "armada"
  var projectPath = "/work/armada"
  var startedAt: Date?
  var lastActivity: Date?
  var stateKey = "idle"
  var stateLabel = "Idle"
  var stateRank = 3
  var contextTokens: Int?
}

/// A seeded generator, so a failing shuffle fails the same way on the next run.
nonisolated struct SplitMix: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
