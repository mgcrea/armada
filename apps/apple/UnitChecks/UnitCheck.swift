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
    transcriptQuota()
    contextWindow()
    usageForecast()
    dayWeights()
    sessionOrder()
    changelog()
    hostWindow()
    codexRollout()
    licenseKey()

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
        weights: .even, asOf: asOf.map(date), now: date(now), calendar: utc)
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
    check(
      "under a tenth of the window elapsed",
      fiveHour(5, asOf: "2026-09-14T10:20:00Z", now: "2026-09-14T10:20:00Z") == nil)

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
        length: .sevenDay, weights: .even, asOf: weeklyNow, now: weeklyNow, calendar: utc)
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
  }

  // MARK: - DayWeights

  static func dayWeights() {
    section("DayWeights")
    // Sunday first, Foundation's numbering: Monday at 1, Tuesday at 0.5.
    let weekdays = DayWeights(values: [0, 1, 0.5, 1, 1, 1, 0])
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
      DayWeights.even.consumed(from: springSaturday, to: springMonday, calendar: paris),
      47 * 3600)
    let sundayOnly = DayWeights(values: [1, 0, 0, 0, 0, 0, 0])
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
      DayWeights(values: [0, 1, 0, 0, 0, 0, 1]).consumed(
        from: springSaturday, to: springMonday, calendar: paris),
      24 * 3600)

    expectEqual(
      "the inverse walks the same short day",
      DayWeights.even.date(
        reaching: 47 * 3600, from: parisDate(2026, 3, 28, 0), limit: parisDate(2026, 4, 4, 0),
        calendar: paris),
      parisDate(2026, 3, 30, 0))
    expectEqual(
      "and steps over a zero-weight Sunday rather than dividing by it",
      DayWeights(values: [0, 1, 1, 1, 1, 1, 1]).date(
        reaching: 2 * 3600, from: date("2026-09-12T23:00:00Z"),
        limit: date("2026-09-19T00:00:00Z"), calendar: utc),
      date("2026-09-14T01:00:00Z"))
    expectEqual(
      "a target past the limit is never reached",
      DayWeights.even.date(
        reaching: 10 * 3600, from: mondayNight, limit: mondayNight.addingTimeInterval(3600),
        calendar: utc),
      nil as Date?)

    check("an all-zero profile degrades to even", DayWeights(stored: "0,0,0,0,0,0,0") == .even)
    check("so does a short one", DayWeights(stored: "100,50") == .even)
    expectEqual(
      "a stored profile round-trips",
      DayWeights(stored: "25,100,100,50,100,100,25").stored, "25,100,100,50,100,100,25")
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
  }

  // MARK: - CodexRollout

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
