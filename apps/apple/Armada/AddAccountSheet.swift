import SwiftUI

/// "Add Account…": a name, then Claude Code in a terminal on a folder of that name.
///
/// See `NewAccount` for why this is all Armada does. The sheet stays up after the terminal
/// opens and closes itself once the account is in the list, because the folder appearing is
/// the only thing Armada can observe. The sign-in that follows is between the person and
/// Claude Code, and the row shows the organization's name once `.claude.json` records it.
struct AddAccountSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var accounts = Accounts.shared
  @State private var name = ""
  /// Set once the terminal was asked to open, and what the sheet then waits for.
  @State private var waitingFor: ClaudeConfigFolder?
  @State private var failure: String?
  @State private var gaveUp = false

  /// Claude Code creates `sessions/` about a second after it starts. A minute covers a slow
  /// terminal and a first launch; after that the sheet says so rather than spinning forever.
  private static let patience: Duration = .seconds(60)

  private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  private var check: NewAccount.Check {
    NewAccount.check(name, home: home) {
      FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
  }

  private var terminalName: String { NewSessionLauncher.shared.terminal.name }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a Claude Account")
        .font(.headline)
      if let waitingFor {
        waiting(for: waitingFor)
      } else {
        form
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Armada opens Claude Code in \(terminalName) on a new config folder. You sign in there, with Anthropic's own sign-in. Armada never sees your credentials."
      )
      .fixedSize(horizontal: false, vertical: true)
      TextField("Name", text: $name, prompt: Text("work"))
        .onSubmit(add)
      Group {
        switch check {
        case .empty:
          Text("Each account gets a folder named ~/.claude-<name>.")
        case .refused(let reason):
          Text(reason).foregroundStyle(.red)
        case .ready(let folderName):
          Text("Claude Code will create ~/\(folderName).")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.red).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Open \(terminalName)", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(!isReady)
      }
    }
  }

  private func waiting(for folder: ClaudeConfigFolder) -> some View {
    let path = (folder.path as NSString).abbreviatingWithTildeInPath
    return VStack(alignment: .leading, spacing: 12) {
      if gaveUp {
        Text(
          "Claude Code has not created \(path) yet. If \(terminalName) shows an error, fix it and run Claude Code again there; the account appears as soon as the folder does."
        )
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Waiting for Claude Code to create \(path)…")
        }
      }
      Text(
        "Sign in from \(terminalName). Until you do, the account shows no plan and no limits."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .task(id: folder.path) { await wait(for: folder) }
  }

  private var isReady: Bool {
    if case .ready = check { return true }
    return false
  }

  private func add() {
    guard case .ready(let folderName) = check else { return }
    let base = NewAccount.base(folderName: folderName, home: home)
    let folder = ClaudeConfigFolder(
      base: base, usageJSON: base.appending(path: ".claude.json", directoryHint: .notDirectory))
    failure = nil
    // In the home folder: there is no project yet, and Claude Code's folder trust question
    // there is an honest one.
    if let message = NewSession.start(
      .claude(folder), in: home, terminal: NewSessionLauncher.shared.terminal,
      completion: { message in
        waitingFor = nil
        failure = message
      })
    {
      failure = message
      return
    }
    waitingFor = folder
  }

  /// Poll rather than observe: the tick that would find the folder is thirty seconds away,
  /// and a second is what the person is looking at.
  private func wait(for folder: ClaudeConfigFolder) async {
    let clock = ContinuousClock()
    let deadline = clock.now + Self.patience
    while !Task.isCancelled {
      accounts.rediscover()
      if accounts.account(id: folder.path) != nil {
        dismiss()
        return
      }
      if clock.now >= deadline { gaveUp = true }
      try? await Task.sleep(for: .seconds(1))
    }
  }
}
