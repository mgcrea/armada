import AppKit
import SupportKit
import SupportKitSettings
import SwiftUI

/// Armada's settings panes.
///
/// The protocol is qualified because this enum has the same name as it — which is
/// the fleet's convention, and the reason `references/shared-package.md` spells
/// the qualification out.
///
/// No entitlement pane: Armada sells nothing, so there is nothing to unlock.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case about

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .about: "info.circle"
    }
  }

  static var defaultPane: SettingsPane { .general }
}

/// The settings window's content.
///
/// The shared `SettingsScaffold` rather than a hand-rolled `NavigationSplitView`:
/// Armada is greenfield, so it can consume the scaffold the rest of the fleet is
/// migrating onto rather than becoming an eleventh thing to migrate. The About
/// pane comes with it.
///
/// Hosted in an `NSWindow` by `HostedWindow`, not declared as a SwiftUI `Settings`
/// scene — that scene opens through `showSettingsWindow:`, routed via an app menu
/// an `LSUIElement` app does not have. Both sibling menu-bar apps found this
/// independently.
struct SettingsWindowView: View {
  var body: some View {
    SettingsScaffold(selection: Support.settings) { pane in
      switch pane {
      case .general: GeneralPane()
      case .about:
        AboutSettingsPane(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      }
    }
    // Sized for the content, never the window: a sidebar spends up to 240pt before
    // a pane sees any width, so a number carried over from a tabbed layout is too
    // narrow. 660 is where the fleet landed.
    .settingsWindowSize(minWidth: 660, idealWidth: 700, minHeight: 400, idealHeight: 460)
  }
}

struct GeneralPane: View {
  @State private var watcher = SessionWatcher.shared
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var loginError: String?

  var body: some View {
    Form {
      Section {
        Toggle("Launch Armada at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, wanted in
            loginError = LoginItem.set(wanted)
            // What the service reports, not what was asked for: a registration
            // that did not take should show as unticked rather than be assumed.
            launchAtLogin = LoginItem.isEnabled
          }
        if let loginError {
          Text(loginError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } footer: {
        Text(
          "Armada watches sessions from the moment it starts. It never writes to your Claude configuration."
        )
      }

      Section("Claude") {
        LabeledContent("Config folder") {
          HStack(spacing: 6) {
            Text(displayPath(watcher.folder.base))
              .truncationMode(.head)
              .lineLimit(1)
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([watcher.folder.base])
            } label: {
              Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
          }
        }
        LabeledContent("Usage cache", value: displayPath(watcher.folder.usageJSON))
        LabeledContent("Live sessions", value: String(watcher.sessions.count))
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
  }

  /// `~` rather than the full home path, which is both shorter and the one part of
  /// these paths nobody needs to read.
  private func displayPath(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}
