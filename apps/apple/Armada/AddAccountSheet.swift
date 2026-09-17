import SwiftUI

/// "Add Account": a name, then the chosen agent in a terminal on a folder of that name.
///
/// See `NewAccount` for why this is all Armada does. The sheet stays up after the terminal
/// opens and closes itself once the account is in the list, because the folder appearing is
/// the only thing Armada can observe. The sign-in that follows is between the person and the
/// agent.
struct AddAccountSheet: View {
  let vendor: NewAccount.Vendor

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  /// Set once the terminal was asked to open: the path the sheet then waits for.
  @State private var waitingFor: String?
  @State private var failure: String?
  @State private var gaveUp = false

  /// Every agent writes its marker within a second or two of starting. A minute covers a slow
  /// terminal and a first launch; after that the sheet says so rather than spinning forever.
  private static let patience: Duration = .seconds(60)

  private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  private var check: NewAccount.Check {
    NewAccount.check(name, for: vendor, home: home) {
      FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
  }

  private var terminalName: String { NewSessionLauncher.shared.terminal.name }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a \(vendor.name) Account")
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
        "Armada opens \(vendor.name) in \(terminalName) on a new folder. You sign in there, with \(vendor.signInOwner)'s own sign-in. Armada never sees your credentials."
      )
      .fixedSize(horizontal: false, vertical: true)
      TextField("Name", text: $name, prompt: Text("work"))
        .onSubmit(add)
      Group {
        switch check {
        case .empty:
          Text("Each account gets a folder named ~/.\(vendor.folderStem)-<name>.")
        case .refused(let reason):
          Text(reason).foregroundStyle(.red)
        case .ready(let folderName):
          Text("The account will live in ~/\(folderName).")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let failure {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
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

  private func waiting(for path: String) -> some View {
    let shown = (path as NSString).abbreviatingWithTildeInPath
    return VStack(alignment: .leading, spacing: 12) {
      if gaveUp {
        Text(
          "\(vendor.name) has not set up \(shown) yet. If \(terminalName) shows an error, fix it and run \(vendor.name) again there; the account appears as soon as the folder is ready."
        )
        .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Waiting for \(vendor.name) to set up \(shown)…")
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
    .task(id: path) { await wait(for: path) }
  }

  private var isReady: Bool {
    if case .ready = check { return true }
    return false
  }

  private func add() {
    guard case .ready(let folderName) = check else { return }
    let base = NewAccount.base(folderName: folderName, home: home)
    failure = nil

    if vendor.needsFolderCreated {
      do {
        // Owner-only, as Codex keeps its own: the folder will hold `auth.json`.
        try FileManager.default.createDirectory(
          at: base, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } catch {
        failure = "Armada could not create the folder: \(error.localizedDescription)"
        return
      }
    }

    let agent: NewSession.Agent
    let path: String
    switch vendor {
    case .claude:
      let folder = ClaudeConfigFolder(
        base: base, usageJSON: base.appending(path: ".claude.json", directoryHint: .notDirectory))
      (agent, path) = (.claude(folder), folder.path)
    case .codex:
      let codex = CodexHome(base: base)
      (agent, path) = (.codex(codex), codex.path)
    case .grok:
      let grok = GrokHome(base: base)
      (agent, path) = (.grok(grok), grok.path)
    }
    // Before the launch, so the home is found however soon the agent writes its marker.
    if vendor != .claude { AddedHomes.add(path, for: vendor) }

    // In the home folder: there is no project yet, and an agent's question about trusting
    // that folder is an honest one.
    if let message = NewSession.start(
      agent, in: home, terminal: NewSessionLauncher.shared.terminal,
      completion: { message in
        waitingFor = nil
        failure = message
      })
    {
      failure = message
      AddedHomes.remove(path, for: vendor)
      // The empty folder Armada made, so trying again is not refused as already existing.
      // Nothing ran in it: this failure comes before the terminal was asked to open.
      if vendor.needsFolderCreated { try? FileManager.default.removeItem(at: base) }
      return
    }
    waitingFor = path
  }

  /// Poll rather than observe: the tick that would find the folder is thirty seconds away,
  /// and a second is what the person is looking at.
  private func wait(for path: String) async {
    let clock = ContinuousClock()
    let deadline = clock.now + Self.patience
    while !Task.isCancelled {
      if isListed(path) {
        dismiss()
        return
      }
      if clock.now >= deadline { gaveUp = true }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func isListed(_ path: String) -> Bool {
    switch vendor {
    case .claude:
      Accounts.shared.rediscover()
      return Accounts.shared.account(id: path) != nil
    case .codex:
      CodexAccounts.shared.rediscover()
      return CodexAccounts.shared.account(id: path) != nil
    case .grok:
      GrokAccounts.shared.rediscover()
      return GrokAccounts.shared.account(id: path) != nil
    }
  }
}

/// The menu that opens the sheet: one item per agent whose CLI is on this Mac.
///
/// **Installed agents only**, so the menu never offers something that ends in "could not find
/// the command". The lookups are a handful of file checks, made when the menu is drawn.
struct AddAccountMenu<Label: View>: View {
  @Binding var adding: NewAccount.Vendor?
  @ViewBuilder let label: () -> Label

  var body: some View {
    Menu {
      let installed = NewAccount.Vendor.allCases.filter(Self.isInstalled)
      ForEach(installed) { vendor in
        Button("\(vendor.name) Account…") { adding = vendor }
      }
      if installed.isEmpty {
        Text("No Claude Code, Codex or Grok Build command found")
      }
    } label: {
      label()
    }
  }

  static func isInstalled(_ vendor: NewAccount.Vendor) -> Bool {
    switch vendor {
    case .claude: ClaudeControl.executable() != nil
    case .codex: CodexCLI.executable() != nil
    case .grok: GrokControl.executable() != nil
    }
  }
}
