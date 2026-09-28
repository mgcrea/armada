import SwiftUI

/// An account's History: the Claude Code sessions it ran that have no process behind them now,
/// by day, each one click from being read and one from being continued, here or elsewhere.
///
/// **Where a session that went missing is found again.** A VS Code tab restored after a reload
/// shows its conversation with nothing running behind it, so Armada's live list, which is the
/// registry, does not have it; nor does anything else in the app outside a project's last eight.
/// See `SessionHistory` for what is listed and why it is the ledger's rows.
///
/// One model per list, owned by the pane, so the detail beside the list reads the same entries
/// the list drew and a selection survives switching to Live and back.
@MainActor
@Observable
final class SessionHistoryModel {
  struct Entry: Identifiable, Sendable {
    let row: UsageSessionRow
    let transcript: URL
    /// When the transcript was last written, which is also what a cached title is checked by.
    let modified: Date
    var title: String?

    var id: String { row.sessionID }
    /// A resumed session and one never titled have no title on disk, so the id's head stands in.
    var displayName: String { title ?? "Session \(row.sessionID.prefix(8))" }
  }

  struct DayGroup: Identifiable {
    let id: Date
    let title: String
    let entries: [Entry]
  }

  /// Nil lists every account's, for a History pane of its own.
  let accountID: String?
  private(set) var entries: [Entry] = []
  /// `entries` narrowed by `query` and cut into days, recomputed when either changes rather than
  /// on every redraw: the pane redraws each second for its clocks, and this is 1,461 rows.
  private(set) var days: [DayGroup] = []
  private(set) var shownCount = 0
  /// False until the first listing is in, so an empty history and one still being read differ.
  private(set) var loaded = false

  var query = "" {
    didSet { if query != oldValue { regroup() } }
  }

  /// The rows the last listing was made from, so a ledger commit that changed nothing here,
  /// which is most of them while other sessions run, reads no directories.
  private var picked: [UsageSessionRow] = []

  /// Titles by transcript path, with the write they were read after. Shared by every list, so
  /// switching accounts or panes does not read them all again.
  private static var titles: [String: (modified: Date, title: String?)] = [:]

  /// How many titles are read before the list is redrawn with them.
  private static let titleBatch = 40

  init(accountID: String?) {
    self.accountID = accountID
  }

  func entries(for ids: Set<String>) -> [Entry] {
    guard !ids.isEmpty else { return [] }
    return entries.filter { ids.contains($0.id) }
  }

  /// List the ledger's rows again when they changed, then fill in the titles not yet read,
  /// newest first.
  ///
  /// **The titles are picked up again even when the rows are not.** The ledger commits every
  /// few seconds while other sessions run, and each commit cancels the reload before it: a
  /// reload that returned on unchanged rows would leave every title after the first cancel
  /// unread for as long as anything else was running.
  func reload(ledger: [UsageSessionRow], live: Set<String>, accounts: [Account]) async {
    let rows = SessionHistory.pick(from: ledger, account: accountID, live: live)
    if rows != picked || !loaded {
      let directories = Dictionary(
        accounts.map { ($0.id, Self.projectsDir(of: $0)) }, uniquingKeysWith: { first, _ in first })
      let located = await Task.detached(priority: .userInitiated) {
        Self.locate(rows, in: directories)
      }.value
      guard !Task.isCancelled else { return }
      picked = rows
      entries = located.map { row, transcript, modified in
        let cached = Self.titles[transcript.path(percentEncoded: false)]
        return Entry(
          row: row, transcript: transcript, modified: modified,
          title: cached?.modified == modified ? cached?.title : nil)
      }
      loaded = true
      regroup()
    }

    let unread = entries.filter {
      Self.titles[$0.transcript.path(percentEncoded: false)]?.modified != $0.modified
    }
    for start in stride(from: 0, to: unread.count, by: Self.titleBatch) {
      let batch = Array(unread[start..<min(start + Self.titleBatch, unread.count)])
      let read = await Task.detached(priority: .utility) {
        batch.map { ($0.transcript, $0.modified, RecentSessionsSection.title(of: $0.transcript)) }
      }.value
      // Cached and shown even by a reload that has been cancelled meanwhile, and only then
      // does it stop: the next one takes a cached title as read, so a title kept here but not
      // put on its row would never reach it.
      var found: [String: String] = [:]
      for (transcript, modified, title) in read {
        Self.titles[transcript.path(percentEncoded: false)] = (modified, title)
        if let title { found[transcript.path(percentEncoded: false)] = title }
      }
      if !found.isEmpty {
        entries = entries.map { entry in
          var entry = entry
          if let title = found[entry.transcript.path(percentEncoded: false)] { entry.title = title }
          return entry
        }
        regroup()
      }
      guard !Task.isCancelled else { return }
    }
  }

  private func regroup() {
    let shown =
      query.isEmpty
      ? entries
      : entries.filter { SessionHistory.matches(query, title: $0.title, cwd: $0.row.cwd) }
    let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    shownCount = shown.count
    days = SessionHistory.days(shown.map(\.row), now: AppClock.now).map { day in
      DayGroup(id: day.id, title: day.title, entries: day.rows.compactMap { byID[$0.sessionID] })
    }
  }

  /// Where an account's transcripts are listed from: its `projects/`, or under a capture the
  /// fixture folder `DemoSeed` writes, since no fixture account's own folder exists.
  private static func projectsDir(of account: Account) -> URL {
    #if DEBUG
      if ScreenshotMode.isEnabled { return DemoSeed.historyProjectsDir }
    #endif
    return account.folder.projectsDir
  }

  /// Each row's transcript, from one listing of every project folder of the accounts involved,
  /// rather than `TranscriptLocator` per row: its fallback lists every folder for each row it
  /// misses, and a history reaching back past Claude Code's cleanup misses a few hundred.
  ///
  /// A row with no transcript left is dropped. There is nothing behind it to read or resume.
  nonisolated private static func locate(
    _ rows: [UsageSessionRow], in directories: [String: URL]
  ) -> [(UsageSessionRow, URL, Date)] {
    let fileManager = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    var found: [String: [String: (URL, Date)]] = [:]
    for account in Set(rows.map(\.account)) {
      guard let projects = directories[account] else { continue }
      var byID: [String: (URL, Date)] = [:]
      let folders =
        (try? fileManager.contentsOfDirectory(
          at: projects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for folder in folders {
        let files =
          (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        for file in files where file.pathExtension == "jsonl" {
          let modified =
            (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
          let id = file.deletingPathExtension().lastPathComponent
          // Two folders holding one id is a handover's copy under a second cwd; the newer one
          // is the conversation as it stands.
          if let known = byID[id], known.1 >= modified { continue }
          byID[id] = (file, modified)
        }
      }
      found[account] = byID
    }
    return rows.compactMap { row in
      guard let (url, modified) = found[row.account]?[row.sessionID] else { return nil }
      return (row, url, modified)
    }
  }
}

/// The list itself: days, rows, and the context menu, over a `SessionHistoryModel`.
struct SessionHistoryList: View {
  let model: SessionHistoryModel
  @Binding var selection: Set<String>
  /// Name each row's account, for a list of more than one.
  var showsAccount = false

  @State private var index = UsageIndex.shared
  @State private var accounts = Accounts.shared

  var body: some View {
    Group {
      if !model.loaded {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.entries.isEmpty {
        ContentUnavailableView {
          Label("No history", systemImage: "clock.arrow.circlepath")
        } description: {
          Text(
            "Sessions that are no longer running appear here, for as long as Claude Code keeps their transcripts."
          )
        }
      } else if model.days.isEmpty {
        ContentUnavailableView.search(text: model.query)
      } else {
        List(selection: $selection) {
          ForEach(model.days) { day in
            Section(day.title) {
              ForEach(day.entries) { entry in
                SessionHistoryRow(
                  entry: entry,
                  accountName: showsAccount
                    ? accounts.account(id: entry.row.account)?.displayName : nil
                )
                .tag(entry.id)
                .id(entry.id)
              }
            }
          }
        }
        // On the `List`, as the live list's is, so a right-click acts on the row under it.
        .contextMenu(forSelectionType: String.self) { ids in
          SessionHistoryContextItems(entries: model.entries(for: ids))
        }
      }
    }
    .task(id: reloadKey) {
      await model.reload(ledger: index.ledger.sessions, live: liveIDs, accounts: accounts.all)
    }
    // A row that has just been resumed is live now, and leaves; so does its selection.
    .onChange(of: model.entries.map(\.id)) { _, ids in
      let kept = selection.intersection(ids)
      if kept != selection { selection = kept }
    }
  }

  private var liveIDs: Set<String> {
    Set(accounts.all.flatMap { $0.sessions.sessions.map(\.id) })
  }

  /// The ledger's generation, so a session that has just ended arrives once it is indexed, and
  /// the live ids, so one that has just been resumed leaves.
  private var reloadKey: [String] {
    ["\(index.ledger.generation)"] + liveIDs.sorted()
  }
}

/// One History row: the title, where it ran, and the time of day it last wrote, the day being
/// its section's.
struct SessionHistoryRow: View {
  let entry: SessionHistoryModel.Entry
  /// Shown after the folder when set, for a list of more than one account.
  let accountName: String?

  @State private var store = ProjectStore.shared

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.displayName)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 8)
      Text(entry.row.lastAt, format: .dateTime.hour().minute())
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(.vertical, 2)
  }

  private var subtitle: String {
    var parts = [SessionHistoryFolder.label(for: entry.row.cwd, in: store)]
    if let accountName { parts.append(accountName) }
    return parts.joined(separator: " · ")
  }
}

/// Where a History session ran, said the way the live list says it: the project, then the
/// subfolder when it was not the project's own.
@MainActor
enum SessionHistoryFolder {
  static func label(for cwd: String, in store: ProjectStore) -> String {
    let path = ProjectPath.normalize(cwd)
    guard let project = store.project(containing: path) else {
      return (path as NSString).abbreviatingWithTildeInPath
    }
    guard path != project.path, ProjectPath.contains(project.path, path) else {
      return project.displayName
    }
    return "\(project.displayName) · \(path.dropFirst(project.path.count + 1))"
  }
}

/// The context menu: one session's actions, or the batch's for several.
struct SessionHistoryContextItems: View {
  let entries: [SessionHistoryModel.Entry]

  @State private var accounts = Accounts.shared

  var body: some View {
    if entries.count > 1 {
      SessionHistoryBatchItems(entries: entries, destinations: destinations)
    } else if let entry = entries.first {
      Button("Resume Session") { SessionResumer.resume(entry.row) }
      ContinueElsewhereItems(row: entry.row, title: entry.title, accounts: destinations)
      Divider()
      Button("Read Transcript") {
        TranscriptWindow.shared.show(url: entry.transcript, name: entry.displayName)
      }
      CopyTranscriptButton(url: entry.transcript)
      CopySessionIDButton(id: entry.id)
    }
  }

  /// Every Claude account some of these are not on.
  private var destinations: [Account] {
    SessionHistoryBatch.destinations(for: entries, among: accounts.all)
  }
}

/// "Continue 3 Sessions on <account>", one item per account, or a submenu for several.
struct SessionHistoryBatchItems: View {
  let entries: [SessionHistoryModel.Entry]
  let destinations: [Account]

  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var copiesOnly = false

  var body: some View {
    let counted = "\(entries.count) \(SessionBatch.noun(entries.count))"
    let label = copiesOnly ? "Copy \(counted)" : "Continue \(counted)"
    if destinations.count > 1 {
      Menu(copiesOnly ? "\(label) to Another Account" : "\(label) on Another Account") {
        ForEach(destinations, id: \.id) { destination in
          Button(destination.displayName) {
            SessionHistoryBatch.continueAll(entries, on: destination)
          }
        }
      }
    } else {
      ForEach(destinations, id: \.id) { destination in
        Button(
          copiesOnly
            ? "\(label) to \(destination.displayName)" : "\(label) on \(destination.displayName)"
        ) {
          SessionHistoryBatch.continueAll(entries, on: destination)
        }
      }
    }
  }
}

/// Continuing several History sessions on another account, reported once for the batch.
@MainActor
enum SessionHistoryBatch {
  static func destinations(
    for entries: [SessionHistoryModel.Entry], among accounts: [Account]
  ) -> [Account] {
    accounts.filter { account in entries.contains { $0.row.account != account.id } }
  }

  /// Each one through Continue's own checks, in the order they are listed. What did not go is
  /// said once, in the pane's batch report, rather than an alert per row replacing the last.
  static func continueAll(_ entries: [SessionHistoryModel.Entry], on destination: Account) {
    let refusals = entries.compactMap { entry in
      SessionResumer.continueElsewhereReporting(entry.row, on: destination.id, title: entry.title)
        .map { SessionBatch.Refusal(name: entry.displayName, reason: $0) }
    }
    let copiesOnly = HandoverTarget.copiesOnly
    guard
      let message = SessionBatch.report(
        verb: copiesOnly
          ? "copied to \(destination.displayName)" : "continued on \(destination.displayName)",
        attempted: entries.count, refusals: refusals)
    else { return }
    SessionBatchActions.shared.report = SessionBatchActions.Report(
      title: copiesOnly ? "Not every session was copied" : "Not every session was continued",
      message: message)
  }
}
