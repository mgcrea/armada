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

extension CodexAutomation {
  /// `status`, in the spelling Armada's own tools and rows use elsewhere.
  var apiStatus: String { status == "ACTIVE" ? "active" : "paused" }
}

/// The `automation.toml` format: exactly what the Codex app writes, and nothing more.
///
/// **Not a TOML parser.** It reads the subset `dB` produces (one `key = value` per line; basic
/// strings with five escapes; integers; string arrays; one inline table) and calls anything
/// else hand-edited. A hand-edited file is still listed, but never rewritten, because writing
/// it back through this serializer would drop whatever the person added.
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
    var fields: [String: Value] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      guard let equals = line.range(of: " = ") else {
        return .handEdited("A line is not `key = value`: \(line.prefix(60))")
      }
      let key = String(line[..<equals.lowerBound])
      guard knownKeys.contains(key) else {
        return .handEdited("It has a key Codex does not write: \(key)")
      }
      guard fields[key] == nil else { return .handEdited("\(key) appears twice.") }
      guard let value = value(String(line[equals.upperBound...])) else {
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
      return .automation(automation)
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
    return .automation(automation)
  }

  /// One value, in the spellings `bz`, `xz` and the target line produce.
  private static func value(_ raw: String) -> Value? {
    if raw.hasPrefix("\"\"\"") { return nil }
    if raw.hasPrefix("\"") {
      guard let (s, rest) = basicString(Substring(raw)), rest.isEmpty else { return nil }
      return .string(s)
    }
    if raw.hasPrefix("[") { return strings(raw) }
    if raw.hasPrefix("{") { return table(raw) }
    if let int = Int64(raw) { return .int(int) }
    return nil
  }

  /// A basic string at the start of `text`, and whatever follows its closing quote.
  private static func basicString(_ text: Substring) -> (String, Substring)? {
    guard text.first == "\"" else { return nil }
    var out = ""
    var index = text.index(after: text.startIndex)
    while index < text.endIndex {
      let c = text[index]
      if c == "\"" { return (out, text[text.index(after: index)...]) }
      if c == "\\" {
        let next = text.index(after: index)
        guard next < text.endIndex else { return nil }
        switch text[next] {
        case "\\": out.append("\\")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "\"": out.append("\"")
        default: return nil
        }
        index = text.index(after: next)
        continue
      }
      out.append(c)
      index = text.index(after: index)
    }
    return nil
  }

  /// `[]` or `["a", "b"]`, as `xz` writes it.
  private static func strings(_ raw: String) -> Value? {
    if raw == "[]" { return .strings([]) }
    var rest = Substring(raw.dropFirst())
    var items: [String] = []
    while true {
      guard let (item, after) = basicString(rest) else { return nil }
      items.append(item)
      if after == "]" { return .strings(items) }
      guard after.hasPrefix(", ") else { return nil }
      rest = after.dropFirst(2)
    }
  }

  /// `{ type = "project", project_id = "…" }` or `{ type = "projectless" }`.
  private static func table(_ raw: String) -> Value? {
    guard raw.hasPrefix("{ "), raw.hasSuffix(" }") else { return nil }
    var rest = Substring(raw.dropFirst(2).dropLast(2))
    var table: [String: String] = [:]
    while !rest.isEmpty {
      guard let equals = rest.range(of: " = ") else { return nil }
      let key = String(rest[..<equals.lowerBound])
      guard let (value, after) = basicString(rest[equals.upperBound...]), table[key] == nil else {
        return nil
      }
      table[key] = value
      if after.isEmpty { break }
      guard after.hasPrefix(", ") else { return nil }
      rest = after.dropFirst(2)
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

  /// `bz`: backslash first, then the four others. Nothing else is escaped.
  static func quoted(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  // MARK: Schedules

  private static let ruleKeys: Set<String> = [
    "FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYDAY", "COUNT",
  ]
  private static let weekdays = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

  /// `BYDAY`'s value, split on its commas. Shared by `scheduleRefusal` and `summary` so the two
  /// never drift on what counts as a day.
  private static func days(_ byDay: String?) -> [String] {
    byDay.map { $0.split(separator: ",").map(String.init) } ?? []
  }

  /// The rule in Codex's spelling (`RRULE:` and upper case), or nil when it is not one
  /// single-line rule of `KEY=VALUE` parts.
  static func normalizedRRule(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
    var body = trimmed.uppercased()
    if body.hasPrefix("RRULE:") { body = String(body.dropFirst(6)) }
    let parts = body.split(separator: ";")
    guard !parts.isEmpty, parts.allSatisfy({ $0.split(separator: "=").count == 2 }) else {
      return nil
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

  private static func numbers(_ list: String?, in range: ClosedRange<Int>) -> [Int]? {
    guard let list else { return [] }
    let values = list.split(separator: ",").map { Int($0) }
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
    else { return "\(quotedRule) has an hour or minute out of range." }
    let ruleDays = days(p["BYDAY"])
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
    let hours = numbers(p["BYHOUR"], in: 0...23) ?? []
    let minutes = numbers(p["BYMINUTE"], in: 0...59) ?? []
    let times = hours.flatMap { h in
      (minutes.isEmpty ? [0] : minutes).map { String(format: "%02ld:%02ld", h, $0) }
    }
    let at = times.isEmpty ? "" : " at " + times.joined(separator: ", ")
    if p["COUNT"] == "1" { return "once" + at }
    let interval = Int(p["INTERVAL"] ?? "1") ?? 1
    let ruleDays = days(p["BYDAY"])
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
