import SwiftUI

/// Moving, continuing or closing the sessions selected in an account's list, several at once,
/// and moving one: a single row's Move goes through here too, so that one session and eight
/// are copied, closed and reported by the same code.
///
/// **What it is for: an account that has run out.** Its sessions have to go to the next one,
/// usually most of them, often across several projects. One at a time that is a copy, a launch
/// and a close per row; here it is one click, one question when something would be stopped
/// part-way, and one sentence afterwards about anything that did not go through.
///
/// **Move is the handover and the close together.** Each conversation is copied and, unless
/// Settings ▸ General says copy only, started on the other account; then only the sessions that
/// made it are closed here. A session whose copy failed stays open, so nothing is ever closed
/// without somewhere to continue it.
///
/// One object for the reason `SessionClosing` is one: the question and the report outlive the
/// context menu that asked for them.
@MainActor
@Observable
final class SessionBatchActions {
  static let shared = SessionBatchActions()

  enum Kind: Equatable {
    case close
    /// To the Claude account with this id.
    case move(to: String)
  }

  /// A batch that would stop turns part-way, until somebody answers.
  struct Pending: Equatable {
    let kind: Kind
    let accountID: String
    let sessionIDs: [String]
    let busy: Int
    let destinationName: String?

    var idle: Int { sessionIDs.count - busy }
  }

  /// What a batch that did not all go through has to say, until it is dismissed.
  struct Report: Equatable {
    let title: String
    let message: String
  }

  var pending: Pending?
  var report: Report?

  private init() {}

  /// Every other Claude account, which is where a session here can go.
  static func destinations(
    from account: Account, among accounts: [Account] = Accounts.shared.all
  ) -> [Account] {
    accounts.filter { $0.id != account.id }
  }

  /// The sessions that can go to another account at all: prompted, and recording a folder.
  static func movable(_ sessions: [Session], in account: Account) -> [Session] {
    sessions.filter { !HandoverAvailability.claude($0, in: account).targets.isEmpty }
  }

  /// Close `sessions`, asking once first when any of them is working.
  func close(_ sessions: [Session], in account: Account) {
    ask(.close, sessions, in: account, destinationName: nil)
  }

  /// Copy `sessions` to `destination`, start them there, and close them here.
  func move(_ sessions: [Session], in account: Account, to destination: Account) {
    ask(.move(to: destination.id), sessions, in: account, destinationName: destination.displayName)
  }

  /// Continue `sessions` on `destination`, or only copy them there, leaving them running here.
  ///
  /// Nothing here is stopped, so nothing is asked.
  func handOver(_ sessions: [Session], in account: Account, to destination: Account) {
    let refusals = sessions.compactMap { handOver($0, in: account, to: destination) }
    let copiesOnly = HandoverTarget.copiesOnly
    show(
      title: copiesOnly ? "Not every session was copied" : "Not every session was continued",
      SessionBatch.report(
        verb: copiesOnly
          ? "copied to \(destination.displayName)" : "continued on \(destination.displayName)",
        attempted: sessions.count, refusals: refusals))
  }

  /// The answer to `pending`: everything, or only what is not working now.
  ///
  /// The sessions are looked up again rather than kept from the question, since some may have
  /// ended while it was on screen, and "working" is read now for the same reason. Without
  /// `force`, one that started a turn since is refused by `SessionCloserBridge` and reported.
  func confirm(skippingBusy: Bool) {
    guard let pending else { return }
    self.pending = nil
    guard let account = Accounts.shared.account(id: pending.accountID) else { return }
    var sessions = account.sessions.sessions.filter { pending.sessionIDs.contains($0.id) }
    if skippingBusy { sessions.removeAll { $0.state.isBusy } }
    run(pending.kind, sessions, in: account, force: !skippingBusy)
  }

  private func ask(
    _ kind: Kind, _ sessions: [Session], in account: Account, destinationName: String?
  ) {
    guard !sessions.isEmpty else { return }
    let busy = sessions.filter(\.state.isBusy).count
    // The rule `SessionClosing.close` follows: an idle session closes without a question,
    // because its conversation is kept and a confirmation would protect nothing.
    guard busy > 0 else { return run(kind, sessions, in: account, force: false) }
    pending = Pending(
      kind: kind, accountID: account.id, sessionIDs: sessions.map(\.id), busy: busy,
      destinationName: destinationName)
  }

  private func run(_ kind: Kind, _ sessions: [Session], in account: Account, force: Bool) {
    guard !sessions.isEmpty else { return }
    switch kind {
    case .close:
      Task {
        let refusals = await SessionClosing.shared.closeAll(sessions, force: force)
        show(
          title: "Not every session closed",
          SessionBatch.report(verb: "closed", attempted: sessions.count, refusals: refusals))
      }
    case .move(let destinationID):
      guard let destination = Accounts.shared.account(id: destinationID) else {
        report = Report(
          title: "Nothing was moved",
          message: "That account is no longer in Armada, so the sessions stay where they are.")
        return
      }
      var refusals: [SessionBatch.Refusal] = []
      var copied: [Session] = []
      for session in sessions {
        if let refusal = handOver(session, in: account, to: destination) {
          refusals.append(refusal)
        } else {
          copied.append(session)
        }
      }
      Task {
        let stillOpen = await SessionClosing.shared.closeAll(copied, force: force)
        refusals += stillOpen.map {
          SessionBatch.Refusal(
            name: $0.name,
            reason: "\($0.name) is on \(destination.displayName) now, and still open here. "
              + $0.reason)
        }
        show(
          title: "Not every session moved",
          SessionBatch.report(
            verb: "moved to \(destination.displayName)", attempted: sessions.count,
            refusals: refusals))
      }
    }
  }

  /// One session's copy and launch, answered with a refusal or nil.
  private func handOver(
    _ session: Session, in account: Account, to destination: Account
  ) -> SessionBatch.Refusal? {
    let availability = HandoverAvailability.claude(session, in: account)
    guard let target = availability.targets.first(where: { $0.folder == destination.folder })
    else {
      let reason =
        if case .unavailable(let reason) = availability { reason } else {
          "Armada could not find \(destination.displayName) to copy it to."
        }
      return SessionBatch.Refusal(name: session.displayName, reason: reason)
    }
    return NewSessionLauncher.shared.handOverReporting(target).map {
      SessionBatch.Refusal(name: session.displayName, reason: $0)
    }
  }

  private func show(title: String, _ message: String?) {
    guard let message else { return }
    report = Report(title: title, message: message)
  }
}

extension View {
  /// The question before a batch stops turns part-way, and the report after one that did not
  /// all go through, attached once per pane.
  func sessionBatchAlerts() -> some View {
    modifier(SessionBatchAlerts())
  }
}

private struct SessionBatchAlerts: ViewModifier {
  @State private var batch = SessionBatchActions.shared

  func body(content: Content) -> some View {
    let pending = batch.pending
    content
      .alert(
        title(for: pending),
        isPresented: Binding(
          get: { batch.pending != nil },
          set: { if !$0 { batch.pending = nil } })
      ) {
        if let pending {
          Button(allLabel(for: pending), role: .destructive) {
            batch.confirm(skippingBusy: false)
          }
          // Absent when every one of them is working: there would be nothing left to do.
          if pending.idle > 0 {
            Button("Skip the Working Ones") { batch.confirm(skippingBusy: true) }
          }
        }
        Button("Cancel", role: .cancel) { batch.pending = nil }
      } message: {
        Text(pending.map(message(for:)) ?? "")
      }
      .alert(
        batch.report?.title ?? "",
        isPresented: Binding(
          get: { batch.report != nil },
          set: { if !$0 { batch.report = nil } })
      ) {
        Button("OK") { batch.report = nil }
      } message: {
        Text(batch.report?.message ?? "")
      }
  }

  private func title(for pending: SessionBatchActions.Pending?) -> String {
    guard let pending else { return "" }
    let sessions =
      pending.sessionIDs.count == 1
      ? "This Session" : SessionBatch.sessions(pending.sessionIDs.count)
    switch pending.kind {
    case .close: return "Close \(sessions)?"
    case .move: return "Move \(sessions) to \(pending.destinationName ?? "the other account")?"
    }
  }

  private func allLabel(for pending: SessionBatchActions.Pending) -> String {
    let verb = pending.kind == .close ? "Close" : "Move"
    return pending.sessionIDs.count == 1 ? verb : "\(verb) All \(pending.sessionIDs.count)"
  }

  private func message(for pending: SessionBatchActions.Pending) -> String {
    let working =
      pending.sessionIDs.count == 1
      ? "It is working"
      : pending.busy == 1 ? "One of them is working" : "\(pending.busy) of them are working"
    switch pending.kind {
    case .close:
      return
        "\(working). Closing stops a turn part-way. The conversations are kept, so they can be resumed."
    case .move:
      return
        "\(working). Moving copies each conversation as it stands now and then closes it here, so a turn in progress stops part-way and its copy ends before it."
    }
  }
}

/// The detail pane with more than one session selected: what they add up to, and what can be
/// done to all of them.
struct SessionSelectionDetail: View {
  let sessions: [Session]
  let account: Account

  @State private var batch = SessionBatchActions.shared
  @State private var closing = SessionClosing.shared
  /// Watched here, so the labels change when Settings flips it.
  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var copiesOnly = false

  var body: some View {
    Form {
      Section {
        handoverActions
        closeAction
      } header: {
        Text("\(SessionBatch.sessions(sessions.count)) selected")
      }
      SessionTallySection(sessions: sessions, empty: "") { key in
        StateDot(state: SessionState(rawValue: key) ?? .idle)
      }
      Section("Selected") {
        ForEach(sessions) { session in
          HStack(spacing: 8) {
            StateDot(state: session.state)
            Text(session.displayName).lineLimit(1)
            Spacer(minLength: 8)
            Text(session.registry.projectName)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var handoverActions: some View {
    let destinations = SessionBatchActions.destinations(from: account)
    let movable = SessionBatchActions.movable(sessions, in: account)
    // With one Claude account there is nowhere to go, and the action does not exist rather
    // than being missing: the same rule `HandoverAvailability.noOtherAccount` states.
    if !destinations.isEmpty {
      if movable.isEmpty {
        Text(
          "None of these can go to another account: each has never been prompted, or records no folder."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        let count = movable.count
        let noun = SessionBatch.noun(count)
        if destinations.count == 1, let destination = destinations.first {
          Button {
            batch.move(movable, in: account, to: destination)
          } label: {
            Label("Move \(count) \(noun) to \(destination.displayName)", systemImage: "arrow.right")
          }
          Button {
            batch.handOver(movable, in: account, to: destination)
          } label: {
            Label(
              copiesOnly
                ? "Copy \(count) \(noun) to \(destination.displayName)"
                : "Continue \(count) \(noun) on \(destination.displayName)",
              systemImage: "arrow.right.arrow.left")
          }
        } else {
          Menu {
            ForEach(destinations) { destination in
              Button(destination.displayName) {
                batch.move(movable, in: account, to: destination)
              }
            }
          } label: {
            Label("Move \(count) \(noun) to Another Account", systemImage: "arrow.right")
          }
          .fixedSize()
          Menu {
            ForEach(destinations) { destination in
              Button(destination.displayName) {
                batch.handOver(movable, in: account, to: destination)
              }
            }
          } label: {
            Label(
              copiesOnly
                ? "Copy \(count) \(noun) to Another Account"
                : "Continue \(count) \(noun) on Another Account",
              systemImage: "arrow.right.arrow.left")
          }
          .fixedSize()
        }
        Text(caption(to: destinations.count == 1 ? destinations[0].displayName : nil))
          .font(.caption)
          .foregroundStyle(.secondary)
        if count < sessions.count {
          let left = sessions.count - count
          Text(
            "\(left == 1 ? "One of these has" : "\(left) of these have") never been prompted or record no folder, so there is nothing to copy. \(left == 1 ? "It stays" : "They stay") here."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func caption(to destination: String?) -> String {
    let there = destination ?? "the account you pick"
    return copiesOnly
      ? "Move copies each conversation to \(there) and closes it here, and starts nothing. Open them from Claude Code's past conversations in a window on \(there), where each keeps its session id. Copy does the same and leaves these running. Earlier turns stay counted against this account."
      : "Move copies each conversation to \(there), opens it there in a terminal and then closes it here. Continue does the same and leaves these running. Each copy gets a new session id and keeps its name when it has one. Earlier turns stay counted against this account."
  }

  @ViewBuilder private var closeAction: some View {
    let isClosing = sessions.contains { closing.inFlight.contains($0.id) }
    Button(role: .destructive) {
      batch.close(sessions, in: account)
    } label: {
      Label(
        isClosing ? "Closing…" : "Close \(sessions.count) \(SessionBatch.noun(sessions.count))",
        systemImage: "xmark.circle")
    }
    .disabled(isClosing)
    Text(
      "Quits each session's Claude Code, as quitting it in its terminal would. The conversations are kept. Armada asks first when any of them is working."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

/// The context menu for more than one selected row.
struct SessionBatchContextItems: View {
  let sessions: [Session]
  let account: Account

  var body: some View {
    let batch = SessionBatchActions.shared
    let destinations = SessionBatchActions.destinations(from: account)
    let movable = SessionBatchActions.movable(sessions, in: account)
    let count = movable.count
    let noun = SessionBatch.noun(count)
    let copiesOnly = HandoverTarget.copiesOnly
    if !destinations.isEmpty, !movable.isEmpty {
      if destinations.count == 1, let destination = destinations.first {
        Button("Move \(count) \(noun) to \(destination.displayName)") {
          batch.move(movable, in: account, to: destination)
        }
        Button(
          copiesOnly
            ? "Copy \(count) \(noun) to \(destination.displayName)"
            : "Continue \(count) \(noun) on \(destination.displayName)"
        ) {
          batch.handOver(movable, in: account, to: destination)
        }
      } else {
        Menu("Move \(count) \(noun) to") {
          ForEach(destinations) { destination in
            Button(destination.displayName) { batch.move(movable, in: account, to: destination) }
          }
        }
        Menu(copiesOnly ? "Copy \(count) \(noun) to" : "Continue \(count) \(noun) on") {
          ForEach(destinations) { destination in
            Button(destination.displayName) {
              batch.handOver(movable, in: account, to: destination)
            }
          }
        }
      }
    }
    // Last and fenced off, as in the single-row menu: the one item that ends something.
    Divider()
    Button("Close \(sessions.count) \(SessionBatch.noun(sessions.count))") {
      batch.close(sessions, in: account)
    }
  }
}

/// "Move to <account>", or a menu of accounts when there are several, for one session: the
/// batch's Move with a single row in it, beside the details' Continue on.
///
/// Nothing when the session cannot be handed over at all. `HandoverButton`, right below it,
/// already says why, and saying it twice would be noise.
struct MoveSessionButton: View {
  let session: Session
  let account: Account

  @State private var closing = SessionClosing.shared
  /// Watched here, so the caption changes when Settings flips it.
  @AppStorage(HandoverTarget.copyOnlyDefaultsKey) private var copiesOnly = false

  var body: some View {
    let destinations = SessionBatchActions.destinations(from: account)
    let movable = !SessionBatchActions.movable([session], in: account).isEmpty
    if !destinations.isEmpty, movable {
      let isClosing = closing.inFlight.contains(session.id)
      if destinations.count == 1, let destination = destinations.first {
        Button {
          SessionBatchActions.shared.move([session], in: account, to: destination)
        } label: {
          Label("Move to \(destination.displayName)", systemImage: "arrow.right")
        }
        .disabled(isClosing)
      } else {
        Menu {
          ForEach(destinations) { destination in
            Button(destination.displayName) {
              SessionBatchActions.shared.move([session], in: account, to: destination)
            }
          }
        } label: {
          Label("Move to Another Account", systemImage: "arrow.right")
        }
        .fixedSize()
        .disabled(isClosing)
      }
      Text(caption(to: destinations.count == 1 ? destinations[0].displayName : nil))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func caption(to destination: String?) -> String {
    let there = destination ?? "the account you pick"
    return copiesOnly
      ? "Armada copies this conversation to \(there) and closes it here, and starts nothing. Open it from Claude Code's past conversations in a window on \(there), where it keeps its session id. Earlier turns stay counted against this account."
      : "Armada copies this conversation to \(there), opens it there in a terminal and then closes it here. The copy gets a new session id. Earlier turns stay counted against this account."
  }
}

/// The single-row context menu's Move: inline for one other account, a submenu for several,
/// as `HandoverContextItems` does for Continue on.
struct MoveContextItems: View {
  let session: Session
  let account: Account

  var body: some View {
    let destinations = SessionBatchActions.destinations(from: account)
    if !destinations.isEmpty, !SessionBatchActions.movable([session], in: account).isEmpty {
      if destinations.count == 1, let destination = destinations.first {
        Button("Move to \(destination.displayName)") {
          SessionBatchActions.shared.move([session], in: account, to: destination)
        }
      } else {
        Menu("Move to Another Account") {
          ForEach(destinations) { destination in
            Button(destination.displayName) {
              SessionBatchActions.shared.move([session], in: account, to: destination)
            }
          }
        }
      }
    }
  }
}
