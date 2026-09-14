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

  /// Where that state sorts among its own vendor's others. 0 comes first.
  ///
  /// **Ordered by what wants you, not by what is busy.** A session stopped on a
  /// permission prompt is the one row in the list you can actually do something about,
  /// so it leads; work in progress follows; finished work sinks. Grouping by state is
  /// a triage view, and triage does not start with the things that need nothing.
  ///
  /// Lives with the list's conformances in `SessionListConformances.swift` rather than
  /// on the enums, because it is a property of *this list's* reading order, not of the
  /// state: nothing else in the app ranks states.
  var stateRank: Int { get }

  /// How full this session's context window is, in tokens, as of its newest turn.
  ///
  /// **Occupancy, not spend.** This is the size of the current prompt — it falls when
  /// a session compacts, and it counts the cached prefix that every turn re-reads. It
  /// is emphatically not "tokens this session has cost", and the two must not share a
  /// column: `CodexSession.totalTokens` is the cumulative figure, Codex reports it
  /// only for itself, and Claude Code records no equivalent anywhere on disk.
  ///
  /// Nil for a session that has never been prompted, and for the moment between a
  /// session appearing and its first transcript read.
  var contextTokens: Int? { get }
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

  /// Project, not `.none`. The list's most common question is "what is running in
  /// this checkout", and answering it flat means reading every row for a folder name
  /// that is already written on each of them. Sections say it once.
  ///
  /// It costs nothing when there is only one project — a single header, naming the
  /// folder the pane is otherwise silent about — and pays off at the nineteen
  /// sessions across six checkouts this was built against.
  static let fallback = SessionGrouping.project

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

  /// The context these sessions are holding between them.
  ///
  /// A sum of occupancies, which is a real quantity — "this checkout has 1.2M tokens
  /// of context open" is the thing worth knowing when several sessions in one project
  /// are all approaching their windows. It is **not** a bill, and it drops when any
  /// one of them compacts.
  ///
  /// Sessions with no reading yet contribute nothing rather than zero, and a group
  /// where none of them has one totals nil so the header stays quiet instead of
  /// claiming 0.
  var contextTokens: Int? {
    let known = items.compactMap(\.contextTokens)
    return known.isEmpty ? nil : known.reduce(0, +)
  }
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
        let (left, right) = (bucket($0.lastActivity), bucket($1.lastActivity))
        return left == right ? stable($0, $1) : left > right
      }
    case .started:
      items.sorted(by: stable)
    case .name:
      items.sorted {
        switch $0.displayName.localizedStandardCompare($1.displayName) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: stable($0, $1)
        }
      }
    case .project:
      // Alphabetical by folder, newest activity inside each. The secondary key is
      // fixed rather than a second menu: "sort by project" with the folders in order
      // and the rows inside them in no particular order would be half a sort.
      items.sorted {
        let byName = $0.projectName.localizedStandardCompare($1.projectName)
        if byName != .orderedSame { return byName == .orderedAscending }
        // Two checkouts can share a folder name. Splitting on the path keeps each
        // one's sessions contiguous, which is the whole promise of "sort by project";
        // without it `~/work/api` and `~/oss/api` interleave by activity.
        if $0.projectPath != $1.projectPath { return $0.projectPath < $1.projectPath }
        let (left, right) = (bucket($0.lastActivity), bucket($1.lastActivity))
        return left == right ? stable($0, $1) : left > right
      }
    }
  }

  /// How long two sessions have to differ by before the list is willing to reorder
  /// them.
  ///
  /// **This is what stops the list jumping.** `lastActivity` reads the registry's
  /// `updatedAt`, and Claude Code rewrites that on *every* status change — busy →
  /// waiting → busy is three moves in as many seconds. Sorting on the raw value means
  /// a row leapfrogs its neighbours every time a tool starts, and since any session's
  /// registry write triggers a full rescan, the whole list re-sorts with it.
  ///
  /// A minute is the coarsest bucket that still reads as "just now" versus "a while
  /// ago", which is all this sort is really claiming.
  private static let activityBucket: TimeInterval = 60

  private static func bucket(_ date: Date?) -> Date {
    guard let date else { return .distantPast }
    let seconds = date.timeIntervalSinceReferenceDate
    return Date(
      timeIntervalSinceReferenceDate: (seconds / activityBucket).rounded(.down) * activityBucket)
  }

  /// The order two sessions fall into when the chosen key cannot separate them.
  ///
  /// Newest-started first, then id — both of which are fixed for the life of a
  /// session, so this can never be the thing that moves a row. Every comparator ends
  /// here, which is also what makes them total orders: `sorted(by:)` is introsort and
  /// is not stable, so two items that compare equal would otherwise be free to swap on
  /// any re-sort.
  private static func stable<Item: SessionListItem>(_ lhs: Item, _ rhs: Item) -> Bool {
    let (left, right) = (lhs.startedAt ?? .distantPast, rhs.startedAt ?? .distantPast)
    return left == right ? lhs.id > rhs.id : left > right
  }

  /// `localizedStandardCompare`, which is what Finder sorts filenames with: case- and
  /// diacritic-insensitive, and number-aware, so `armada-2` comes before `armada-10`.
  /// A plain `<` puts `Z` before `a` and `armada-10` before `armada-2`, and both look
  /// like bugs in a list of project folders.
  ///
  /// **The tiebreak is not optional.** Two checkouts can share a folder name, so a
  /// name comparison alone is not a total order and `sorted(by:)` may return either
  /// arrangement from one call to the next.
  private static func ascending(_ lhs: String, _ rhs: String, tie: (String, String)) -> Bool {
    switch lhs.localizedStandardCompare(rhs) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: tie.0 < tie.1
    }
  }

  /// Buckets, in an order that does not depend on the sort.
  ///
  /// **Section order is fixed: alphabetical for projects, triage rank for states.** An
  /// earlier cut ordered groups by where their first member landed, which read well —
  /// sort by activity and the folder you just touched floats up — and was the single
  /// worst thing in the list. Group order then inherited every twitch of the sort key,
  /// so one session changing status did not move one row, it threw an entire section
  /// past three others. Rows moving is a nuisance; sections moving loses your place.
  ///
  /// The rows inside each group still follow the chosen sort, which is where that
  /// expressiveness belongs — it costs a glance, not the whole page.
  ///
  /// `.none` returns one untitled group rather than an empty array, so a caller that
  /// forgets to branch still renders every row.
  static func group<Item: SessionListItem>(
    _ items: [Item], by grouping: SessionGrouping
  ) -> [SessionGroup<Item>] {
    guard grouping != .none else {
      return [SessionGroup(id: "", title: "", subtitle: nil, items: items)]
    }

    var buckets: [String: [Item]] = [:]
    for item in items {
      let key = grouping == .project ? item.projectPath : item.stateKey
      buckets[key, default: []].append(item)
    }

    let groups = buckets.compactMap { key, bucket -> SessionGroup<Item>? in
      guard let first = bucket.first else { return nil }
      return SessionGroup(
        id: key,
        title: grouping == .project ? first.projectName : first.stateLabel,
        subtitle: grouping == .project ? first.projectPath : nil,
        items: bucket)
    }

    // Both comparisons end on `id` — the cwd, or the state's raw value. Neither is a
    // formality: two checkouts can share a folder name, so title alone is not a total
    // order, and `sorted(by:)` would be free to return either arrangement each time.
    switch grouping {
    case .state:
      return groups.sorted {
        let (left, right) = ($0.items.first?.stateRank ?? 0, $1.items.first?.stateRank ?? 0)
        return left == right ? $0.id < $1.id : left < right
      }
    default:
      return groups.sorted { ascending($0.title, $1.title, tie: ($0.id, $1.id)) }
    }
  }
}
