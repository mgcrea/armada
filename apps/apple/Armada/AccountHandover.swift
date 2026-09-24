import SwiftUI

/// A Claude Code session continued on another Claude account.
///
/// **A fork that crosses accounts, and nothing more.** The session's own transcript is copied
/// into the other account (see `TranscriptHandover`), then that account's `claude` opens it
/// with `--resume --fork-session`, the launch `ForkTarget` already makes. The original keeps
/// running, untouched. Resuming under the same id instead would leave one session id live
/// under two accounts, and every lookup Armada makes by id — close, focus, send — assumes an
/// id names one session.
///
/// **Earlier turns stay on the account that paid for them.** The copy repeats their message
/// ids, and `UsageIngest` dedupes on those, first seen wins.
nonisolated struct HandoverTarget: Hashable, Sendable {
  let transcript: URL
  let project: URL
  let sessionID: String
  let folder: ClaudeConfigFolder
  let accountName: String

  var agent: NewSession.Agent { .claude(folder) }
  var start: NewSession.Start { .fork(sessionID: sessionID) }

  /// Settings ▸ General's "without opening a terminal": copy the transcript and stop there.
  ///
  /// For someone who continues in an editor rather than a terminal, switching a window's
  /// account by hand and opening the conversation from Claude Code's own history. That opens
  /// it under the id it already has, not a fork, so the note says to close this one first.
  static let copyOnlyDefaultsKey = "armada.handoverCopyOnly"

  /// Read at the click, like `NewSessionLauncher.terminal`.
  static var copiesOnly: Bool { UserDefaults.standard.bool(forKey: copyOnlyDefaultsKey) }

  var title: String {
    Self.copiesOnly ? "Copy to \(accountName)" : "Continue on \(accountName)"
  }

  var note: String {
    Self.copiesOnly
      ? "Armada copies this conversation to \(accountName) and starts nothing. Open it from Claude Code's past conversations in a window on \(accountName), after closing this session, since it keeps the same session id there. Earlier turns stay counted against this account."
      : "Armada copies this conversation to \(accountName) and opens it there in a terminal, and this session keeps running, untouched. The copy gets a new session id and arrives under \(accountName) as a separate, untitled row. Earlier turns stay counted against this account."
  }
}

/// Where this session can be continued, or why it cannot be.
///
/// The same rules as `ForkAvailability.claude`, for the reason that type gives: three surfaces
/// offer this, and they must not disagree about which rows can.
enum HandoverAvailability {
  case available([HandoverTarget])
  case unavailable(String)
  /// There is no other Claude account. Says nothing, where `unavailable` explains: on a Mac
  /// with one account the action is not missing, it does not exist.
  case noOtherAccount

  var targets: [HandoverTarget] {
    if case .available(let targets) = self { return targets }
    return []
  }

  @MainActor
  static func claude(
    _ session: Session, in account: Account, among accounts: [Account] = Accounts.shared.all
  ) -> HandoverAvailability {
    let others = accounts.filter { $0.id != account.id }
    guard !others.isEmpty else { return .noOtherAccount }
    guard let transcript = session.transcript else {
      return .unavailable(
        "This session has never been prompted, so there is no conversation to continue elsewhere.")
    }
    guard !session.registry.cwd.isEmpty else {
      return .unavailable(
        "This session records no folder, so there is nowhere to continue it.")
    }
    let project = URL(filePath: session.registry.cwd, directoryHint: .isDirectory)
    return .available(
      others.map {
        HandoverTarget(
          transcript: transcript, project: project, sessionID: session.registry.sessionId,
          folder: $0.folder, accountName: $0.displayName)
      })
  }
}

extension NewSessionLauncher {
  /// Copy the conversation across, then start it there.
  ///
  /// `fromMenuBar` for the reason `startFromMenuBar` exists: the popover has no alert, so a
  /// failure opens the main window to be read.
  func handOver(_ target: HandoverTarget, fromMenuBar: Bool = false) {
    do {
      try TranscriptHandover.stage(transcript: target.transcript, into: target.folder.projectsDir)
    } catch {
      failure = Self.handoverFailure(error, to: target)
      if fromMenuBar { AppDelegate.shared?.showMain() }
      return
    }
    if HandoverTarget.copiesOnly { return }
    if fromMenuBar {
      startFromMenuBar(target.agent, in: target.project, start: target.start)
    } else {
      start(target.agent, in: target.project, start: target.start)
    }
  }

  private static func handoverFailure(_ error: Error, to target: HandoverTarget) -> String {
    switch error {
    case TranscriptHandover.Failure.empty:
      return "This session's transcript has no complete turn yet, so there is nothing to copy."
    case TranscriptHandover.Failure.conflict(let url):
      let path = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
      return
        "\(target.accountName) already holds a different conversation under this session's id, at \(path). Armada leaves it alone rather than overwrite it."
    default:
      return
        "Armada could not copy the conversation to \(target.accountName): \(error.localizedDescription)"
    }
  }
}

/// "Continue on <account>", a menu of accounts when there are several, or why neither.
struct HandoverButton: View {
  let availability: HandoverAvailability
  /// Watched here, so the details pane redraws when Settings flips it.
  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var copiesOnly = false

  var body: some View {
    switch availability {
    case .available(let targets):
      if targets.count == 1, let target = targets.first {
        Button {
          NewSessionLauncher.shared.handOver(target)
        } label: {
          Label(target.title, systemImage: "arrow.right.arrow.left")
        }
        Text(target.note)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Menu {
          HandoverMenuItems(targets: targets)
        } label: {
          Label(
            copiesOnly ? "Copy to Another Account" : "Continue on Another Account",
            systemImage: "arrow.right.arrow.left")
        }
        .fixedSize()
        Text(
          copiesOnly
            ? "Armada copies this conversation to the account you pick and starts nothing. Open it from Claude Code's past conversations in a window on that account, after closing this session, since it keeps the same session id there."
            : "Armada copies this conversation to the account you pick and opens it there in a terminal, and this session keeps running, untouched. The copy gets a new session id and arrives under that account as a separate, untitled row."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    case .unavailable(let reason):
      Text(reason)
        .font(.caption)
        .foregroundStyle(.secondary)
    case .noOtherAccount:
      EmptyView()
    }
  }
}

/// The context-menu form: one item per account, inline for one and a submenu for several.
struct HandoverMenuItems: View {
  let targets: [HandoverTarget]
  var fromMenuBar = false
  var onStart: () -> Void = {}

  var body: some View {
    ForEach(targets, id: \.self) { target in
      Button(targets.count == 1 ? target.title : target.accountName) {
        NewSessionLauncher.shared.handOver(target, fromMenuBar: fromMenuBar)
        onStart()
      }
    }
  }
}

/// `HandoverMenuItems` in a context menu: a submenu once there is more than one account.
struct HandoverContextItems: View {
  let targets: [HandoverTarget]
  var fromMenuBar = false
  var onStart: () -> Void = {}

  var body: some View {
    if targets.count > 1 {
      Menu(HandoverTarget.copiesOnly ? "Copy to Another Account" : "Continue on Another Account") {
        HandoverMenuItems(targets: targets, fromMenuBar: fromMenuBar, onStart: onStart)
      }
    } else {
      HandoverMenuItems(targets: targets, fromMenuBar: fromMenuBar, onStart: onStart)
    }
  }
}
