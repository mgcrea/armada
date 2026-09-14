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

  private var sort: SessionSort { SessionSort(stored: storedSort) }
  private var grouping: SessionGrouping { SessionGrouping(stored: storedGrouping) }

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
      // **The label names the sort, not the control.** A bare glyph was too quiet to
      // find, and "Sort" would have been a word that says nothing: the sort key is the
      // one half of this choice the list cannot show you. Grouping needs no label
      // because a grouped list is visibly sections, with the folder written on each.
      //
      // The glyph is fixed, so it names the control rather than reading as a fact
      // about the list. The per-sort glyphs are on the rows inside the menu.
      Label(sort.label, systemImage: "arrow.up.arrow.down")
        .font(.caption)
    }
    .menuStyle(.button)
    // The two halves of the affordance. `.accessoryBar`, the system's style for a
    // list's own options control in Finder and Mail, is what makes it read as
    // pressable at rest without the weight of a push button; the chevron is what says
    // that pressing it opens a menu rather than acting on the spot.
    .menuIndicator(.visible)
    .buttonStyle(.accessoryBar)
    // Fixed, so the header's `Spacer` keeps it hard against the trailing edge and it
    // never stretches. It costs the pane the glyph, the sort's name and the chevron
    // in width, and no height at all — see `AccountPaneView.body` for why the fitting
    // size is worth defending.
    .fixedSize()
    .help(helpText)
    // Otherwise VoiceOver reads the label alone, "Last activity", which names a value
    // and says nothing about what pressing it does.
    .accessibilityLabel("Sort by \(sort.label)")
  }

  /// Says both halves, since the button only shows one of them.
  private var helpText: String {
    let by = grouping == .none ? "not grouped" : "grouped by \(grouping.label.lowercased())"
    return "Sorted by \(sort.label.lowercased()), \(by)"
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
    HStack(spacing: 8) {
      Text(group.title)
      Spacer(minLength: 8)
      if let tokens = group.contextTokens {
        // Tertiary and unlabelled: it sits directly above a column of the same
        // numbers, which is what says what it is. The tooltip carries the noun, and
        // the warning — this is context held right now, not what the work has cost.
        Text(TokenCount.short(tokens))
          .monospacedDigit()
          .foregroundStyle(.tertiary)
          .help(
            "\(group.items.count == 1 ? "1 session is" : "\(group.items.count) sessions are") holding \(TokenCount.short(tokens)) tokens of context here. Not a running total of what they have cost."
          )
      }
    }
  }
}
