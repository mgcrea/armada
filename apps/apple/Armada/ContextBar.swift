import SwiftUI

/// One band of the context window: a name, a size, and the colour that ties its row
/// in the table to its segment in the bar.
///
/// The vocabulary and the palette are Claude Code's own `/context`, deliberately, so
/// that someone who has read one can read the other without relearning anything.
/// **What Armada cannot copy is the number of bands.** `/context` splits the fixed
/// prefix into system prompt, system tools, MCP tools, memory files and skills;
/// those figures are worked out in the running process and never written down, so
/// here they arrive as a single measured total. See `TranscriptContext`.
nonisolated struct ContextCategory: Sendable, Hashable, Identifiable {
  let name: String
  let tokens: Int
  let color: Color
  /// The tooltip for both the row and its segment.
  let help: String

  var id: String { name }

  /// The blue `/context` gives "System tools", which is the largest thing inside the
  /// prefix this row stands for.
  static let prefixColor = Color(red: 0.36, green: 0.55, blue: 0.94)
  /// The red `/context` gives "Messages".
  static let conversationColor = Color(red: 0.77, green: 0.27, blue: 0.24)

  /// `/context`'s own swatch for a probed category, by the name it returns.
  ///
  /// The palette is Claude Code's: white for the system prompt, blue for system
  /// tools, green for MCP, tan for memory files, purple for skills. An unknown name
  /// falls back to the prefix blue rather than to nothing, so a category added in a
  /// future release still gets a swatch and still lines up with its row.
  static func color(forProbed name: String) -> Color {
    switch name {
    case "System prompt": .init(white: 0.92)
    case "System tools": prefixColor
    case "MCP tools": .init(red: 0.55, green: 0.80, blue: 0.55)
    case "Memory files": .init(red: 0.90, green: 0.70, blue: 0.44)
    case "Skills": .init(red: 0.78, green: 0.56, blue: 0.90)
    case "Custom agents": .init(red: 0.45, green: 0.75, blue: 0.85)
    default: prefixColor
    }
  }
}

/// The context window as one bar, banded like `/context`'s.
///
/// **Not `UsageBar`, and not a variant of it.** That one renders a single percentage
/// with a forecast drawn over it, and its whole shape — one `percent`, one tint from
/// `UsageTint` — assumes there is one quantity. This has a list of them.
///
/// Segments are laid out left to right in a `ZStack` as cumulative capsules drawn
/// widest-first, which is how `UsageBar` builds its layers too. Anything that
/// overhangs the track would belong in an `.overlay` rather than as a stack child —
/// a `ZStack` takes its height from its tallest child, which is how a 3pt-taller
/// marker once silently inflated every bar it was drawn in (`UsageBar.swift`).
struct ContextBar: View {
  let categories: [ContextCategory]
  let limit: Int
  var height: CGFloat = 8

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        // Widest first: each capsule runs from the left edge to the end of its own
        // band, so the one after it paints over all but its own slice. Drawing each
        // band as an offset rectangle instead would leave hairline gaps between them
        // at fractional widths.
        ForEach(cumulative.reversed(), id: \.0.id) { category, end in
          Capsule()
            .fill(category.color)
            .frame(width: width * end)
        }
      }
    }
    .frame(height: height)
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
  }

  /// Each category paired with where its band ends, as a fraction of the window.
  private var cumulative: [(ContextCategory, Double)] {
    var running = 0
    return categories.map { category in
      running += category.tokens
      return (category, min(Double(running) / Double(max(limit, 1)), 1))
    }
  }

  private var accessibilityLabel: String {
    let used = categories.reduce(0) { $0 + $1.tokens }
    let percent = Int((Double(used) / Double(max(limit, 1)) * 100).rounded())
    return "\(min(percent, 100)) percent of the context window used: "
      + categories.map { "\($0.name) \(TokenCount.short($0.tokens))" }.joined(separator: ", ")
  }
}

/// Token counts the way Claude Code writes them: `270.9k`, `1.0M`, `367`.
///
/// Its own type rather than a `FormatStyle` on `Int`, because the rounding is the
/// part that matters and it is not the default one. `4.0k` and `696.1k` both carry
/// one decimal where a `.notation(.compact)` style drops it above 100k, and the
/// figure this app exists to show is most often in exactly that range.
enum TokenCount {
  static func short(_ tokens: Int) -> String {
    switch tokens {
    case ..<1_000: "\(tokens)"
    case ..<1_000_000: String(format: "%.1fk", Double(tokens) / 1_000)
    default: String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
  }

  /// `270.9k / 1.0M tokens (27%)`, the headline over the bar.
  static func headline(total: Int, limit: Int) -> String {
    let percent = Int((Double(total) / Double(max(limit, 1)) * 100).rounded())
    return "\(short(total)) / \(short(limit)) tokens (\(min(percent, 100))%)"
  }

  /// The `USAGE` column: a share of the whole window, `<0.1%` rather than `0.0%`.
  ///
  /// `/context` writes it that way, and the reason is worth keeping: a row that
  /// rounds to nothing is not a row worth nothing, and `0.0%` reads like a bug.
  static func share(_ tokens: Int, of limit: Int) -> String {
    let percent = Double(tokens) / Double(max(limit, 1)) * 100
    if percent > 0, percent < 0.1 { return "<0.1%" }
    return String(format: "%.1f%%", percent)
  }
}
