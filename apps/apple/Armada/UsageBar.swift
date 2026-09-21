import SwiftUI

/// A usage meter that shows where you *should* be, not only where you are.
///
/// The one custom shape in the app, and it replaces `ProgressView(.linear)` at every
/// call site. The reason is narrow: a linear `ProgressView` renders one value, and
/// the whole point of this change is that a percentage on its own is a fact without
/// a verdict. Three of the four layers below are the verdict.
///
/// Reads, from left to right: the solid fill is spent, the ghost past it is where the
/// current rate lands by the reset, the tick and the caret above it are where the pace
/// profile says you would be, and the chevron appears only when the ghost runs off
/// the end — or, before there is a ghost, when the fill is well past the tick.
struct UsageBar: View {
  let percent: Int
  let forecast: UsageForecast?
  var height: CGFloat = 6

  /// The window this bar describes has rolled over, and nothing has read the new one
  /// yet — so draw the empty track and nothing else.
  ///
  /// **The bar is the part that misleads, more than the caption under it.** A reset
  /// that has passed means `percent` belongs to a window that is gone, and a red bar
  /// at 99% says "you are nearly out" about an allowance that is in fact untouched.
  /// The caption has said "already reset" for a while; the bar went on contradicting
  /// it. The previous figure is not lost, it moves to the tooltip at the call site.
  var voided: Bool = false

  /// Width of the pace tick. Kept as one constant because the tick is also inset by
  /// half of it at both ends, so the two uses must not drift apart.
  private static let tickWidth: CGFloat = 1.5

  /// Fixed rather than scaled with `height`: the caret is a pointer, and the meter
  /// that needs one most is the popover's, which is also the shortest.
  private static let caretWidth: CGFloat = 7
  private static let caretHeight: CGFloat = 4.5

  /// A downward triangle, apex at the bottom edge so it lands on the tick's top.
  nonisolated private struct Caret: Shape {
    func path(in rect: CGRect) -> Path {
      Path { path in
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
      }
    }
  }

  var body: some View {
    let tint = UsageTint.for(percent)
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)

        // The projection, drawn under the spent fill so the two read as one bar
        // rather than two. Clamped at the full width; the chevron carries the
        // overflow, because a bar cannot be more than full.
        if let forecast, let projected = forecast.projected, projected > forecast.used, !voided {
          Capsule()
            .fill(tint.opacity(0.28))
            .frame(width: width * min(projected, 1))
        }

        if !voided {
          Capsule()
            .fill(tint)
            .frame(width: width * min(Double(percent) / 100, 1))
        }
      }
      // The tick overhangs the track by design, and that is exactly why it is an
      // overlay rather than a fourth layer of the `ZStack`. A stack takes its size
      // from its tallest child, so a tick of `height + 3` inside it made the whole
      // bar 3pt taller — but only on the windows that had a forecast to draw one
      // from. In the menu bar popover that showed up as a 5h meter at its stated
      // 5pt beside a 7d meter at 8pt, on the same account, in the same list.
      .overlay(alignment: .leading) {
        if let forecast, !voided {
          // Inset by half the tick at each end so a marker at 0% or 100% stays
          // inside the bar instead of being clipped in half by the capsule.
          let inset = Self.tickWidth / 2
          let x = inset + (width - Self.tickWidth) * min(max(forecast.expected, 0), 1)
          // An explicit leading stack, because the overlay's `alignment` places the
          // group and not its members: left implicit, the 1.5pt tick was centred in
          // the caret's 7pt and drew 2.75pt right of where the offset put it.
          ZStack(alignment: .leading) {
            Capsule()
              .fill(.primary.opacity(0.75))
              .frame(width: Self.tickWidth, height: height + 3)
              .offset(x: x)
            // The caret is what makes the tick findable. On its own it was a 1.5pt
            // line inside the fill, a few points from the fill's end, and on a 5pt
            // popover meter it simply did not register. Pointing down from above the
            // track, it sits on the one background that never changes colour.
            Caret()
              .fill(.primary.opacity(0.75))
              .frame(width: Self.caretWidth, height: Self.caretHeight)
              .offset(
                x: x + Self.tickWidth / 2 - Self.caretWidth / 2,
                y: -(height + 3) / 2 - Self.caretHeight / 2)
          }
        }
      }
      .overlay(alignment: .trailing) {
        if forecast?.isOverrunning == true, !voided {
          Image(systemName: "chevron.compact.right")
            .font(.system(size: height + 3, weight: .bold))
            .foregroundStyle(.red)
            .offset(x: height * 0.7)
        }
      }
    }
    .frame(height: height)
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .modifier(OptionalHelp(text: paceHelp))
  }

  private var accessibilityLabel: String {
    if voided { return "window has reset, no reading since" }
    guard let forecast else { return "\(percent) percent used" }
    let pace = "\(percent) percent used, \(Int(forecast.expected * 100)) percent expected by now"
    guard let projected = forecast.projected else { return pace }
    return pace + ", projected \(Int(projected * 100)) percent at reset"
  }

  /// The gap the caret draws, in words, on hover.
  ///
  /// In the popover this is the only place it is written down: the verdict line
  /// there appears only past `UsageForecast.significantDelta`, so "3 points behind"
  /// was otherwise a distance to judge by eye on a 5pt bar.
  private var paceHelp: String? {
    guard let forecast, !voided else { return nil }
    let expected = Int((forecast.expected * 100).rounded())
    return "\(expected)% expected by now: \(Self.paceGap(forecast.deltaPoints))."
  }

  /// "4 points ahead of pace", "1 point behind pace", "on pace".
  static func paceGap(_ points: Double) -> String {
    let rounded = Int(points.rounded())
    return switch rounded {
    case 0: "on pace"
    case 1: "1 point ahead of pace"
    case -1: "1 point behind pace"
    case 2...: "\(rounded) points ahead of pace"
    default: "\(-rounded) points behind pace"
    }
  }
}

/// The percentage itself, or an em dash once the window it belonged to has gone.
///
/// Pairs with `UsageBar(voided:)` — the bar empties and the figure goes, together,
/// because a `—` beside a full red bar reads as a rendering glitch rather than as a
/// statement. The figure is not thrown away: the tooltip says what it was and when
/// its window ended, which is the one thing someone reading a blank meter wants.
struct UsageFigure: View {
  let window: UsageWindow
  let now: Date
  var font: Font = .callout

  var body: some View {
    let rolled = window.hasRolled(asOf: now)
    Text(rolled ? "—" : "\(window.utilization)%")
      .font(font.monospacedDigit())
      .contentTransition(.numericText())
      .foregroundStyle(rolled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
      // Only when there is something to explain. `.help("")` would attach an empty
      // accessibility hint to the ordinary case, which is the common one.
      .modifier(OptionalHelp(text: help(rolled: rolled)))
  }

  /// The tooltip, or nil for a figure that speaks for itself.
  private func help(rolled: Bool) -> String? {
    if rolled { return Self.rolledHelp(window) }
    if let rejectedAt = window.rejectedAt { return Self.rejectionHelp(rejectedAt) }
    return nil
  }

  private static func rolledHelp(_ window: UsageWindow) -> String {
    guard let resetsAt = window.resetsAt else { return UsageResetLine.rolledHelp }
    let moment = resetsAt.formatted(date: .omitted, time: .shortened)
    return
      "Previously \(window.utilization)%. That window ended at \(moment), and nothing has "
      + "reported the new one since."
  }

  /// Why a figure can be higher than the cache says. Only ever seen on a window a
  /// request was actually refused from, which is the one reading here that is not a
  /// cached copy of someone else's number.
  static func rejectionHelp(_ at: Date) -> String {
    "A request was refused for hitting this limit at "
      + "\(at.formatted(date: .omitted, time: .shortened)), so the window is spent — "
      + "whatever Claude Code's older cached figure says."
  }
}

/// `.help()` only when there is a string for it.
private struct OptionalHelp: ViewModifier {
  let text: String?

  func body(content: Content) -> some View {
    if let text { content.help(text) } else { content }
  }
}

/// When this window resets.
///
/// **Always rendered, in the same place, whatever else is said about the window.**
/// The reset is the fact every other line is relative to — "12 points ahead of pace"
/// means nothing until you know whether the window turns over tonight or on Monday.
/// An earlier cut of this let the verdict take the caption's place, which silently
/// dropped the reset in three of its five cases; that is why this is its own view
/// rather than one branch of a caption.
///
/// **`now` is a required property, not `Date.now` read inside the body.** A relative
/// time computed from the clock at evaluation time is right once and then silently
/// rots: the menu bar popover has no pane around it pushing state in, so its copy of
/// this line sat on "resets in 20m" long after the window had gone. Making the
/// caller supply a tick means a view that does not have one cannot compile.
struct UsageResetLine: View {
  let window: UsageWindow?
  let now: Date
  var style: Style = .full

  /// `.compact` is for the menu bar popover, where the reset sits at the end of a
  /// row beside the bar. It renders the same instant as "in 19h" where the panes say
  /// "in 19 hours", and it lets a clock glyph say "resets" — which is what keeps the
  /// row short enough to leave the bar room.
  enum Style { case full, compact }

  private static let compactFormat = Date.RelativeFormatStyle(
    presentation: .numeric, unitsStyle: .narrow)

  var body: some View {
    if let window, let resetsAt = window.resetsAt {
      let rolled = window.hasRolled(asOf: now)
      Group {
        if rolled {
          // A reset in the past is not a reset "11 hours ago" — it means the cached
          // percentage belongs to a window that no longer exists. Observed on
          // 2026-09-10, when the cache was written two minutes after the five-hour
          // window it described had rolled.
          if style == .full {
            Text("window has since reset")
          } else {
            compact("clock.arrow.circlepath", Text("reset"), label: "already reset")
          }
        } else if style == .full {
          Text("resets in \(Self.countdown(from: now, to: resetsAt))")
        } else {
          compact("clock", Text(resetsAt, format: Self.compactFormat), label: "resets")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      // The exact moment on hover, spelled out in full. The countdown answers "can
      // I finish this today"; the weekday and date answer "what do I move it to",
      // and an abbreviated "20 Sep" made that a second piece of arithmetic.
      .help(help(rolled: rolled, resetsAt: resetsAt))
    }
  }

  /// A glyph in place of the word "resets".
  ///
  /// **The word was the longest fixed thing on a row whose bar wanted the space.**
  /// "resets in 19h" is about 66pt at `.caption2` and six of those points are a verb
  /// that never changes, on a row that already reads as a meter. The clock says it in
  /// ten, the tooltip still spells the moment out, and the accessibility label keeps
  /// the word for anyone not looking at the glyph.
  private func compact(_ symbol: String, _ text: Text, label: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol)
        .imageScale(.small)
        .accessibilityLabel(label)
      text
    }
  }

  private func help(rolled: Bool, resetsAt: Date) -> String {
    if rolled { return Self.rolledHelp }
    let moment = "Resets \(resetsAt.formatted(date: .complete, time: .shortened))"
    guard let rejectedAt = window?.rejectedAt else { return moment }
    return "\(moment). " + UsageFigure.rejectionHelp(rejectedAt)
  }

  /// How long is left, to two units — "6 days, 23 hours", not "in 6 days".
  ///
  /// **The last day of a weekly window is the one worth planning around, and a
  /// single unit rounds it away.** "in 6 days" covers everything from six days to
  /// nearly seven, which is the difference between an allowance that turns over
  /// before Monday's work and one that does not. Two units settle that; a third is
  /// noise on a caption, so the fields narrow as the interval does — and a field
  /// worth zero is dropped, so a window six days and four minutes out says "6 days"
  /// rather than "6 days, 0 hours".
  static func countdown(from now: Date, to resetsAt: Date) -> String {
    let fields: Set<Date.ComponentsFormatStyle.Field> =
      switch resetsAt.timeIntervalSince(now) {
      case 86400...: [.day, .hour]
      case 3600...: [.hour, .minute]
      case 60...: [.minute]
      default: [.second]
      }
    // Safe against a reset in the past only because the caller branches on
    // `hasRolled` first: `now..<resetsAt` traps on a reversed range.
    return (now..<resetsAt).formatted(.components(style: .wide, fields: fields))
  }

  /// Vendor-neutral on purpose: the same line now sits under Codex meters, where
  /// the figures come from a session log rather than from Claude Code's cache. The
  /// tooltip's job is to say the number is the previous window's, and naming the
  /// mechanism was never part of that.
  static let rolledHelp =
    "This window reset after these figures were recorded, so the percentage above is the previous window's."
}

/// What the window is on course to do — the verdict, never the reset.
///
/// Every projected figure is prefixed with `~` and carries a `.help()` naming the
/// assumption behind it, matching how the rest of the app labels what it inferred
/// rather than read — `SessionState.isBestEffort` draws a hollow ring, and
/// `StalenessBadge` shows the cache's age.
struct UsageVerdictLine: View {
  let forecast: UsageForecast?

  var body: some View {
    // A window nothing has been spent from has no rate to project and nothing worth
    // saying about it: "100% unused" on a model you simply have not used reads as a
    // warning about a non-event. The reset line above still says when it turns over.
    if let forecast, forecast.used > 0 {
      switch forecast.verdict {
      case .exhausting(let date):
        line(
          "At this rate, 100% \(date, format: .relative(presentation: .named))", .orange,
          help: "Projected from the rate so far in this window.")
      case .ahead(let points):
        line("\(Int(points.rounded())) points ahead of pace", .orange, help: Self.paceHelp)
      case .forfeiting(let points):
        // Says only what is lost: the reset it is lost at is on the line above.
        line(
          "~\(Int(points.rounded()))% will go unused", .secondary,
          help: "Unused allowance does not carry over to the next week.")
      case .onPace:
        if let projected = forecast.projected {
          line(
            "~\(Int((projected * 100).rounded()))% by reset", .secondary,
            help: "Projected from the rate so far in this window.")
        } else {
          // Too early in the window to project from, which is exactly when the gap
          // to the marker is the one thing worth reading.
          line(
            LocalizedStringKey(UsageBar.paceGap(forecast.deltaPoints)), .secondary,
            help: Self.paceHelp)
        }
      }
    }
  }

  private func line(_ text: LocalizedStringKey, _ style: Color, help: String) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(style)
      .lineLimit(1)
      .help(help)
  }

  private static let paceHelp =
    "Compared with the share of the window that has elapsed. The weekly window is weighted by the days and working hours set in Settings."
}

/// The two lines under a meter: when it resets, and what it is on course to do.
struct UsageFootnote: View {
  let window: UsageWindow?
  let forecast: UsageForecast?
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      UsageResetLine(window: window, now: now)
      UsageVerdictLine(forecast: forecast)
    }
  }
}
