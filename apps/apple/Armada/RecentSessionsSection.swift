import SwiftUI

/// "Recently ended" in a project's details: the last few Claude Code sessions that ran here and
/// are no longer open, each one click from being read and one from being continued.
///
/// **What makes Close Session's promise true.** Closing keeps the conversation "so it can be
/// resumed", and until this list the only thing that could resume one was an agent, through
/// `armada_start_session`. A row that left the sessions list had nowhere to be found again.
///
/// **Ended any way, not only closed from Armada.** The ledger records that a session last wrote
/// at some moment, not how it stopped, and one quit in its terminal is as worth picking up.
///
/// **A click reads, the button resumes.** Reading changes nothing and resuming opens a terminal,
/// so the larger target goes to the harmless one, as the popover's rows do with Focus.
struct RecentSessionsSection: View {
  let project: Project

  @State private var index = UsageIndex.shared
  @State private var store = ProjectStore.shared
  @State private var accounts = Accounts.shared
  @State private var entries: [Entry] = []

  struct Entry: Identifiable, Sendable {
    let row: UsageSessionRow
    let transcript: URL
    let accountName: String
    var title: String?

    var id: String { row.sessionID }
    /// A resumed session and one never titled have no title on disk, so the id's head stands in.
    var displayName: String { title ?? "Session \(row.sessionID.prefix(8))" }
  }

  /// More than are shown, because a row whose transcript Claude Code has since cleaned up is
  /// dropped rather than listed with nothing behind it.
  private static let candidateLimit = RecentSessions.limit * 3

  var body: some View {
    // No empty state: a project nothing has ended in has nothing to say here, and "Live
    // sessions" above already answers whether anything is running.
    Group {
      if !entries.isEmpty {
        Section("Recently ended") {
          ForEach(entries) { entry in
            row(entry)
          }
        }
      }
    }
    .task(id: reloadKey) { await reload() }
  }

  private func row(_ entry: Entry) -> some View {
    PanelRow(help: "Read this session's transcript") {
      TranscriptWindow.shared.show(url: entry.transcript, name: entry.displayName)
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(entry.displayName)
            .lineLimit(1)
          Text(subtitle(for: entry))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        Spacer(minLength: 8)
        Text(entry.row.lastAt, format: .clockRelative(presentation: .numeric))
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    } accessory: {
      Button("Resume") { SessionResumer.resume(entry.row) }
        .controlSize(.small)
        .help("Continue this conversation in a terminal, on \(entry.accountName)")
    }
    .contextMenu {
      Button("Resume Session") { SessionResumer.resume(entry.row) }
      ContinueElsewhereItems(
        row: entry.row, title: entry.title, accounts: otherAccounts(than: entry))
      Button("Read Transcript") {
        TranscriptWindow.shared.show(url: entry.transcript, name: entry.displayName)
      }
      CopyTranscriptButton(url: entry.transcript)
    }
  }

  /// The subfolder relative to the project, then the account, as a live row has it.
  private func subtitle(for entry: Entry) -> String {
    let cwd = ProjectPath.normalize(entry.row.cwd)
    var parts: [String] = []
    if cwd != project.path {
      parts.append(
        ProjectPath.contains(project.path, cwd)
          ? String(cwd.dropFirst(project.path.count + 1))
          : (cwd as NSString).abbreviatingWithTildeInPath)
    }
    parts.append(entry.accountName)
    return parts.joined(separator: " · ")
  }

  /// Every Claude account but the one this row's transcript is on.
  private func otherAccounts(than entry: Entry) -> [Account] {
    accounts.all.filter { $0.id != entry.row.account }
  }

  private var liveIDs: Set<String> {
    Set(accounts.all.flatMap { $0.sessions.sessions.map(\.id) })
  }

  /// The ledger's generation, so a session that has just ended arrives once it is indexed, and
  /// the live ids, so one that has just been resumed leaves.
  private var reloadKey: [String] {
    [project.id, "\(index.ledger.generation)"] + liveIDs.sorted()
  }

  private func reload() async {
    let picked = RecentSessions.pick(
      from: index.ledger.sessions, project: project.id, candidates: store.candidates,
      live: liveIDs, limit: Self.candidateLimit)
    var found: [Entry] = []
    for row in picked {
      guard let account = accounts.account(id: row.account),
        let transcript = TranscriptLocator.find(
          sessionId: row.sessionID, cwd: row.cwd, in: account.folder.projectsDir)
      else { continue }
      found.append(
        Entry(row: row, transcript: transcript, accountName: account.displayName, title: nil))
      if found.count == RecentSessions.limit { break }
    }
    // Titles after the rows, off the main actor: each is a 64KB read, and the list is worth
    // showing before the last of them comes back.
    entries = found.map { entry in
      var entry = entry
      entry.title = entries.first { $0.id == entry.id }?.title
      return entry
    }
    let titled = await Self.titles(for: found)
    guard !Task.isCancelled else { return }
    entries = titled
  }

  nonisolated private static func titles(for entries: [Entry]) async -> [Entry] {
    entries.map { entry in
      var entry = entry
      entry.title = title(of: entry.transcript)
      return entry
    }
  }

  /// The newest title in the transcript's tail, which is where `TranscriptTitle` finds it 96%
  /// of the time and the only place this list looks.
  nonisolated static func title(of transcript: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let tail = UInt64(TranscriptTitle.tailBytes)
    let offset = size > tail ? size - tail : 0
    guard (try? handle.seek(toOffset: offset)) != nil, let chunk = try? handle.readToEnd() else {
      return nil
    }
    return TranscriptTitle.newestTitle(inChunk: chunk, droppingFirstLine: offset > 0)
  }
}

/// "Continue on <account>" for an ended row: one item for one other account, a submenu for
/// several, nothing on a Mac with one.
///
/// **The live row's action, for a session that has none.** Continuing on another account was
/// only offered while a session ran, and a session stopped at one account's limit is the one
/// most worth moving: it is also usually one that has ended, or a VS Code tab restored with
/// no process behind it, which Armada cannot see as live. The accounts are listed when the
/// menu opens; whether the session can go is decided when an item is picked.
///
/// Shared with an account's History, which lists the same ledger rows.
struct ContinueElsewhereItems: View {
  let row: UsageSessionRow
  let title: String?
  let accounts: [Account]

  var body: some View {
    if accounts.count > 1 {
      Menu(HandoverTarget.copiesOnly ? "Copy to Another Account" : "Continue on Another Account") {
        items(titled: \.displayName)
      }
    } else {
      items {
        HandoverTarget.copiesOnly ? "Copy to \($0.displayName)" : "Continue on \($0.displayName)"
      }
    }
  }

  private func items(titled label: @escaping (Account) -> String) -> some View {
    ForEach(accounts, id: \.id) { account in
      Button(label(account)) {
        SessionResumer.continueElsewhere(row, on: account.id, title: title)
      }
    }
  }
}

/// Resume, asked for by a person: `SessionResume`'s checks, then the terminal.
///
/// The refusals are worded for someone looking at the row. Most cannot be reached from the list,
/// which leaves out live sessions and rows with no transcript, and are here for the seconds
/// between the list being drawn and the button being pressed.
@MainActor
enum SessionResumer {
  static func resume(_ row: UsageSessionRow) {
    let launcher = NewSessionLauncher.shared
    switch SessionResume.prepare(row.sessionID, preferring: row.account, now: Date()) {
    case .ready(let target):
      launcher.start(
        .claude(target.account.folder),
        in: URL(filePath: target.cwd, directoryHint: .isDirectory),
        start: .resume(sessionID: row.sessionID))
    case .refused(let refusal):
      launcher.failure = message(for: refusal)
    }
  }

  /// Continue on another account: Resume's checks, then the live row's handover, which copies
  /// the transcript across and forks it there.
  ///
  /// **The same checks as Resume**, because the one thing a copy of a live transcript risks is
  /// what resuming it risks: something may still be writing it. A fork rather than a resume
  /// under the same id, as for a live row, so the id stays one account's; here it also leaves
  /// the original where it was should its restored VS Code tab be typed into later.
  static func continueElsewhere(_ row: UsageSessionRow, on accountID: String, title: String?) {
    let launcher = NewSessionLauncher.shared
    switch handover(row, on: accountID, title: title) {
    case .ready(let target): launcher.handOver(target)
    case .refused(let reason): launcher.failure = reason
    }
  }

  /// `continueElsewhere`, handing back why it did not go rather than showing it, for a batch
  /// that reports once. Nil once the copy is in place and the launch is under way.
  static func continueElsewhereReporting(
    _ row: UsageSessionRow, on accountID: String, title: String?
  ) -> String? {
    switch handover(row, on: accountID, title: title) {
    case .ready(let target): NewSessionLauncher.shared.handOverReporting(target)
    case .refused(let reason): reason
    }
  }

  private enum Handover {
    case ready(HandoverTarget)
    case refused(String)
  }

  private static func handover(
    _ row: UsageSessionRow, on accountID: String, title: String?
  ) -> Handover {
    switch SessionResume.prepare(row.sessionID, preferring: row.account, now: Date()) {
    case .ready(let source):
      guard let destination = Accounts.shared.account(id: accountID) else {
        return .refused("That account is no longer set up in Armada.")
      }
      // `prepare` falls back to another account's copy when this row's own transcript has gone,
      // which can be the very account asked for.
      guard destination.id != source.account.id else {
        return .refused(
          "This conversation is only on \(destination.displayName) now, so Resume continues it there."
        )
      }
      return .ready(
        HandoverTarget(
          transcript: source.transcript,
          project: URL(filePath: source.cwd, directoryHint: .isDirectory),
          sessionID: row.sessionID, folder: destination.folder,
          accountName: destination.displayName,
          name: SessionBatch.carriedName(title: title, registryName: nil, nameSource: nil)))
    case .refused(let refusal):
      return .refused(message(for: refusal))
    }
  }

  static func message(for refusal: SessionResume.Refusal) -> String {
    switch refusal {
    case .live(let session):
      "\(session.displayName) is open again in \(session.registry.projectName). Resuming it a second time would put two sessions on one conversation; fork it instead."
    case .noTranscript:
      "Its transcript is gone. Claude Code removes old ones, so there is nothing left to resume."
    case .recentWrite(let seconds):
      "This conversation was written to \(seconds) seconds ago, so something may still have it open. Try again in a minute."
    case .noFolder:
      "Its transcript records no folder to resume it in."
    case .notInProject(let cwd):
      "It ran in \((cwd as NSString).abbreviatingWithTildeInPath), which is no longer inside a saved project."
    case .folderGone(let cwd):
      "\((cwd as NSString).abbreviatingWithTildeInPath) is not there any more."
    }
  }
}
