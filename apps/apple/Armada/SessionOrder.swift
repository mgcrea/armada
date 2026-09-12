import Foundation

/// What the session list needs from a session in order to sort and group it.
///
/// Deliberately the *smallest* set of facts that answers those two questions, and
/// deliberately not a shared session model. `Session` and `CodexSession` describe two
/// vendors that agree about almost nothing — see `CodexSessionState` for why even the
/// state enums are different sets on purpose — and a protocol wide enough to unify
/// them would be the place that disagreement got quietly flattened.
protocol SessionListItem: Identifiable where ID == String {
  /// What to call this session in a list.
  var displayName: String { get }

  /// The folder, as a person would name it.
  var projectName: String { get }

  /// The folder's full path. This is the key project grouping buckets on, never the
  /// name — see `SessionGroup.id`.
  var projectPath: String { get }

  var startedAt: Date? { get }

  /// The newest thing this session did, falling back to when it started.
  var lastActivity: Date? { get }

  /// The state's own raw value and label — `SessionState`'s or `CodexSessionState`'s,
  /// never a third vocabulary invented here. Grouping by state puts a Claude session
  /// under "Idle" and a Codex one under "Ended" because those are different facts.
  var stateKey: String { get }
  var stateLabel: String { get }

  /// Where that state sorts among its own vendor's others. 0 is the busiest.
  ///
  /// Lives here rather than on the enums because it is a property of *this list's*
  /// reading order, not of the state: nothing else in the app ranks states.
  var stateRank: Int { get }
}

extension Session: SessionListItem {
  var projectName: String { registry.projectName }
  var projectPath: String { registry.cwd }
  var startedAt: Date? { registry.startedAtDate }

  /// `lastWrite ?? startedAt`, which is the expression `CodexWatcher` already sorts
  /// on — consistency rather than invention. The fallback still matters even with
  /// `SessionWatcher.refreshTitle` seeding `lastWrite` from the transcript's mtime: a
  /// session that has never been prompted has no transcript at all, and its start
  /// time is the only activity it has.
  var lastActivity: Date? { lastWrite ?? registry.startedAtDate }

  var stateKey: String { state.rawValue }
  var stateLabel: String { state.label }
  var stateRank: Int {
    switch state {
    case .working: 0
    case .runningTool: 1
    case .idle: 2
    }
  }
}

extension CodexSession: SessionListItem {
  var projectName: String { meta.projectName }
  var projectPath: String { meta.cwd }
  var startedAt: Date? { meta.startedAt }
  var lastActivity: Date? { lastEventAt ?? meta.startedAt }

  var stateKey: String { state.rawValue }
  var stateLabel: String { state.label }
  var stateRank: Int {
    switch state {
    case .working: 0
    case .awaitingInput: 1
    case .ended: 2
    }
  }
}

/// How the session list is ordered.
///
/// **Every key carries its own direction** rather than pairing with an
/// ascending/descending toggle. A single direction control has to mean opposite
/// things per key — "oldest first" for a date, "Z→A" for a name — and "Ascending ·
/// Last activity" is a phrase half of readers will guess backwards. Four checkmarked
/// items is a menu that reads in one glance.
///
/// Stored as a string round-trip rather than through `@AppStorage`'s
/// `RawRepresentable` overload, for the reason `DayWeights` gives: a value written by
/// a later version — a fifth key, a renamed case — has to degrade to the default, and
/// `init(stored:)` is what pins that down rather than leaving it to the framework.
enum SessionSort: String, CaseIterable, Identifiable {
  /// Newest activity first. The default, because it answers "what have I touched",
  /// which is the question this window exists for.
  case activity
  /// Newest session first — the order `SessionWatcher.rescan` has always produced.
  case started
  /// The session's title, A→Z.
  case name
  /// The folder's name, A→Z, newest activity inside each folder.
  case project

  static let defaultsKey = "armada.sessionSort"

  /// The one place the default lives. Three views declare `@AppStorage` on this key,
  /// and a default typed out twice is a fresh install where the list is in one order
  /// and the menu's checkmark is on another.
  static let fallback = SessionSort.activity

  var id: String { rawValue }
  var stored: String { rawValue }
  init(stored: String) { self = SessionSort(rawValue: stored) ?? Self.fallback }

  var label: String {
    switch self {
    case .activity: "Last activity"
    case .started: "Started"
    case .name: "Name"
    case .project: "Project"
    }
  }

  var systemImage: String {
    switch self {
    case .activity: "clock"
    case .started: "calendar"
    case .name: "textformat"
    case .project: "folder"
    }
  }
}

/// What the list is broken into, if anything.
///
/// `.none` rather than `.flat` because the menu item says "None"; the enum is never
/// optional anywhere, so the usual `Optional.none` ambiguity cannot arise.
enum SessionGrouping: String, CaseIterable, Identifiable {
  case none
  case project
  case state

  static let defaultsKey = "armada.sessionGrouping"
  static let fallback = SessionGrouping.none

  var id: String { rawValue }
  var stored: String { rawValue }
  init(stored: String) { self = SessionGrouping(rawValue: stored) ?? Self.fallback }

  var label: String {
    switch self {
    case .none: "None"
    case .project: "Project"
    case .state: "State"
    }
  }
}

/// One section of the session list.
struct SessionGroup<Item: SessionListItem>: Identifiable {
  /// **The bucket's key, not its title, and unique by construction.** Two checkouts
  /// can share a folder name — `~/work/api` and `~/oss/api` are both "api" — and a
  /// `ForEach` keyed on the title would then run two sections under one id. That
  /// failure renders as sections showing each other's rows, which looks like a
  /// SwiftUI bug and is not one.
  let id: String
  let title: String
  /// The full path, for the tooltip that tells those two "api" sections apart.
  let subtitle: String?
  let items: [Item]
}

/// What order the session list is in.
///
/// Main-actor isolated by default, and that is right rather than an oversight: it
/// reads `@Observable` main-actor state, which is also what makes SwiftUI's
/// observation tracking notice when a session's `lastWrite` moves. Unlike
/// `TranscriptTitle` and friends there is no file I/O here to get off the thread
/// drawing the window — twenty items and a string compare apiece.
enum SessionOrder {
  static func arrange<Item: SessionListItem>(
    _ items: [Item], sort: SessionSort, grouping: SessionGrouping
  ) -> [SessionGroup<Item>] {
    group(sorted(items, by: sort), by: grouping)
  }

  /// **Every comparator ends in the `id` tiebreak**, the one from
  /// `SessionWatcher.rescan`: a total order is what keeps two rows that compare equal
  /// from swapping places on a tick.
  static func sorted<Item: SessionListItem>(_ items: [Item], by sort: SessionSort) -> [Item] {
    switch sort {
    case .activity:
      items.sorted {
        ($0.lastActivity ?? .distantPast, $0.id) > ($1.lastActivity ?? .distantPast, $1.id)
      }
    case .started:
      items.sorted {
        ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
      }
    case .name:
      items.sorted { ascending($0.displayName, $1.displayName, tie: ($0.id, $1.id)) }
    case .project:
      // Alphabetical by folder, newest activity inside each. The secondary key is
      // fixed rather than a second menu: "sort by project" with the folders in order
      // and the rows inside them in no particular order would be half a sort.
      items.sorted {
        if $0.projectName.localizedStandardCompare($1.projectName) != .orderedSame {
          return ascending($0.projectName, $1.projectName, tie: ($0.id, $1.id))
        }
        return ($0.lastActivity ?? .distantPast, $0.id) > ($1.lastActivity ?? .distantPast, $1.id)
      }
    }
  }

  /// `localizedStandardCompare`, which is what Finder sorts filenames with: case- and
  /// diacritic-insensitive, and number-aware, so `armada-2` comes before `armada-10`.
  /// A plain `<` puts `Z` before `a` and `armada-10` before `armada-2`, and both look
  /// like bugs in a list of project folders.
  private static func ascending(_ lhs: String, _ rhs: String, tie: (String, String)) -> Bool {
    switch lhs.localizedStandardCompare(rhs) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: tie.0 < tie.1
    }
  }

  /// Buckets, in the order their first member appears.
  ///
  /// **That one rule gives the right group order for every sort without a second
  /// decision.** Sorted by name the projects come out alphabetically, because their
  /// first members do; sorted by last activity the folder you just touched is on top.
  /// `.state` is the single exception and overrides it: somebody scanning for what is
  /// running wants that block first however the rows inside are ordered.
  ///
  /// `.none` returns one untitled group rather than an empty array, so a caller that
  /// forgets to branch still renders every row.
  static func group<Item: SessionListItem>(
    _ items: [Item], by grouping: SessionGrouping
  ) -> [SessionGroup<Item>] {
    guard grouping != .none else {
      return [SessionGroup(id: "", title: "", subtitle: nil, items: items)]
    }

    var keys: [String] = []
    var buckets: [String: [Item]] = [:]
    for item in items {
      let key = grouping == .project ? item.projectPath : item.stateKey
      if buckets[key] == nil { keys.append(key) }
      buckets[key, default: []].append(item)
    }

    let groups = keys.compactMap { key -> SessionGroup<Item>? in
      guard let first = buckets[key]?.first, let bucket = buckets[key] else { return nil }
      return SessionGroup(
        id: key,
        title: grouping == .project ? first.projectName : first.stateLabel,
        subtitle: grouping == .project ? first.projectPath : nil,
        items: bucket)
    }

    guard grouping == .state else { return groups }
    return groups.sorted { ($0.items.first?.stateRank ?? 0) < ($1.items.first?.stateRank ?? 0) }
  }
}
