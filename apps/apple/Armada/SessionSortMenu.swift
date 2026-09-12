import SwiftUI

/// How the session list is ordered, as one menu.
///
/// `Picker`s inside a `Menu` rather than `Toggle`s or a segmented control: on macOS an
/// inline `Picker` in a menu renders as a titled group with a checkmark on the chosen
/// item, which is the system's own sort menu — Finder's View → Sort By, Mail's
/// list-options button — and needs no styling to look right.
///
/// **`.pickerStyle(.inline)` is load-bearing.** The default style inside a `Menu` nests
/// each picker in a submenu, which turns a four-item menu into two hovers.
///
/// **No parameters and no bindings passed in.** Both values live in `@AppStorage`,
/// which is this app's preference convention (`DayWeights`, `SidebarItem`), and every
/// view reading the same key updates when this writes it. So it drops into either
/// pane's header as one line with no signature change, and the two panes — which are
/// twinned on purpose — cannot drift apart.
struct SessionSortMenu: View {
  @AppStorage(SessionSort.defaultsKey) private var storedSort = SessionSort.fallback.stored
  @AppStorage(SessionGrouping.defaultsKey)
  private var storedGrouping = SessionGrouping.fallback.stored

  var body: some View {
    Menu {
      // The tags are `String`, matching what `@AppStorage` binds, exactly. The same
      // trap as `.contextMenu(forSelectionType:)` in `AccountPaneView`: a tag of the
      // wrong type compiles and the control silently selects nothing.
      Picker("Sort by", selection: $storedSort) {
        ForEach(SessionSort.allCases) { sort in
          Label(sort.label, systemImage: sort.systemImage).tag(sort.stored)
        }
      }
      .pickerStyle(.inline)

      Divider()

      Picker("Group by", selection: $storedGrouping) {
        ForEach(SessionGrouping.allCases) { grouping in
          Text(grouping.label).tag(grouping.stored)
        }
      }
      .pickerStyle(.inline)
    } label: {
      // `arrow.up.arrow.down`, not `line.3.horizontal.decrease`. This menu orders and
      // filters nothing; the filter glyph should stay free for a filter field rather
      // than be spent here and have to move later.
      Label("Sort and group", systemImage: "arrow.up.arrow.down")
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .labelStyle(.iconOnly)
    // Icon-only and fixed, so the control adds neither height nor width to the header.
    // See `AccountPaneView.body` for why the pane's fitting size is worth defending.
    .fixedSize()
    .help("How this list is ordered")
  }
}

/// A section header in a grouped session list.
///
/// The full path goes in a tooltip rather than the title: two checkouts can both be
/// called "api", the headers would read identically, and the path is the only thing
/// that tells them apart. See `SessionGroup.id`.
struct SessionGroupHeader<Item: SessionListItem>: View {
  let group: SessionGroup<Item>

  var body: some View {
    Text(group.title)
      .help(group.subtitle ?? group.title)
  }
}
