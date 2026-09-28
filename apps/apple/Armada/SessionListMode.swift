import SwiftUI

/// What an account's session list shows: what is running, or what ran and has nothing behind it.
enum SessionListMode: Hashable {
  case live
  case history
}

/// The switch between the two, in the middle of the window's toolbar.
///
/// **In the toolbar, not over the list.** At the head of the list's strip it took its width out
/// of a column whose floor is 320pt, and so pushed the live tiles into their one-line layout
/// at a wider list than before. In the toolbar it costs the list nothing, and sits beside
/// History's search field. `.principal`, the middle, as Calendar's Day | Week | Month is: a
/// switch of what the content shows, apart from the actions at either end.
struct SessionListModePicker: View {
  @Binding var mode: SessionListMode

  var body: some View {
    Picker("Show", selection: $mode) {
      Text("Live").tag(SessionListMode.live)
      Text("History").tag(SessionListMode.history)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .help("Switch between the sessions running now and the ones that are not")
  }
}

/// The strip over History: how many sessions the list holds, and how many a search left.
///
/// **The same figure-over-caption tile as the live strip's first**, so the strip keeps its
/// height when the switch flips and the list below does not jump.
struct SessionHistoryBar: View {
  let model: SessionHistoryModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 1) {
          Text(model.loaded ? model.shownCount.formatted() : "—")
            .font(.title3.weight(.medium).monospacedDigit())
            .foregroundStyle(model.shownCount == 0 ? .tertiary : .primary)
            .contentTransition(.numericText())
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .help(SessionHistory.countLabel(shown: model.shownCount, total: model.entries.count))
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      Divider()
    }
    .background(.bar)
  }

  private var caption: String {
    let total = model.entries.count
    guard model.shownCount != total else { return "Not running" }
    return "of \(total.formatted()) found"
  }
}
