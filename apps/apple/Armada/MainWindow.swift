import SwiftUI

/// The two things Armada shows.
enum MainPane: String, CaseIterable, Identifiable {
  case sessions
  case usage

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .sessions: "Sessions"
    case .usage: "Usage"
    }
  }

  var systemImage: String {
    switch self {
    case .sessions: "list.bullet.rectangle"
    case .usage: "gauge.with.dots.needle.bottom.50percent"
    }
  }
}

struct MainWindowView: View {
  /// A `String`-backed `RawRepresentable` through `@AppStorage`, matching the
  /// sibling apps: the window reopens on the pane it was last left on.
  @AppStorage("armada.mainPane") private var pane: MainPane = .sessions
  @State private var watcher = SessionWatcher.shared

  var body: some View {
    NavigationSplitView {
      List(selection: Binding(selecting: $pane)) {
        ForEach(MainPane.allCases) { item in
          Label(item.title, systemImage: item.systemImage)
            .badge(item == .sessions ? watcher.sessions.count : 0)
            .tag(item)
        }
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
      .safeAreaInset(edge: .bottom) {
        Text("Armada \(AppInfo.shortVersion)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
    } detail: {
      switch pane {
      case .sessions: SessionsPaneView()
      case .usage: UsagePaneView()
      }
    }
  }
}

extension Binding {
  /// A non-optional binding as the optional one `List(selection:)` wants.
  ///
  /// **A nil write is dropped rather than stored.** `List` hands `nil` back on its
  /// way up, before the tagged rows have registered, so folding it into a real
  /// value overwrites whatever was just selected a frame later. `SettingsScaffold`
  /// carries the same guard and the note that it cost a staged screenshot which
  /// opened on the wrong pane having asked for the right one.
  init<Selected>(selecting source: Binding<Selected>) where Value == Selected? {
    self.init(
      get: { source.wrappedValue },
      set: { newValue in
        guard let newValue else { return }
        source.wrappedValue = newValue
      })
  }
}
