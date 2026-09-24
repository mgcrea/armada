import AppKit
import Observation
import SwiftUI

/// The licence gate, in one place.
///
/// Armada's gate is not a check sprinkled over the views. It is whether the
/// watchers run at all: refused, `Accounts` and `CodexAccounts` are stopped and
/// hold nothing, and the mouse tap is removed, so there is no session list for a
/// view to show and nothing left polling a folder or spawning `claude` in the
/// background. The views then only have to say why the panel is empty —
/// `LockedCard` — rather than each deciding what to hide.
///
/// Everything that can change the answer goes through here: launch, a trial
/// starting, a key entered or removed, and the trial window closing. That is what
/// keeps the watchers and what the windows say from disagreeing.
///
/// It is also a few lines anyone reading the source can find and remove. See
/// `LicenseKey` for why that is accepted rather than defended against.
@MainActor
@Observable
final class EntitlementMonitor {
  static let shared = EntitlementMonitor()

  /// Read by every view that shows the gate. Stored rather than computed so a
  /// change is observed; `apply()` is the only writer.
  private(set) var current: Entitlement = Entitlement.current

  private init() {}

  /// Bring the watchers in line with the entitlement. Idempotent both ways:
  /// `start()` returns early when already running and `stop()` when stopped, so
  /// calling this again on an unchanged answer costs a signature check.
  func apply() {
    current = Entitlement.current
    if current.isEntitled {
      Accounts.shared.start()
      CodexAccounts.shared.start()
      GrokAccounts.shared.start()
      // After the accounts, whose folders it reads.
      UsageIndex.shared.start()
      // After the accounts too: it edits each one's settings.json to match the switch.
      MessageDelivery.shared.sync()
    } else {
      UsageIndex.shared.stop()
      Accounts.shared.stop()
      CodexAccounts.shared.stop()
      GrokAccounts.shared.stop()
    }
    MouseTap.shared.sync()
    // After the watchers, for the same reason as the tap: an unlicensed Armada holds no
    // sessions, so the MCP server stops with them rather than answering with an empty fleet.
    MCPServerController.shared.sync()
    // After the server, which voice reads the fleet through. The shortcut is registered only
    // while voice is switched on and Armada is entitled, so an unlicensed Armada hears nothing.
    VoiceController.shared.sync()
  }

  func startTrial() {
    Trial.start()
    apply()
  }

  @discardableResult
  func enterKey(_ key: String) -> LicenseCheck {
    let result = LicenseStore.store(key)
    apply()
    return result
  }

  func removeKey() {
    LicenseStore.clear()
    apply()
  }
}

/// What stands where the sessions would be while Armada is not entitled.
///
/// The trial leads, and only until it has been used — bastion's reasoning:
/// somebody reading this has just found an empty panel, and the useful offer is
/// the one that makes it work in the next ten seconds, not the one that opens a
/// checkout. Once the window has closed there is nothing to offer a second time,
/// so the card says what to do instead.
struct LockedCard: View {
  let compact: Bool
  private var monitor = EntitlementMonitor.shared

  init(compact: Bool) {
    self.compact = compact
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 10) {
      Label(
        Trial.hasRun ? "The trial has ended" : "Armada needs a licence",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      .font(compact ? .caption : .headline)

      Text(
        Trial.hasRun
          ? "Armada has stopped watching. Enter a key to carry on, or quit and reopen it for another trial."
          : "Without a key Armada watches nothing. A \(Int(Trial.duration / 60))-minute trial runs everything, on your own accounts, with no key."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      // A key that is present and refused says why. "No licence key" is the
      // ordinary state and the sentence above already covers it.
      if case .refused(let reason) = monitor.current, LicenseStore.raw != nil {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        if !Trial.hasRun {
          Button("Start a \(Int(Trial.duration / 60))-minute trial") { monitor.startTrial() }
            .buttonStyle(.glassProminent)
          Button("Enter a key…") { openLicence() }
            .buttonStyle(.glass)
        } else {
          Button("Enter a licence key…") { openLicence() }
            .buttonStyle(.glassProminent)
        }
        // Gated exactly as `LicensePane` gates the identical button. In the
        // popover only once the trial is spent: three buttons do not fit in
        // 320pt, and before then the trial is the better offer.
        if LicenseLinks.isSelling && (!compact || Trial.hasRun) {
          Button("Buy a licence…") { NSWorkspace.shared.open(LicenseLinks.buy) }
            .buttonStyle(.glass)
        }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: compact ? .infinity : 440, alignment: .leading)
    .padding(compact ? 0 : 24)
    .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
  }

  private func openLicence() {
    // The panel first, for the reason `SummaryRow` gives: opening one of
    // Armada's own windows never makes the app resign active, so the panel
    // would otherwise hang over the window it just opened.
    if compact { MenuBarPanel.dismiss() }
    AppDelegate.shared?.showSettings(.licence)
  }
}

/// The trial, while it is running, in the popover.
///
/// Deliberately not styled as a warning. Nothing is wrong — everything is
/// working, on purpose — and the orange triangle belongs to the state where it is
/// not.
struct TrialBanner: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      HStack(spacing: 6) {
        Label("Trial · \(Trial.remainingText)", systemImage: "clock")
          .foregroundStyle(.blue)
          .font(.caption)
        Spacer(minLength: 4)
        if LicenseLinks.isSelling {
          Button("Buy a licence…") { NSWorkspace.shared.open(LicenseLinks.buy) }
            .buttonStyle(.glass)
            .controlSize(.small)
        } else {
          Button("Enter a key…") {
            MenuBarPanel.dismiss()
            AppDelegate.shared?.showSettings(.licence)
          }
          .buttonStyle(.borderless)
          .font(.caption)
        }
      }
    }
  }
}

/// One line in the main window's sidebar footer: licensed, trial, or unlicensed.
///
/// Cupertino's `licenceLine`. On a timeline because one of the three states is a
/// countdown, and this line sits in a window somebody leaves open while they try
/// the thing out.
struct LicenceStatusLine: View {
  private var monitor = EntitlementMonitor.shared

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      Button {
        AppDelegate.shared?.showSettings(.licence)
      } label: {
        switch monitor.current {
        case .licensed:
          Label("Licensed", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        case .trial:
          Label("Trial · \(Trial.remainingText)", systemImage: "clock.fill")
            .foregroundStyle(.blue)
        case .refused:
          Label("Unlicensed", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      .buttonStyle(.plain)
      .font(.caption)
      .pointerStyle(.link)
      .help(helpText)
    }
  }

  private var helpText: String {
    switch monitor.current {
    case .licensed(let license): "Licensed to \(license.email)"
    case .trial: "Everything is running, exactly as a licensed copy would"
    case .refused(let reason): reason
    }
  }
}

#if DEBUG
  extension EntitlementMonitor {
    /// A capture's entitlement, set rather than verified. It unlocks nothing: in a
    /// capture `apply()` is never called, so no watcher starts on the strength of
    /// it. See `DemoSeed` and `LicenseStore`.
    func demoInstall(_ entitlement: Entitlement) { current = entitlement }
  }
#endif
