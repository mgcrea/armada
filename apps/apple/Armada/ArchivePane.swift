import SwiftUI

/// Settings ▸ Archive: where copies go, which accounts send them, and how long they stay.
///
/// **Every account is listed here as well as on its own overview**, because this is where
/// somebody setting the archive up for the first time is looking, and the overview is where
/// they notice an account is left out.
struct ArchivePane: View {
  @State private var archiver = TranscriptArchiver.shared
  @State private var accounts = Accounts.shared
  @State private var codex = CodexAccounts.shared
  @State private var pendingRetention: Int?

  var body: some View {
    Form {
      Section {
        if let path = archiver.displayRoot {
          LabeledContent("Folder") {
            HStack(spacing: 6) {
              Text(path)
                .truncationMode(.head)
                .lineLimit(1)
              Button {
                archiver.showInFinder()
              } label: {
                Image(systemName: "arrow.up.forward.square")
              }
              .buttonStyle(.borderless)
              .help("Show in Finder")
            }
          }
          ArchiveStatusRow(archiver: archiver)
          HStack {
            Button("Change Folder…") { archiver.chooseFolder() }
            Button("Copy Now") { archiver.requestPass() }
              .disabled(!archiver.isOn || archiver.status == .copying)
            Spacer()
            Button("Stop Archiving", role: .destructive) { archiver.forgetFolder() }
          }
        } else {
          Button("Choose Folder…") { archiver.chooseFolder() }
        }
      } header: {
        Text("Destination")
      } footer: {
        Text(
          "Pick a folder on a NAS, an external disk or anywhere else you keep backups. Armada writes copies there and nowhere else. It never mounts a share or sends anything over the network itself, so the copies go as far as the folder you picked does."
        )
      }

      Section {
        if accounts.all.isEmpty && codex.all.isEmpty {
          Text("No Claude Code or Codex accounts found yet.").foregroundStyle(.secondary)
        }
        ForEach(accounts.all) { account in
          Toggle(isOn: binding(account.id)) {
            VStack(alignment: .leading, spacing: 1) {
              Text(account.displayName)
              Text(account.displayPath).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        ForEach(codex.all) { account in
          Toggle(isOn: binding(account.id)) {
            VStack(alignment: .leading, spacing: 1) {
              Text(account.displayName)
              Text(account.displayPath).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        Text("Accounts")
      } footer: {
        Text(
          "Claude Code accounts copy everything under projects/, which is every transcript, its subagents and tool results, and the auto memory. Codex homes copy their session rollouts. The first copy includes everything still on this Mac, and Claude Code keeps transcripts for 30 days unless its cleanupPeriodDays setting says otherwise."
        )
      }

      Section {
        Picker("Keep copies", selection: retentionBinding) {
          ForEach(TranscriptArchiver.retentionChoices, id: \.self) { days in
            Text(Self.retentionLabel(days)).tag(days)
          }
        }
      } header: {
        Text("Retention")
      } footer: {
        Text(
          "A copy is deleted once its session has not written for longer than this, and older transcripts are not copied. Applies to every account in the archive, including ones switched off. Kept forever, nothing is ever deleted: a transcript Claude Code removes from this Mac keeps its copy."
        )
      }

      Section {
        Text(
          "Transcripts hold everything the agent saw: file contents, command output, and any key or password that went past it. The archive keeps them exactly as written, so keep the folder somewhere only you can read."
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("What is in a transcript")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Archive")
    .alert(
      "Delete older copies?",
      isPresented: Binding(
        get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
      presenting: pendingRetention
    ) { days in
      Button("Delete Older Copies", role: .destructive) {
        archiver.setRetention(days)
        pendingRetention = nil
      }
      Button("Cancel", role: .cancel) { pendingRetention = nil }
    } message: { days in
      Text(
        "Copies whose session last wrote more than \(Self.retentionLabel(days).lowercased()) ago will be deleted from the archive on the next pass. This cannot be undone."
      )
    }
  }

  private func binding(_ account: String) -> Binding<Bool> {
    Binding(
      get: { archiver.isEnabled(account) },
      set: { archiver.setEnabled($0, account: account) })
  }

  /// Shortening the period deletes copies, so that one direction asks first.
  private var retentionBinding: Binding<Int> {
    Binding(
      get: { archiver.retentionDays },
      set: { days in
        let current = archiver.retentionDays
        let shortens = days > 0 && (current == 0 || days < current)
        if shortens && archiver.target != nil {
          pendingRetention = days
        } else {
          archiver.setRetention(days)
        }
      })
  }

  static func retentionLabel(_ days: Int) -> String {
    switch days {
    case 0: "Forever"
    case 365: "1 year"
    case let days where days % 365 == 0: "\(days / 365) years"
    default: "\(days) days"
    }
  }
}

/// What the last pass did, or why none ran.
struct ArchiveStatusRow: View {
  let archiver: TranscriptArchiver

  var body: some View {
    LabeledContent("Status") {
      switch archiver.status {
      case .copying:
        if let progress = archiver.progress, progress.total > 0 {
          Text("Copying, \(progress.done.formatted()) of \(progress.total.formatted()) files")
        } else {
          Text("Copying…")
        }
      case .unavailable:
        Text("Folder not available. Is the disk or share mounted?")
          .foregroundStyle(.orange)
      case .failed(let message):
        Text(message)
          .foregroundStyle(.red)
          .lineLimit(2)
          .truncationMode(.middle)
          .help(message)
      case .idle:
        if !archiver.isOn {
          Text("Off. Switch on an account to start.").foregroundStyle(.secondary)
        } else if let date = archiver.lastSuccessAt {
          Text("Up to date as of \(date.formatted(date: .omitted, time: .shortened))\(summary)")
        } else {
          Text("Waiting for the first pass").foregroundStyle(.secondary)
        }
      }
    }
  }

  /// What the last pass wrote, when it wrote anything.
  private var summary: String {
    guard let report = archiver.lastReport, report.bytesWritten > 0 || report.filesPruned > 0
    else { return "" }
    var parts: [String] = []
    if report.bytesWritten > 0 {
      parts.append(
        "\(ByteCountFormatter.string(fromByteCount: report.bytesWritten, countStyle: .file)) written"
      )
    }
    if report.filesPruned > 0 { parts.append("\(report.filesPruned.formatted()) removed") }
    return ", " + parts.joined(separator: ", ")
  }
}

/// An account's switch, on its overview.
struct ArchiveSection: View {
  let account: String

  @State private var archiver = TranscriptArchiver.shared

  var body: some View {
    Section {
      Toggle(
        "Copy transcripts to the archive",
        isOn: Binding(
          get: { archiver.isEnabled(account) },
          set: { archiver.setEnabled($0, account: account) }))
      if archiver.isEnabled(account) {
        ArchiveStatusRow(archiver: archiver)
      }
    } header: {
      Text("Archive")
    } footer: {
      if let path = archiver.displayRoot {
        Text("Copies go to \(path). Settings ▸ Archive sets the folder and how long copies stay.")
      } else {
        Text("Keeps copies in a folder you choose, such as on a NAS, after this Mac deletes them.")
      }
    }
  }
}
