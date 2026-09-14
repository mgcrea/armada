import AppKit
import Observation
import Sparkle
import SwiftUI

/// The update check — the one thing in this app that opens a socket to the
/// internet, and the single named exception to the claim in SECURITY.md.
///
/// Everything here is built around one property: **an Armada nobody has said yes
/// to has never resolved a name.** That is stronger than "the checkbox is off",
/// and it is why `SPUStandardUpdaterController` is not a stored property built at
/// launch but a `nil` that stays `nil`. Sparkle starts a scheduler the moment it
/// is constructed, so constructing it and then declining to check would leave the
/// claim resting on a flag rather than on the absence of the machinery.
///
/// `scripts/audit-network.sh` asserts the shipped Info.plist agrees — checks off,
/// feed ours, public key well formed — so "off by default" is something CI
/// refuses to ship without rather than a sentence in a settings pane.
///
/// Cupertino's controller, copied, less what Armada does not have: no screenshot
/// capture to stay out of, no bridge that can start the app in the background,
/// and no child processes of its own to stop before a relaunch — the `claude`
/// probes `ClaudeControl` spawns answer one question and exit.
@MainActor
@Observable
final class UpdateController: NSObject {
  static let shared = UpdateController()

  /// Set once the user has answered the consent card, either way.
  static let choiceMade = "updateChoiceMade"

  private var controller: SPUStandardUpdaterController?

  private(set) var isChecking = false
  private(set) var lastCheck: Date?

  /// Whether automatic checks are on.
  ///
  /// The answer lives in Sparkle's own `UserDefaults` key, read through the
  /// updater when it exists and directly when it does not. A second
  /// `@AppStorage` mirror would be one more thing to drift, and the plist default
  /// (`SUEnableAutomaticChecks`, false) already answers for a fresh install.
  var automatic: Bool {
    controller?.updater.automaticallyChecksForUpdates
      ?? UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
  }

  /// Whether the consent card has been answered, either way.
  var hasAnswered: Bool {
    UserDefaults.standard.bool(forKey: Self.choiceMade)
  }

  /// Called from `applicationDidFinishLaunching`. Builds nothing unless the user
  /// has already opted in.
  func startIfConsented() {
    guard UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks") else { return }
    start()
  }

  /// An explicit Check Now. This is consent in itself — pressing it is asking —
  /// so it starts the updater even when automatic checks are off, and leaves
  /// them off.
  func checkNow() {
    start()
    isChecking = true
    lastCheck = Date()
    controller?.updater.checkForUpdates()
  }

  func setAutomatic(_ on: Bool) {
    if on { start() }
    controller?.updater.automaticallyChecksForUpdates = on
    // Written through even when no updater exists, so that a "no" answered at the
    // consent card is durable without constructing one to record it.
    UserDefaults.standard.set(on, forKey: "SUEnableAutomaticChecks")
  }

  /// Record an answer from either place that asks: the card or the pane.
  func answer(automatic on: Bool) {
    setAutomatic(on)
    UserDefaults.standard.set(true, forKey: Self.choiceMade)
  }

  private func start() {
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
  }
}

extension UpdateController: SPUUpdaterDelegate {
  /// Sparkle asks on its own on second launch when `SUEnableAutomaticChecks` is
  /// absent. It is present and false, so this never fires — but the plist is a
  /// build input and this is code, and only one of the two survives somebody
  /// deleting a key they did not recognise.
  nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
    false
  }

  /// Never postpone the relaunch. Sparkle calls this the moment somebody clicks
  /// Install and Relaunch, so the only thing a postponement could ever defer is
  /// an explicit request — cupertino found exactly that, and a button that reads
  /// as broken.
  nonisolated func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool { false }
}

extension UpdateController: SPUStandardUserDriverDelegate {
  /// A scheduled check that finds something posts a notification instead of
  /// stealing focus. Armada spends nearly all of its life as an accessory nobody
  /// is looking at, and an alert in front of the window someone *is* looking at
  /// is the wrong way to mention a point release.
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  /// `DockPresence` follows the windows, and every window this app owns is opened
  /// through `HostedWindow.show()`, which calls `update()` itself. Sparkle's
  /// alert is the first window that arrives from neither path, and without this
  /// it appears with no Dock icon, no app menu and no ⌘-Tab entry.
  ///
  /// The hop mirrors `updateAfterClose`'s: the notification arrives before the
  /// window is on screen, so counting immediately would not yet see it.
  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    Task { @MainActor in
      isChecking = false
      try? await Task.sleep(for: .milliseconds(50))
      DockPresence.update()
    }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    Task { @MainActor in
      isChecking = false
      DockPresence.update()
    }
  }
}

/// Asked once, and as a card rather than a dialog.
///
/// The honest default already holds without an answer — nothing constructs an
/// updater, and nothing resolves a name, until somebody opts in — so stopping the
/// app to demand one would be theatre.
///
/// It is also the sentence that keeps SECURITY.md honest. Armada reads every
/// transcript on the Mac and is sold partly on none of it leaving, so the moment
/// it can open a connection at all, the person who bought it on that basis is the
/// one who decides.
struct UpdateConsentCard: View {
  @State private var answered = UpdateController.shared.hasAnswered

  var body: some View {
    if !answered {
      VStack(alignment: .leading, spacing: 8) {
        Label("Should Armada check for updates?", systemImage: "arrow.down.circle")
          .font(.subheadline).bold()
        Text(
          """
          Armada makes no network connections of its own. Checking for updates is \
          the one exception, and it is off until you say otherwise. It reads one \
          file and sends no identifier with it.
          """
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button("Check automatically") { answer(true) }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
          Button("Keep updates off") { answer(false) }
            .controlSize(.small)
          Text("You can change this in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4))
    }
  }

  private func answer(_ automatic: Bool) {
    UpdateController.shared.answer(automatic: automatic)
    answered = true
  }
}

/// The update controls.
///
/// Armada's only network connection is this one, so the footer says what the
/// check sends in plain terms rather than leaving it to the privacy page.
struct UpdatesPane: View {
  @State private var automatic = UpdateController.shared.automatic
  private var updates = UpdateController.shared

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: AppInfo.version)

        // The row's whole label is the answer to "am I current", because a row
        // titled the same thing as the button beside it says nothing twice.
        LabeledContent {
          Button("Check Now…") { updates.checkNow() }
            .disabled(updates.isChecking)
        } label: {
          Text(lastCheck)
        }
      }

      Section {
        Toggle(isOn: $automatic) {
          Text("Check for updates automatically")
        }
        .onChange(of: automatic) { _, on in
          // Answering here is answering the consent card too. Leaving it armed
          // would ask again about a decision already made in this pane.
          updates.answer(automatic: on)
        }
      } footer: {
        Text(
          """
          This is the only network connection Armada makes, and it makes none at \
          all until you turn this on or press Check Now. It reads one file, \
          armada.mgcrea.io/appcast.xml, and sends no identifier with it: not your \
          licence key, not a machine id.
          """
        )
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Updates")
  }

  /// A sentence either way. A row showing nothing before the first check reads
  /// as a missing value rather than as the answer.
  private var lastCheck: String {
    guard let last = updates.lastCheck else { return "Not checked yet" }
    return "Last checked \(last.formatted(.relative(presentation: .named)))"
  }
}
