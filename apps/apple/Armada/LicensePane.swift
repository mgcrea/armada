import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LicenseLinks {
  /// Where to buy one. The site's own vanity path rather than the Stripe checkout
  /// URL, so the destination can move without shipping a new build — see
  /// `apps/website/public/_redirects`. A Stripe URL compiled into a binary would
  /// be a payment link nobody could ever repoint.
  static let buy = URL(string: "https://armada.mgcrea.io/buy")!

  /// Whether /buy resolves to a live payment link.
  ///
  /// The same flag, for the same reason, as `SHIPPED` on the website — a button
  /// here is a promise that there is something on the other end of it. The two
  /// move together, and this one is the slower half: the site can be redeployed
  /// in a minute, while a build that has shipped carries whatever it was compiled
  /// with until the next release. Every buy button in the app is gated on it.
  static let isSelling = false
}

/// Entering a licence key, seeing what happened to it, and — when there is none —
/// finding out what that actually means.
///
/// A Settings pane rather than a window of its own, as in both siblings. A key is
/// 240 characters that arrive by paste or by drop from a mail client, so it needs
/// somewhere with room and somewhere that survives losing focus.
///
/// Bastion's pane, copied, with the explanation rewritten for what Armada's gate
/// actually does.
struct LicensePane: View {
  @State private var entry = ""
  @State private var problem: String?
  private var monitor = EntitlementMonitor.shared

  var body: some View {
    Form {
      Section {
        status
      } footer: {
        footer
      }

      Section {
        editor
      } header: {
        Text("Licence key")
      } footer: {
        Text("Paste your key, or drop the .license file anywhere in this window.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Licence")
    .onAppear { entry = LicenseStore.raw ?? "" }
    .onDrop(of: [.fileURL], isTargeted: nil, perform: accept)
  }

  private var status: some View {
    // On a schedule, because one of the three states is a countdown. A pane left
    // open across the end of a trial window has to stop claiming Armada is
    // watching — the monitor will already have stopped it. Fifteen seconds is
    // comfortably inside the minute the label rounds to.
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      // Read once. The badge and the words beside it are two renderings of one
      // answer, and a trial that ended between two reads would have them
      // contradict each other.
      let entitlement = monitor.current

      HStack(alignment: .top, spacing: 14) {
        badge(for: entitlement)

        VStack(alignment: .leading, spacing: 4) {
          switch entitlement {
          case .licensed(let license):
            Text("Licensed to \(license.email)").foregroundStyle(.green)
            Text(
              "Licence \(license.id) · covers \(license.major).x · issued \(day(license.issuedAt))"
            )
            .font(.caption).foregroundStyle(.secondary)
          case .trial:
            Text("Trial · \(Trial.remainingText)").foregroundStyle(.blue)
            trialExplanation
          case .refused(let reason):
            Text("Unlicensed").foregroundStyle(.orange)
            Text(reason)
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            explanation
            trialOffer
          }
        }
      }
    }
    .textSelection(.enabled)
  }

  /// The glyph, alone in a column to the left of everything the state has to say.
  /// Fixed width, because a triangle is narrower than a seal and without it every
  /// sentence in the block would shift sideways the moment a trial ended.
  private func badge(for entitlement: Entitlement) -> some View {
    let (symbol, tint): (String, Color) =
      switch entitlement {
      case .licensed: ("checkmark.seal.fill", .green)
      case .trial: ("clock.fill", .blue)
      case .refused: ("exclamationmark.triangle.fill", .orange)
      }

    return Image(systemName: symbol)
      .font(.system(size: 28))
      .foregroundStyle(tint)
      .frame(width: 32, alignment: .leading)
  }

  /// What a trial is, said where somebody is watching it run. The second line is
  /// the one worth being blunt about: the window really does close.
  private var trialExplanation: some View {
    VStack(alignment: .leading, spacing: 3) {
      row(
        "Every account, every session, the usage forecast, new and forked sessions and your mouse "
          + "bindings. This is the app, not a demo.")
      row(
        "When the window closes Armada stops watching, until a key is entered or it is reopened.")
    }
    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
  }

  /// The offer, or the note that it has already been taken.
  @ViewBuilder private var trialOffer: some View {
    if Trial.hasRun {
      Text("The trial window has closed. Quitting and reopening Armada starts another one.")
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        // Reachable only from a button, here and on the locked card. A trial that
        // armed itself at login would burn in a menu bar nobody was looking at.
        Button("Start a \(Int(Trial.duration / 60))-minute trial") {
          monitor.startTrial()
        }
        .controlSize(.small)
        Text("Full function, no key — enough to see it reading your own accounts and sessions.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 6)
    }
  }

  /// What "unlicensed" costs, in the words somebody needs when the session list
  /// they opened is not there.
  private var explanation: some View {
    VStack(alignment: .leading, spacing: 3) {
      row(
        "Armada watches nothing: no sessions, no context, no usage, and your mouse bindings are "
          + "paused.")
      row(
        "Nothing is lost. Your settings, bindings and recorded usage history stay exactly where "
          + "they are, and Armada never touched your Claude or Codex folders to begin with.")
      row("A key takes effect at once. Nothing needs restarting.")
    }
    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
  }

  private func row(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("·")
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      // A `TextEditor` rather than a single-line field: the key is 240 characters,
      // and a key pasted out of a mail client can arrive with the line breaks that
      // client wrapped it at. `LicenseKey.check` trims, and a box that shows the
      // whole thing is what lets somebody see they have pasted half of it.
      TextEditor(text: $entry)
        .font(.system(.caption, design: .monospaced))
        .frame(height: 92)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

      if let problem {
        // The reason, not a generic failure. It is produced once in
        // `LicenseKey.check` precisely so the same sentence reaches every surface.
        Text(problem)
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Use this key") { apply(entry) }
          .keyboardShortcut(.defaultAction)
          .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove") {
          monitor.removeKey()
          entry = ""
          problem = nil
        }
        .disabled(LicenseStore.raw == nil)
        if LicenseLinks.isSelling {
          Spacer()
          Button("Buy a licence…") { NSWorkspace.shared.open(LicenseLinks.buy) }
        }
      }
      .controlSize(.small)
    }
  }

  private var footer: some View {
    Text(
      "One key covers every \(AppInfo.major).x release and every Mac you own — it is issued to "
        + "you, not to a machine, and nothing counts your installs. Armada verifies it on this "
        + "Mac and never asks anyone about it."
    )
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Store it, or say why not. Refusing to persist a bad key is what stops the
  /// field and the status line disagreeing about what is installed.
  private func apply(_ text: String) {
    switch monitor.enterKey(text) {
    case .valid:
      problem = nil
      entry = LicenseStore.raw ?? ""
    case .refused(let reason):
      problem = reason
    }
  }

  private func accept(_ providers: [NSItemProvider]) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
      guard
        let data,
        let url = URL(dataRepresentation: data, relativeTo: nil),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else { return }
      Task { @MainActor in
        entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(entry)
      }
    }
    return true
  }

  /// The date half of an ISO timestamp. The clock time is noise on a receipt.
  private func day(_ issuedAt: String) -> String {
    String(issuedAt.prefix(10))
  }
}
