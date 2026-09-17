import SwiftUI

/// Which accounts the menu bar panel leaves out.
///
/// **A list of hidden ids, not of shown ones**, so an account that appears later (a new
/// `~/.claude-<name>`, a Grok Build install) is on the panel by default rather than silently
/// missing from it. Every vendor's account id is its folder's absolute path, so one list covers
/// Claude, Codex and Grok without a prefix.
///
/// Hiding trims the glance and nothing else. The window's sidebar and Usage pane list every
/// account, a starred menu bar figure keeps drawing, and the halo still lights for a hidden
/// account's sessions: hiding is about clutter, and a session waiting on you is the thing that
/// should never go unseen.
nonisolated enum PanelVisibility {
  static let defaultsKey = "armada.panelHiddenAccounts"

  /// One path per line: a path holds no newline, and a line list reads plainly in `defaults read`.
  static func hidden(stored: String) -> Set<String> {
    Set(stored.split(separator: "\n").map(String.init))
  }

  static func stored(_ hidden: Set<String>) -> String {
    hidden.sorted().joined(separator: "\n")
  }

  static func setting(_ id: String, shown: Bool, in stored: String) -> String {
    var set = hidden(stored: stored)
    if shown { set.remove(id) } else { set.insert(id) }
    return Self.stored(set)
  }
}

/// The sidebar row's "Show in Menu Bar Panel", a checkmark item.
struct PanelVisibilityToggle: View {
  let accountID: String

  @AppStorage(PanelVisibility.defaultsKey) private var storedHidden = ""

  var body: some View {
    Toggle("Show in Menu Bar Panel", isOn: shown)
  }

  private var shown: Binding<Bool> {
    Binding(
      get: { !PanelVisibility.hidden(stored: storedHidden).contains(accountID) },
      set: { storedHidden = PanelVisibility.setting(accountID, shown: $0, in: storedHidden) })
  }
}

/// The sidebar row's eye.
///
/// State-aware rather than always drawn: a hidden account keeps a dimmed `eye.slash`, so what the
/// panel leaves out reads at a glance, and a shown one reveals its `eye` only while the row is
/// hovered, so a sidebar of ordinary accounts carries no extra glyph per row.
struct PanelVisibilityEye: View {
  let accountID: String
  let rowHovered: Bool

  @AppStorage(PanelVisibility.defaultsKey) private var storedHidden = ""

  var body: some View {
    let hidden = PanelVisibility.hidden(stored: storedHidden).contains(accountID)
    if hidden || rowHovered {
      Button {
        storedHidden = PanelVisibility.setting(accountID, shown: hidden, in: storedHidden)
      } label: {
        Image(systemName: hidden ? "eye.slash" : "eye")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .help(hidden ? "Show in the menu bar panel" : "Hide from the menu bar panel")
      .accessibilityLabel(hidden ? "Show in menu bar panel" : "Hide from menu bar panel")
    }
  }
}
