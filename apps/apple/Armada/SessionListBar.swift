import AppKit
import SwiftUI

/// What the list below is doing, as a row of tiles, with the sort menu at the end.
///
/// **The tally the account's overview used to carry, moved to the list it counts.** On the
/// overview it described the rows beside it only while no row was selected, which is the one
/// moment the list is also on screen to be read directly. Above the list it stays while a
/// session is open, and reads as the list's own summary: how many want you, how many are
/// working, out of how many, across how many checkouts, holding how much context.
///
/// **A tile for every state the vendor has, zeros included.** The overview's tally listed
/// only the states present, which was fine in a form and is not in a strip: sessions flip
/// between working and idle all day, and tiles appearing and disappearing would move every
/// tile after them each time. A zero is drawn in tertiary instead, so the eye still lands on
/// the counts that are not.
///
/// **Only the tiles change shape.** Side by side while they fit, then a single line of dots
/// and counts, then that line without the context figure, so a list dragged to its 320pt
/// floor still gets every count; the sort menu holds the trailing edge in all three.
///
/// Not in the window's toolbar, which holds actions: the sidebar toggle, Add Account, and an
/// account pane's New Session. This is the list's own summary, drawn over the column it counts.
struct SessionListBar<Item: SessionListItem, Dot: View>: View {
  /// One tile's state: the key `SessionListItem.stateKey` reports, a name short enough for a
  /// tile, and the vendor's own label for the tooltip.
  struct Tile: Identifiable {
    let id: String
    let short: String
    let label: String
  }

  let sessions: [Item]
  /// Every state this vendor's list can show, in the list's order. See
  /// `SessionState.barTiles`.
  let tiles: [Tile]
  @ViewBuilder let dot: (String) -> Dot

  var body: some View {
    let counts = Dictionary(grouping: sessions, by: \.stateKey).mapValues(\.count)
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        ViewThatFits(in: .horizontal) {
          wide(counts)
          narrow(counts, showsContext: true)
          narrow(counts, showsContext: false)
        }
        Spacer(minLength: 0)
        SessionSortMenu()
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      Divider()
    }
    .background(.bar)
  }

  // MARK: - Layouts

  private func wide(_ counts: [String: Int]) -> some View {
    HStack(alignment: .top, spacing: 16) {
      // The total first, fenced off from the states it is the sum of, so it reads as the
      // headline rather than as a fifth state.
      stat(sessions.count.formatted(), dimmed: sessions.isEmpty) { Text("Sessions") }
        .help(totalHelp)
      Divider().frame(height: 30)
      ForEach(tiles) { tile in
        let count = counts[tile.id] ?? 0
        stat(count.formatted(), dimmed: count == 0) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            dot(tile.id).centeredOnCapHeight(of: .caption1)
            Text(tile.short)
              .alignmentGuide(.statText) { $0[.leading] }
          }
        }
        .help(help(count, tile))
      }
      Divider().frame(height: 30)
      stat(projectCount.formatted(), dimmed: projectCount == 0) { Text("Projects") }
        .help(projectsHelp)
      stat(contextTokens.map(TokenCount.short) ?? "—", dimmed: contextTokens == nil) {
        Text("Context")
      }
      .help(Self.contextHelp)
    }
  }

  private func narrow(_ counts: [String: Int], showsContext: Bool) -> some View {
    HStack(spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
        Text(sessions.count.formatted()).fontWeight(.semibold)
      }
      .help(totalHelp)
      ForEach(tiles) { tile in
        let count = counts[tile.id] ?? 0
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          dot(tile.id).centeredOnCapHeight(of: .callout)
          Text(count.formatted())
            .foregroundStyle(count == 0 ? .tertiary : .primary)
        }
        .help(help(count, tile))
      }
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text(projectCount.formatted())
      }
      .help(projectsHelp)
      if showsContext, let contextTokens {
        Text("\(TokenCount.short(contextTokens)) context")
          .foregroundStyle(.secondary)
          .help(Self.contextHelp)
      }
    }
    .font(.callout.monospacedDigit())
    .lineLimit(1)
    .fixedSize()
  }

  /// The figure over its caption. Held to one line each: squeezed, a `Text` with no limit
  /// wraps a character per line, which is what once made the usage strip here hundreds of
  /// points tall in a narrow pane.
  ///
  /// Aligned on `.statText`, so a figure starts where its caption's words do and not over
  /// the state dot in front of them. A caption with no dot has nothing to skip, and the
  /// guide falls back to its leading edge.
  private func stat<Caption: View>(
    _ value: String, dimmed: Bool, @ViewBuilder caption: () -> Caption
  ) -> some View {
    VStack(alignment: .statText, spacing: 1) {
      Text(value)
        .font(.title3.weight(.medium).monospacedDigit())
        .foregroundStyle(dimmed ? .tertiary : .primary)
        .contentTransition(.numericText())
      caption()
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .fixedSize()
  }

  // MARK: - Figures

  /// Distinct checkouts, keyed on the path rather than the name: `~/work/api` and
  /// `~/oss/api` are two projects, and counting names would say one.
  private var projectCount: Int {
    Set(sessions.map(\.projectPath)).count
  }

  /// Nil when nothing has a reading yet, so the tile says "—" rather than claiming 0.
  private var contextTokens: Int? {
    let known = sessions.compactMap(\.contextTokens)
    return known.isEmpty ? nil : known.reduce(0, +)
  }

  private func help(_ count: Int, _ tile: Tile) -> String {
    "\(tile.label): \(count == 1 ? "1 session" : "\(count.formatted()) sessions")"
  }

  private var totalHelp: String {
    sessions.count == 1
      ? "1 session in this list" : "\(sessions.count.formatted()) sessions in this list"
  }

  private var projectsHelp: String {
    projectCount == 1
      ? "These sessions run in 1 folder."
      : "These sessions run in \(projectCount.formatted()) different folders."
  }

  /// The same warning `SessionGroupHeader` carries, for the same figure: this is what the
  /// sessions are holding right now, and it falls when any one of them compacts. It is not
  /// what they have cost — see `SessionListItem`.
  private static var contextHelp: String {
    "What these sessions are holding between them as of their newest turns. Not a running total of what they have cost."
  }
}

extension SessionState {
  /// The Claude pane's tiles, in `SessionListItem.stateRank`'s order: what wants you first.
  /// A state added to the enum has to be added here to get a tile.
  static let barTiles: [SessionListBar<Session, StateDot>.Tile] =
    [SessionState.waiting, .working, .runningTool, .idle].map {
      .init(id: $0.rawValue, short: $0.shortLabel, label: $0.label)
    }

  /// The label, cut to fit a tile. Exhaustive, so a new state cannot go without one.
  var shortLabel: String {
    switch self {
    case .waiting: "Waiting"
    case .working: "Working"
    case .runningTool: "Tool"
    case .idle: "Idle"
    }
  }
}

extension CodexSessionState {
  /// The Codex pane's tiles, in `SessionListItem.stateRank`'s order.
  static let barTiles: [SessionListBar<CodexSession, CodexStateDot>.Tile] =
    [CodexSessionState.awaitingInput, .working, .ended].map {
      .init(id: $0.rawValue, short: $0.shortLabel, label: $0.label)
    }

  var shortLabel: String {
    switch self {
    case .awaitingInput: "Waiting"
    case .working: "Working"
    case .ended: "Ended"
    }
  }
}

extension HorizontalAlignment {
  /// Where a tile's caption text starts, past any dot in front of it. See
  /// `SessionListBar.stat`.
  private enum StatText: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.leading] }
  }

  fileprivate static let statText = HorizontalAlignment(StatText.self)
}

extension View {
  /// Centres a view with no text in it, such as a state dot, on the capitals of the text it
  /// sits beside in a `.firstTextBaseline` stack.
  ///
  /// A plain centred `HStack` centres the dot on the text's whole line box, descender space
  /// included, which puts it visibly low beside "Working" or a count. The line's capitals are
  /// what the eye centres on, so the dot's middle goes at half their height above the
  /// baseline. SF Symbols need none of this: they carry a baseline of their own.
  fileprivate func centeredOnCapHeight(of style: NSFont.TextStyle) -> some View {
    let capHeight = NSFont.preferredFont(forTextStyle: style).capHeight
    return alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHeight / 2 }
  }
}
