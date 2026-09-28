import Foundation

/// One Codex automation, as `~/.codex/automations/<id>/automation.toml` holds it.
///
/// **Read off the Codex app's own code**, since the format is documented nowhere: the reader
/// `lB`, the writer `dB` and the schedule check `DB`/`EB` in ChatGPT.app's `app.asar`
/// (26.917.51856, measured 2026-09-28). The app reads these files from disk every time it
/// lists or schedules, and keeps only run state in its database, so the file is the automation.
nonisolated struct CodexAutomation: Sendable, Equatable {
  enum Target: Sendable, Equatable {
    case project(String)
    case projectless
  }

  var id: String
  /// `cron` or `heartbeat`. Armada creates only `cron`.
  var kind: String
  var name: String
  var prompt: String
  /// `ACTIVE` or `PAUSED`, Codex's spelling.
  var status: String
  var rrule: String
  var model: String?
  var reasoningEffort: String?
  var notificationPolicy: String?
  var pluginTemplateId: String?
  /// `local` or `worktree`.
  var executionEnvironment: String
  var localEnvironmentConfigPath: String?
  var target: Target?
  var cwds: [String]
  /// A heartbeat's thread, in place of `target` and `cwds`.
  var targetThreadId: String?
  /// Epoch milliseconds, as Codex writes them.
  var createdAt: Int64
  var updatedAt: Int64
}

/// `nonisolated` on the extension, not just inherited from the type: under
/// `-default-isolation MainActor` a plain `extension` does not pick up the isolation of the
/// type it extends, so without this every access to `apiStatus` from off the main actor
/// (`ScheduleStoreBridge`, run off the main actor like everything under `CodexWatcher`) would
/// need to hop actors to read a string. See `Armada/ProjectsBridge.swift`, `Armada/MessageHook.swift`.
nonisolated extension CodexAutomation {
  /// `status`, in the spelling Armada's own tools and rows use elsewhere.
  var apiStatus: String { status == "ACTIVE" ? "active" : "paused" }
}

/// The `automation.toml` format: exactly what the Codex app writes, and nothing more.
///
/// **Not a TOML parser.** It reads the subset `dB` produces (one `key = value` per line; basic
/// strings with five escapes; integers; string arrays; one inline table) and calls anything
/// else hand-edited. A hand-edited file is still listed, but never rewritten, because writing
/// it back through this serializer would drop whatever the person added.
///
/// **Every escape and every split below works on Unicode scalars, not `Character`.** A
/// `Character` is an extended grapheme cluster: a `"` or `\` immediately followed by a
/// combining mark (U+0301 and friends) is *one* `Character` in Swift, not two, so comparing it
/// against the literal `Character` `"\""` or `"\\"` silently fails — the quote is never seen as
/// a quote. Scalar-by-scalar comparison has no such blind spot: a combining mark is its own
/// scalar regardless of what it renders next to.
nonisolated enum CodexAutomationFile {
  enum Parsed: Sendable, Equatable {
    case automation(CodexAutomation)
    /// Readable as TOML by Codex, perhaps, but not in the shape Codex writes. The reason is for
    /// the person.
    case handEdited(String)
    /// Codex itself would skip it: another version, a missing field, a heartbeat without a
    /// thread.
    case notAutomation
  }

  static let version = 1

  /// Every key `dB` can write, and so every key this reads.
  static let knownKeys: Set<String> = [
    "version", "id", "kind", "name", "prompt", "status", "rrule", "model", "reasoning_effort",
    "notification_policy", "plugin_template_id", "execution_environment",
    "local_environment_config_path", "target", "cwds", "target_thread_id", "created_at",
    "updated_at",
  ]

  private enum Value: Equatable {
    case string(String)
    case int(Int64)
    case strings([String])
    case table([String: String])
  }

  // MARK: Parsing

  static func parse(_ text: String) -> Parsed {
    let lines = splitLines(Array(text.unicodeScalars))
    var fields: [String: Value] = [:]
    for (index, line) in lines.enumerated() {
      let isTrailing = index == lines.count - 1
      if isBlank(line) {
        if isTrailing { continue }
        return .handEdited("A blank line appears where a key belongs.")
      }
      guard let equals = findEquals(line) else {
        return .handEdited("A line is not `key = value`: \(scalarsToString(line.prefix(60)))")
      }
      let key = scalarsToString(line[line.startIndex..<equals])
      guard knownKeys.contains(key) else {
        return .handEdited("It has a key Codex does not write: \(key)")
      }
      guard fields[key] == nil else { return .handEdited("\(key) appears twice.") }
      guard let value = value(line[(equals + 3)...]) else {
        return .handEdited("\(key) is not written the way Codex writes it.")
      }
      fields[key] = value
    }

    func string(_ key: String) -> String? {
      if case .string(let s) = fields[key] { return s }
      return nil
    }
    func int(_ key: String) -> Int64? {
      if case .int(let i) = fields[key] { return i }
      return nil
    }

    if let version = fields["version"], version != .int(Int64(Self.version)) {
      return .notAutomation
    }
    guard let id = string("id"), let name = string("name"), let prompt = string("prompt"),
      let status = string("status"), let rrule = string("rrule"),
      let createdAt = int("created_at"), let updatedAt = int("updated_at")
    else { return .notAutomation }
    guard status == "ACTIVE" || status == "PAUSED" else {
      return .handEdited("Its status is neither ACTIVE nor PAUSED.")
    }
    let kind = string("kind") ?? "cron"

    var automation = CodexAutomation(
      id: id, kind: kind, name: name, prompt: prompt, status: status, rrule: rrule,
      model: string("model"), reasoningEffort: string("reasoning_effort"),
      notificationPolicy: string("notification_policy"),
      pluginTemplateId: string("plugin_template_id"),
      executionEnvironment: string("execution_environment") ?? "local",
      localEnvironmentConfigPath: string("local_environment_config_path"),
      target: nil, cwds: [], targetThreadId: string("target_thread_id"),
      createdAt: createdAt, updatedAt: updatedAt)

    if kind == "heartbeat" {
      guard let thread = automation.targetThreadId,
        !thread.trimmingCharacters(in: .whitespaces).isEmpty
      else { return .notAutomation }
      return finalized(automation, against: text)
    }
    guard case .strings(let cwds) = fields["cwds"] else { return .notAutomation }
    automation.cwds = cwds
    if case .table(let table) = fields["target"] {
      switch table["type"] {
      case "project":
        guard let project = table["project_id"] else {
          return .handEdited("Its project target names no project.")
        }
        automation.target = .project(project)
      case "projectless": automation.target = .projectless
      default: return .handEdited("Its target is neither a project nor projectless.")
      }
    }
    return finalized(automation, against: text)
  }

  /// The last guard: an automation this read back must write back to the same bytes, or it was
  /// not written by `dB` (a wrong-typed value silently dropped, a key foreign to its kind, a
  /// target table with the wrong keys for its own type…). This is what makes "never a lossy
  /// `.automation`" true by construction, rather than one case at a time.
  private static func finalized(_ automation: CodexAutomation, against text: String) -> Parsed {
    serialize(automation) == text
      ? .automation(automation)
      : .handEdited("Writing it back would not reproduce the file byte for byte.")
  }

  /// `text.unicodeScalars`, split on `\n`, keeping empty lines (including the trailing one a
  /// well-formed file ends on) — the scalar equivalent of
  /// `split(separator: "\n", omittingEmptySubsequences: false)`.
  private static func splitLines(_ scalars: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
    var lines: [ArraySlice<Unicode.Scalar>] = []
    var start = scalars.startIndex
    for index in scalars.indices where scalars[index] == "\n" {
      lines.append(scalars[start..<index])
      start = index + 1
    }
    lines.append(scalars[start...])
    return lines
  }

  /// Only spaces and tabs — never a `\n`, since lines are already split on it.
  private static func isBlank(_ line: ArraySlice<Unicode.Scalar>) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" }
  }

  /// The index of the space that starts this line's ` = `, searching left to right so a
  /// quoted value containing that exact substring can never be mistaken for the separator: the
  /// key precedes every quote on the line, so the first match is always the real one.
  private static func findEquals(_ line: ArraySlice<Unicode.Scalar>) -> Int? {
    guard line.count >= 3 else { return nil }
    for index in line.startIndex...(line.endIndex - 3) {
      if line[index] == " ", line[index + 1] == "=", line[index + 2] == " " { return index }
    }
    return nil
  }

  private static func scalarsToString(_ slice: ArraySlice<Unicode.Scalar>) -> String {
    String(String.UnicodeScalarView(slice))
  }

  /// One value, in the spellings `bz`, `xz` and the target line produce.
  private static func value(_ raw: ArraySlice<Unicode.Scalar>) -> Value? {
    guard let first = raw.first else { return nil }
    if first == "\"" {
      if raw.count >= 3, raw[raw.startIndex + 1] == "\"", raw[raw.startIndex + 2] == "\"" {
        return nil
      }
      guard let (s, rest) = basicString(raw), rest.isEmpty else { return nil }
      return .string(s)
    }
    if first == "[" { return strings(raw) }
    if first == "{" { return table(raw) }
    return canonicalInt(raw).map { .int($0) }
  }

  /// `0`, or `[1-9][0-9]*`: no leading zero, no leading `+`, no leading `-`. Codex's own writer
  /// never emits any of the three, so a file that has one was not written by `dB`.
  private static func canonicalInt(_ raw: ArraySlice<Unicode.Scalar>) -> Int64? {
    guard let first = raw.first, ("0"..."9").contains(first) else { return nil }
    guard raw.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
    guard first != "0" || raw.count == 1 else { return nil }
    return Int64(scalarsToString(raw))
  }

  /// A basic string at the start of `scalars`, and whatever follows its closing quote. A raw
  /// (unescaped) control character inside it — a literal tab, newline, CR, or anything else
  /// under U+0020 — fails the read: `bz` always escapes those five characters, so a literal one
  /// proves the file was not written by `dB`.
  private static func basicString(
    _ scalars: ArraySlice<Unicode.Scalar>
  ) -> (String, ArraySlice<Unicode.Scalar>)? {
    guard scalars.first == "\"" else { return nil }
    var out = String.UnicodeScalarView()
    var index = scalars.startIndex + 1
    while index < scalars.endIndex {
      let c = scalars[index]
      if c == "\"" { return (String(out), scalars[(index + 1)...]) }
      if c == "\\" {
        let next = index + 1
        guard next < scalars.endIndex else { return nil }
        switch scalars[next] {
        case "\\": out.append("\\")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "\"": out.append("\"")
        default: return nil
        }
        index = next + 1
        continue
      }
      guard c.value >= 0x20, c.value != 0x7F else { return nil }
      out.append(c)
      index += 1
    }
    return nil
  }

  /// `[]` or `["a", "b"]`, as `xz` writes it.
  private static func strings(_ raw: ArraySlice<Unicode.Scalar>) -> Value? {
    guard raw.first == "[" else { return nil }
    var rest = raw[(raw.startIndex + 1)...]
    if rest.count == 1, rest.first == "]" { return .strings([]) }
    var items: [String] = []
    while true {
      guard let (item, after) = basicString(rest) else { return nil }
      items.append(item)
      if after.count == 1, after.first == "]" { return .strings(items) }
      guard after.count >= 2, after.first == ",", after[after.startIndex + 1] == " " else {
        return nil
      }
      rest = after[(after.startIndex + 2)...]
    }
  }

  /// `{ type = "project", project_id = "…" }` or `{ type = "projectless" }`.
  private static func table(_ raw: ArraySlice<Unicode.Scalar>) -> Value? {
    guard raw.count >= 4, raw.first == "{", raw[raw.startIndex + 1] == " ",
      raw[raw.endIndex - 2] == " ", raw[raw.endIndex - 1] == "}"
    else { return nil }
    var rest = raw[(raw.startIndex + 2)..<(raw.endIndex - 2)]
    var table: [String: String] = [:]
    while !rest.isEmpty {
      guard let equals = findEquals(rest) else { return nil }
      let key = scalarsToString(rest[rest.startIndex..<equals])
      guard let (value, after) = basicString(rest[(equals + 3)...]), table[key] == nil else {
        return nil
      }
      table[key] = value
      if after.isEmpty { break }
      guard after.count >= 2, after.first == ",", after[after.startIndex + 1] == " " else {
        return nil
      }
      rest = after[(after.startIndex + 2)...]
    }
    guard Set(table.keys).isSubset(of: ["type", "project_id"]) else { return nil }
    return .table(table)
  }

  // MARK: Writing

  /// `dB`, line for line: the same keys in the same order, one per line, a trailing newline.
  static func serialize(_ a: CodexAutomation) -> String {
    var lines = [
      "version = \(version)", "id = \(quoted(a.id))", "kind = \(quoted(a.kind))",
      "name = \(quoted(a.name))", "prompt = \(quoted(a.prompt))", "status = \(quoted(a.status))",
      "rrule = \(quoted(a.rrule))",
    ]
    if let model = a.model { lines.append("model = \(quoted(model))") }
    if let effort = a.reasoningEffort { lines.append("reasoning_effort = \(quoted(effort))") }
    if let policy = a.notificationPolicy { lines.append("notification_policy = \(quoted(policy))") }
    if a.kind == "heartbeat" {
      lines.append("target_thread_id = \(quoted(a.targetThreadId ?? ""))")
    } else {
      if let template = a.pluginTemplateId {
        lines.append("plugin_template_id = \(quoted(template))")
      }
      lines.append("execution_environment = \(quoted(a.executionEnvironment))")
      if let path = a.localEnvironmentConfigPath {
        lines.append("local_environment_config_path = \(quoted(path))")
      }
      switch a.target {
      case .project(let id):
        lines.append("target = { type = \"project\", project_id = \(quoted(id)) }")
      case .projectless: lines.append("target = { type = \"projectless\" }")
      case nil: break
      }
      lines.append(
        "cwds = " + (a.cwds.isEmpty ? "[]" : "[" + a.cwds.map(quoted).joined(separator: ", ") + "]")
      )
    }
    lines.append("created_at = \(a.createdAt)")
    lines.append("updated_at = \(a.updatedAt)")
    return lines.joined(separator: "\n") + "\n"
  }

  /// `bz`: backslash first, then the four others. Nothing else is escaped. Scalar by scalar, so
  /// a combining mark right after one of the five never hides it — see the type's doc comment.
  static func quoted(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\"": out += "\\\""
      default: out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
    return out
  }

  // MARK: Schedules

  private static let ruleKeys: Set<String> = [
    "FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYDAY", "COUNT",
  ]
  private static let weekdays = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

  /// `BYDAY`'s value, split on its commas, or nil for an empty item (`MO,,WE`) — the comma
  /// list Codex itself would never write empty.
  private static func days(_ byDay: String?) -> [String]? {
    guard let byDay else { return [] }
    let items = byDay.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard items.allSatisfy({ !$0.isEmpty }) else { return nil }
    return items
  }

  /// The rule in Codex's spelling (`RRULE:` and upper case), or nil when it is not one
  /// single-line rule of unique `KEY=VALUE` parts. Scalar-checked for `\r`/`\n`: a `Character`
  /// comparison misses an embedded `\r\n`, since CR-LF is itself one `Character` in Swift and so
  /// never equal to the bare `Character` `"\n"`.
  static func normalizedRRule(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.unicodeScalars.contains("\r"), !trimmed.unicodeScalars.contains("\n") else {
      return nil
    }
    var body = trimmed.uppercased()
    if body.hasPrefix("RRULE:") { body = String(body.dropFirst(6)) }
    let rawParts = body.split(separator: ";")
    guard !rawParts.isEmpty else { return nil }
    var seenKeys: Set<Substring> = []
    for part in rawParts {
      let pair = part.split(separator: "=")
      guard pair.count == 2, seenKeys.insert(pair[0]).inserted else { return nil }
    }
    return "RRULE:" + body
  }

  private static func parts(_ rrule: String) -> [String: String]? {
    guard let normal = normalizedRRule(rrule) else { return nil }
    var out: [String: String] = [:]
    for part in normal.dropFirst(6).split(separator: ";") {
      let pair = part.split(separator: "=")
      out[String(pair[0])] = String(pair[1])
    }
    return out
  }

  /// A comma list of numbers in `range`, or nil for an empty item (`7,,8`) or one out of range.
  private static func numbers(_ list: String?, in range: ClosedRange<Int>) -> [Int]? {
    guard let list else { return [] }
    let items = list.split(separator: ",", omittingEmptySubsequences: false)
    guard items.allSatisfy({ !$0.isEmpty }) else { return nil }
    let values = items.map { Int($0) }
    guard values.allSatisfy({ $0.map(range.contains) ?? false }) else { return nil }
    return values.compactMap { $0 }
  }

  /// Why Codex would not run this rule, or nil when it would. Codex accepts a recurring cron
  /// rule only when its frequency is hourly, daily or weekly (`DB`), an hourly one only on the
  /// hour and every day (`EB`), and treats `COUNT=1` as a one-time run.
  ///
  /// Armada is stricter than Codex in a few places — it also refuses `UNTIL`, `WKST`,
  /// `BYSETPOS`, `BYMONTHDAY`, and `BYHOUR` on an hourly rule — so a rule it accepts is one
  /// Codex schedules as written.
  static func scheduleRefusal(_ rrule: String) -> String? {
    let accepted =
      "Codex runs hourly (on the hour, every day), daily or weekly rules, or a one-time rule with "
      + "COUNT=1, such as RRULE:FREQ=DAILY;BYHOUR=7;BYMINUTE=0."
    guard let p = parts(rrule) else { return "\"\(rrule)\" is not an RRULE. \(accepted)" }
    let quotedRule = normalizedRRule(rrule) ?? rrule
    if let extra = Set(p.keys).subtracting(ruleKeys).sorted().first {
      return "\(quotedRule) uses \(extra), which Armada does not write. \(accepted)"
    }
    guard let freq = p["FREQ"], ["HOURLY", "DAILY", "WEEKLY"].contains(freq) else {
      return "\(quotedRule) is not hourly, daily or weekly. \(accepted)"
    }
    if let interval = p["INTERVAL"], (Int(interval) ?? 0) < 1 {
      return "\(quotedRule) has an INTERVAL that is not a positive number."
    }
    if let count = p["COUNT"], count != "1" {
      return "\(quotedRule) has COUNT=\(count); Codex takes COUNT=1 (once) or no COUNT."
    }
    guard let hours = numbers(p["BYHOUR"], in: 0...23),
      let minutes = numbers(p["BYMINUTE"], in: 0...59)
    else { return "\(quotedRule) has an hour or minute that is out of range or malformed." }
    guard let ruleDays = days(p["BYDAY"]) else {
      return "\(quotedRule) has a malformed BYDAY list."
    }
    guard ruleDays.allSatisfy(weekdays.contains) else {
      return "\(quotedRule) has a BYDAY that is not MO, TU, WE, TH, FR, SA or SU."
    }
    if freq == "HOURLY" {
      if !(minutes.isEmpty || minutes == [0]) || !hours.isEmpty {
        return "\(quotedRule) is hourly but not on the hour. \(accepted)"
      }
      if !ruleDays.isEmpty && Set(ruleDays).count != 7 {
        return "\(quotedRule) is hourly on some days only. \(accepted)"
      }
    }
    return nil
  }

  /// Plain words for a rule: "daily at 07:00", "weekly on Mon, Wed at 18:00", "every 4 hours".
  /// The rule itself when it is not one this can read.
  static func summary(_ rrule: String) -> String {
    guard let p = parts(rrule), let freq = p["FREQ"] else { return rrule }
    guard let hours = numbers(p["BYHOUR"], in: 0...23),
      let minutes = numbers(p["BYMINUTE"], in: 0...59), let ruleDays = days(p["BYDAY"])
    else { return rrule }
    let times: [String]
    if !hours.isEmpty {
      times = hours.flatMap { h in
        (minutes.isEmpty ? [0] : minutes).map { String(format: "%02ld:%02ld", h, $0) }
      }
    } else if !minutes.isEmpty && minutes != [0] {
      // No anchor hour, but the minute still says something — e.g. "at minute 30".
      times = minutes.map { "minute \($0)" }
    } else {
      times = []
    }
    let at = times.isEmpty ? "" : " at " + times.joined(separator: ", ")
    if p["COUNT"] == "1" { return "once" + at }
    let interval = Int(p["INTERVAL"] ?? "1") ?? 1
    switch freq {
    case "HOURLY": return interval == 1 ? "hourly" : "every \(interval) hours"
    case "DAILY": return (interval == 1 ? "daily" : "every \(interval) days") + at
    case "WEEKLY":
      if Set(ruleDays).count == 7 { return "daily" + at }
      let names = [
        "MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu", "FR": "Fri", "SA": "Sat", "SU": "Sun",
      ]
      let on =
        ruleDays.isEmpty ? "" : " on " + ruleDays.compactMap { names[$0] }.joined(separator: ", ")
      return (interval == 1 ? "weekly" : "every \(interval) weeks") + on + at
    default: return rrule
    }
  }

  // MARK: Ids

  /// `Xz`: lower case, each run of anything else a single `-`, no `-` at either end.
  static func slug(_ name: String) -> String {
    var out = ""
    var pendingDash = false
    for scalar in name.lowercased().unicodeScalars {
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        if pendingDash && !out.isEmpty { out.append("-") }
        pendingDash = false
        out.unicodeScalars.append(scalar)
      } else {
        pendingDash = true
      }
    }
    return out.isEmpty ? "automation" : out
  }

  /// The slug, or the slug with `-2`, `-3`… when a folder or a leftover database row holds it.
  static func uniqueID(for name: String, taken: Set<String>) -> String {
    let base = slug(name)
    if !taken.contains(base) { return base }
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
  }
}
