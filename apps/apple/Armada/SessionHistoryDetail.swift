import SwiftUI

/// One History session beside the list: which conversation it was, and what can be done with it.
///
/// **The last reply leads**, above the folder and the times. A title is often missing or
/// generic ("Session 3d34535a", "App review"), and what tells two sessions in one project apart
/// is where each of them stopped: "The iOS work is on `main`: 22 commits…".
///
/// **Resume and Continue are greyed out outside a saved project**, rather than offered and then
/// refused: `SessionResume` keeps a resumed session inside a project, as a fresh one is, and the
/// note says which folder to add.
struct SessionHistoryDetail: View {
  let entry: SessionHistoryModel.Entry

  @State private var accounts = Accounts.shared
  @State private var store = ProjectStore.shared
  @State private var reply: String?
  @State private var didReadReply = false
  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var copiesOnly = false

  /// How much of the transcript's tail is read for the last reply. More than a title's 64KB,
  /// because a turn that ended in a long tool result can push the reply above that.
  nonisolated static let replyBytes = 512 * 1024
  /// Enough to recognise the conversation by, not to read it; Read Transcript is for that.
  nonisolated static let replyCap = 1_200

  var body: some View {
    let project = store.project(containing: entry.row.cwd)
    Form {
      Section {
        if let reply {
          Text(reply)
            .textSelection(.enabled)
            .lineLimit(12)
        } else if didReadReply {
          Text("No reply in the last part of this transcript.")
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
            .controlSize(.small)
        }
      } header: {
        Text(entry.displayName)
      } footer: {
        Text("The last thing the agent said in this session.")
      }

      Section {
        Button {
          SessionResumer.resume(entry.row)
        } label: {
          Label("Resume", systemImage: "play")
        }
        .disabled(project == nil)
        continueActions(disabled: project == nil)
        Button {
          TranscriptWindow.shared.show(url: entry.transcript, name: entry.displayName)
        } label: {
          Label("Read Transcript", systemImage: "text.alignleft")
        }
        if project == nil {
          Text(
            "It ran in \(folder), which is not inside a saved project, so it cannot be resumed from here. Add the folder as a project first."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text(
            "Resume continues it on \(accountName) in a terminal, under the id it has. Continuing on another account copies it there first and gives the copy an id of its own."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Session") {
        LabeledContent("Project", value: project?.displayName ?? "Not in a saved project")
        LabeledContent("Folder", value: folder)
          .lineLimit(3)
          .truncationMode(.head)
        LabeledContent("Account", value: accountName)
        LabeledContent("Started") {
          Text(entry.row.firstAt, format: .dateTime.weekday().day().month().hour().minute())
        }
        LabeledContent("Last active") {
          Text(entry.row.lastAt, format: .dateTime.weekday().day().month().hour().minute())
        }
      }
    }
    .formStyle(.grouped)
    .task(id: entry.transcript) {
      didReadReply = false
      reply = nil
      let transcript = entry.transcript
      let read = await Task.detached(priority: .userInitiated) {
        Self.lastReply(of: transcript)
      }.value
      guard !Task.isCancelled else { return }
      reply = read
      didReadReply = true
    }
    #if DEBUG
      // The History plate waits for both things it shows that are read off the main actor:
      // this reply, and the rows' titles, which land in one batch with this row's.
      .onChange(of: didReadReply && entry.title != nil, initial: true) { _, ready in
        if ready { DemoSeed.signalReady(from: .history) }
      }
    #endif
  }

  @ViewBuilder private func continueActions(disabled: Bool) -> some View {
    let destinations = accounts.all.filter { $0.id != entry.row.account }
    if destinations.count == 1, let destination = destinations.first {
      Button {
        SessionResumer.continueElsewhere(entry.row, on: destination.id, title: entry.title)
      } label: {
        Label(
          copiesOnly
            ? "Copy to \(destination.displayName)" : "Continue on \(destination.displayName)",
          systemImage: "arrow.right.arrow.left")
      }
      .disabled(disabled)
    } else if destinations.count > 1 {
      Menu {
        ForEach(destinations, id: \.id) { destination in
          Button(destination.displayName) {
            SessionResumer.continueElsewhere(entry.row, on: destination.id, title: entry.title)
          }
        }
      } label: {
        Label(
          copiesOnly ? "Copy to Another Account" : "Continue on Another Account",
          systemImage: "arrow.right.arrow.left")
      }
      .fixedSize()
      .disabled(disabled)
    }
  }

  private var folder: String {
    (entry.row.cwd as NSString).abbreviatingWithTildeInPath
  }

  private var accountName: String {
    accounts.account(id: entry.row.account)?.displayName ?? entry.row.account
  }

  /// The newest assistant text in the transcript's tail, cut to `replyCap`.
  nonisolated static func lastReply(of transcript: URL) -> String? {
    let options = TranscriptLog.Options(includeThinking: false, cap: replyCap)
    guard let entries = TranscriptLog.tail(of: transcript, bytes: replyBytes, options: options)
    else { return nil }
    guard
      let last = entries.last(where: {
        $0.kind == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { return nil }
    return last.truncated ? last.text + "…" : last.text
  }
}

/// Several History sessions selected: how many, where they can go, and which they are.
struct SessionHistorySelectionDetail: View {
  let entries: [SessionHistoryModel.Entry]

  @State private var accounts = Accounts.shared
  @State private var store = ProjectStore.shared

  var body: some View {
    let destinations = SessionHistoryBatch.destinations(for: entries, among: accounts.all)
    Form {
      Section {
        if destinations.isEmpty {
          Text("There is no other Claude account to continue these on.")
            .foregroundStyle(.secondary)
        } else {
          SessionHistoryBatchItems(entries: entries, destinations: destinations)
          Text(
            "Each one is copied to the account you pick and opened there in a terminal, with an id of its own. One that ran outside a saved project stays where it is, and is named afterwards."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      } header: {
        Text("\(SessionBatch.sessions(entries.count)) selected")
      }
      Section("Selected") {
        ForEach(entries) { entry in
          HStack(spacing: 8) {
            Text(entry.displayName).lineLimit(1)
            Spacer(minLength: 8)
            Text(SessionHistoryFolder.label(for: entry.row.cwd, in: store))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}
