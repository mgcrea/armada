import Foundation

/// What a name typed as `/name`, or passed to the `Skill` tool, turned out to be.
nonisolated enum SkillSource: String, Sendable {
  case skill, command, plugin, builtin
}

/// Tells skills and custom commands from Claude Code's own slash commands.
///
/// **At snapshot time, never stored.** A skill installed tomorrow turns yesterday's uses of
/// its name into a skill's, and one deleted turns them back, with no rescan.
///
/// **In the spec's order, cheapest first.** A name with a `:` is a plugin's, and a name the
/// model called through the `Skill` tool is a skill, both without touching the disk. Only a
/// name that was only ever typed is looked for: in each account's config folder, then in
/// `.claude` of the folder it was typed in and each parent up to `home`. What is found
/// nowhere is a built-in like `/compact`.
nonisolated enum SkillCatalog {
  /// configs: each Claude account's config folder (`ClaudeConfigFolder.base`).
  static func classify(
    _ rows: [SkillUsageRow], configs: [URL], home: String,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> [String: SkillSource] {
    var folders: [String: Set<String>] = [:]
    var auto: Set<String> = []
    for row in rows {
      folders[row.skill, default: []].insert(row.cwd)
      if row.kind == .auto { auto.insert(row.skill) }
    }
    let bases = configs.map { ProjectPath.normalize($0.path(percentEncoded: false)) }
    let home = ProjectPath.normalize(home)

    func found(_ name: String, in base: String) -> SkillSource? {
      if fileExists("\(base)/skills/\(name)/SKILL.md") { return .skill }
      if fileExists("\(base)/commands/\(name).md") { return .command }
      return nil
    }

    var sources: [String: SkillSource] = [:]
    for (name, cwds) in folders {
      if name.contains(":") {
        sources[name] = .plugin
        continue
      }
      if auto.contains(name) {
        sources[name] = .skill
        continue
      }
      var source: SkillSource?
      for base in bases where source == nil { source = found(name, in: base) }
      var walked: Set<String> = []
      for cwd in cwds.sorted() where source == nil {
        for folder in lineage(of: cwd, home: home) where source == nil {
          guard walked.insert(folder).inserted else { break }
          source = found(name, in: folder + "/.claude")
        }
      }
      sources[name] = source ?? .builtin
    }
    return sources
  }

  /// `cwd` and each parent up to and including `home`, or up to the root's child when `cwd`
  /// is outside it. Empty for `~tmp`, the bucket for temp folders, and anything not absolute.
  ///
  /// The root itself is left out: a `/.claude` is nobody's project.
  private static func lineage(of cwd: String, home: String) -> [String] {
    var folder = ProjectPath.normalize(cwd)
    guard folder.hasPrefix("/") else { return [] }
    var folders: [String] = []
    while folder != "/" {
      folders.append(folder)
      if folder == home { break }
      guard let slash = folder.lastIndex(of: "/") else { break }
      folder = slash == folder.startIndex ? "/" : String(folder[..<slash])
    }
    return folders
  }
}

/// One skill's uses in one window, for one project (or none) and one account.
nonisolated struct SkillTally: Hashable, Sendable {
  let projectID: String?
  let account: String
  let skill: String
  let source: SkillSource
  let window: StatsWindow
  let auto: Int
  let slash: Int
  let lastAt: Date

  var total: Int { auto + slash }
}

/// Rolls skill uses up per project, account, skill and window.
///
/// **From folders at query time, as `ProjectStats` does it.** A use goes to the deepest
/// project holding the folder it happened in, or to none: a tally with a nil `projectID` is
/// a use outside every saved project, `~tmp` included.
nonisolated enum SkillStats {
  static func compute(
    _ rows: [SkillUsageRow], projects: [ProjectPath.Candidate],
    sources: [String: SkillSource], today: Date, calendar: Calendar
  ) -> [SkillTally] {
    struct Key: Hashable {
      let projectID: String?
      let account: String
      let skill: String
      let window: StatsWindow
    }
    struct Sum {
      var auto = 0
      var slash = 0
      var lastAt = Date.distantPast
    }

    let windows = StatsWindow.allCases
    let floors = windows.map { $0.floor(today: today, calendar: calendar) }
    var owners: [String: String?] = [:]
    var sums: [Key: Sum] = [:]
    for row in rows {
      let owner: String?
      if let known = owners[row.cwd] {
        owner = known
      } else {
        owner = ProjectPath.deepest(for: row.cwd, in: projects)
        owners[row.cwd] = .some(owner)
      }
      for (window, floor) in zip(windows, floors) where row.day >= floor {
        let key = Key(projectID: owner, account: row.account, skill: row.skill, window: window)
        var sum = sums[key, default: Sum()]
        switch row.kind {
        case .auto: sum.auto += row.count
        case .slash: sum.slash += row.count
        }
        sum.lastAt = max(sum.lastAt, row.lastAt)
        sums[key] = sum
      }
    }

    // Windows in their declared order, then the busiest skill first, so the order never
    // depends on the dictionary's.
    let rank = Dictionary(uniqueKeysWithValues: windows.enumerated().map { ($1, $0) })
    return sums.map { key, sum in
      SkillTally(
        projectID: key.projectID, account: key.account, skill: key.skill,
        source: sources[key.skill] ?? .builtin, window: key.window, auto: sum.auto,
        slash: sum.slash, lastAt: sum.lastAt)
    }.sorted {
      let lhs = rank[$0.window] ?? 0
      let rhs = rank[$1.window] ?? 0
      if lhs != rhs { return lhs < rhs }
      if $0.projectID != $1.projectID { return ($0.projectID ?? "") < ($1.projectID ?? "") }
      if $0.account != $1.account { return $0.account < $1.account }
      if $0.total != $1.total { return $0.total > $1.total }
      return $0.skill < $1.skill
    }
  }
}
