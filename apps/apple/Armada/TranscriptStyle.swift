import Foundation

/// What the transcript window is made of.
///
/// A reading window is the one place in Armada where the material is a real choice rather
/// than a decoration: a transcript is read for minutes at a time, against whatever happens
/// to be behind it, and the right answer depends on the desk it sits on. Everything else in
/// the app is a dashboard glanced at, and takes the system background without asking.
///
/// **Ordered by how much gets through.** Solid lets nothing through and is the default,
/// because it is the only one where contrast is a property of the window rather than of
/// what is behind it. The three below it each trade some of that for depth, and the trade
/// gets worse the busier the desktop is — which is why the picker says so.
///
/// Pure Foundation on purpose: the mapping to an `NSVisualEffectView.Material` lives in
/// `TranscriptPane`, so this file stays a set of cases with names, checkable by `make unit`
/// with no AppKit and no window.
enum TranscriptStyle: String, CaseIterable, Sendable {
  /// The ordinary window background. Opaque, and the most readable.
  case solid
  /// Blurred and tinted, like a sidebar. What is behind shows as colour, not as shapes.
  case frosted
  /// The material macOS puts under a window: the desktop reads through most strongly.
  case desktop
  /// Liquid Glass, as macOS 26 draws it.
  case glass

  static let defaultsKey = "armada.transcriptStyle"

  /// Solid, and the reason is contrast rather than taste. Every other style borrows its
  /// legibility from whatever is behind the window, which is a thing Armada cannot see.
  static let fallback = TranscriptStyle.solid

  /// Read a stored value, falling back for anything unrecognised — an older build's
  /// spelling, or a hand-edited defaults key.
  init(stored: String) {
    self = TranscriptStyle(rawValue: stored) ?? .fallback
  }

  var stored: String { rawValue }

  var label: String {
    switch self {
    case .solid: "Solid"
    case .frosted: "Frosted"
    case .desktop: "Desktop through"
    case .glass: "Glass"
    }
  }

  /// What it costs, not what it looks like. A picker of four material names tells someone
  /// nothing they cannot see by trying all four; what they cannot see from the picker is
  /// that three of them get harder to read as the desktop behind gets busier.
  var detail: String {
    switch self {
    case .solid: "Opaque. The same contrast wherever the window sits."
    case .frosted: "Blurred and tinted. Colour from behind, not shapes."
    case .desktop: "The desktop reads through. Hardest to read over a busy wallpaper."
    case .glass: "Liquid Glass, as macOS draws it."
    }
  }

  /// Whether the window has to stop painting its own background for this to show.
  ///
  /// An opaque `NSWindow` composites its `backgroundColor` under everything, so a blur put
  /// inside it blurs that colour and nothing else — the material renders as flat grey and
  /// looks like a bug in the material rather than in the window.
  var isTranslucent: Bool { self != .solid }
}
