import ArmadaMCP
import SwiftUI

/// Closing a session from Armada's own windows, and saying so when it does not close.
///
/// **The same door an agent uses.** `SessionCloserBridge` finds the session again, ties the pid
/// to it by start time and sends the signal; this adds only what a person needs in front of
/// that: a question before a turn is stopped part-way, and somewhere for a refusal to be read.
///
/// One object for the reason `NewSessionLauncher` is one: a context menu is gone by the time
/// the answer comes back, up to `killGrace` later, so it lands here and whichever pane is on
/// screen shows it.
@MainActor
@Observable
final class SessionClosing {
  static let shared = SessionClosing()

  /// A busy session somebody asked to close, until they answer.
  struct Pending: Equatable {
    let sessionID: String
    let name: String
    let state: SessionState
  }

  var pending: Pending?
  /// The last refusal, until it is dismissed.
  var failure: String?
  /// Sessions signalled and not yet answered for, so their button cannot be pressed twice.
  private(set) var inFlight: Set<String> = []

  private init() {}

  /// Close `session`, asking first when that would stop a turn.
  ///
  /// **Idle and waiting sessions go without a question**, as they do for an agent: the
  /// transcript stays and the session can be resumed, so a confirmation there would be a
  /// second click that protects nothing.
  ///
  /// From the menu bar the session is opened in the main window first. The popover has no
  /// alert of its own and closes as soon as something else is key, and the row behind the
  /// question is the right thing to be looking at while answering it.
  func close(_ session: Session, in account: Account, fromMenuBar: Bool = false) {
    guard !inFlight.contains(session.id) else { return }
    if session.state.isBusy {
      if fromMenuBar { MainWindowRoute.shared.open(.account(account.id), session: session.id) }
      pending = Pending(sessionID: session.id, name: session.displayName, state: session.state)
    } else {
      send(session.id, name: session.displayName, force: false, fromMenuBar: fromMenuBar)
    }
  }

  func confirm() {
    guard let pending else { return }
    self.pending = nil
    send(pending.sessionID, name: pending.name, force: true, fromMenuBar: false)
  }

  private func send(_ sessionID: String, name: String, force: Bool, fromMenuBar: Bool) {
    inFlight.insert(sessionID)
    Task {
      let outcome = await SessionCloserBridge.close(
        CloseSessionRequest(sessionID: sessionID, force: force), origin: .person)
      inFlight.remove(sessionID)
      switch outcome {
      case .closed(let closed) where !closed.exited:
        report(
          "\(name) was sent a quit and then killed, and its process is still there. It is "
            + "probably stuck on a disk or the network, and will go when that lets it.",
          fromMenuBar: fromMenuBar)
      case .closed:
        // Nothing to say: the row leaves the list when the registry file does.
        break
      case .refused(let message):
        report(message, fromMenuBar: fromMenuBar)
      }
    }
  }

  private func report(_ message: String, fromMenuBar: Bool) {
    failure = message
    if fromMenuBar { AppDelegate.shared?.showMain() }
  }
}

extension View {
  /// The question before a busy session is closed and the alert for one that was not, attached
  /// once per pane.
  func sessionClosingAlerts() -> some View {
    modifier(SessionClosingAlerts())
  }
}

private struct SessionClosingAlerts: ViewModifier {
  @State private var closing = SessionClosing.shared

  func body(content: Content) -> some View {
    content
      .alert(
        "Close \(closing.pending?.name ?? "this session")?",
        isPresented: Binding(
          get: { closing.pending != nil },
          set: { if !$0 { closing.pending = nil } })
      ) {
        Button("Close Session", role: .destructive) { closing.confirm() }
        Button("Cancel", role: .cancel) { closing.pending = nil }
      } message: {
        Text(
          closing.pending?.state == .runningTool
            ? "It is probably running a tool. Closing stops the turn part-way and ends the command it is running. The conversation is kept, so it can be resumed."
            : "It is working. Closing stops the turn part-way. The conversation is kept, so it can be resumed."
        )
      }
      .alert(
        "Could not close the session",
        isPresented: Binding(
          get: { closing.failure != nil },
          set: { if !$0 { closing.failure = nil } })
      ) {
        Button("OK") { closing.failure = nil }
      } message: {
        Text(closing.failure ?? "")
      }
  }
}

/// "Close Session", last in the detail's actions because it is the one that ends something.
///
/// **"Close" is the word the tool already uses** (`armada_close_session`), and the honest one:
/// the process ends and the conversation does not. "Kill" would describe the fallback rather
/// than the method, and "End" reads as ending the conversation, which resume disproves.
struct CloseSessionButton: View {
  let session: Session
  let account: Account

  @State private var closing = SessionClosing.shared

  var body: some View {
    let isClosing = closing.inFlight.contains(session.id)
    Button(role: .destructive) {
      closing.close(session, in: account)
    } label: {
      Label(isClosing ? "Closing…" : "Close Session", systemImage: "xmark.circle")
    }
    .disabled(isClosing)
    Text(
      "Quits this session's Claude Code, as quitting it in its terminal would. The conversation is kept, and one in a saved project can be resumed from there."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
