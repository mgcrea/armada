import SwiftUI

/// A usage meter that shows where you *should* be, not only where you are.
///
/// The one custom shape in the app, and it replaces `ProgressView(.linear)` at every
/// call site. The reason is narrow: a linear `ProgressView` renders one value, and
/// the whole point of this change is that a percentage on its own is a fact without
/// a verdict. Three of the four layers below are the verdict.
///
/// Reads, from left to right: the solid fill is spent, the ghost past it is where the
/// current rate lands by the reset, the tick is where the pace profile says you would
/// be, and the chevron appears only when the ghost runs off the end.
struct UsageBar: View {
  let percent: Int
  let forecast: UsageForecast?
  var height: CGFloat = 6
  /// Width of the pace tick. Kept as one constant because the tick is also inset by
  /// half of it at both ends, so the two uses must not drift apart.
  private static let tickWidth: CGFloat = 1.5

  var body: some View {
    let tint = UsageTint.for(percent)
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)

        // The projection, drawn under the spent fill so the two read as one bar
        // rather than two. Clamped at the full width; the chevron carries the
        // overflow, because a bar cannot be more than full.
        if let forecast, forecast.projected > forecast.used {
          Capsule()
            .fill(tint.opacity(0.28))
            .frame(width: width * min(forecast.projected, 1))
        }

        Capsule()
          .fill(tint)
          .frame(width: width * min(Double(percent) / 100, 1))

        if let forecast {
          // Inset by half the tick at each end so a marker at 0% or 100% stays
          // inside the bar instead of being clipped in half by the capsule.
          let inset = Self.tickWidth / 2
          Capsule()
            .fill(.primary.opacity(0.55))
            .frame(width: Self.tickWidth, height: height + 3)
            .offset(x: inset + (width - Self.tickWidth) * min(max(forecast.expected, 0), 1))
        }
      }
      .overlay(alignment: .trailing) {
        if let forecast, forecast.projected > 1 {
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
  }

  private var accessibilityLabel: String {
    guard let forecast else { return "\(percent) percent used" }
    return
      "\(percent) percent used, \(Int(forecast.expected * 100)) percent expected by now, "
      + "projected \(Int(forecast.projected * 100)) percent at reset"
  }
}

/// The one line worth saying under a meter.
///
/// Every projected figure is prefixed with `~` and carries a `.help()` naming the
/// assumption behind it, matching how the rest of the app labels what it inferred
/// rather than read — `SessionState.isBestEffort` draws a hollow ring, and
/// `StalenessBadge` shows the cache's age.
struct UsageCaption: View {
  let window: UsageWindow?
  let forecast: UsageForecast?

  var body: some View {
    // A window nothing has been spent from has no rate to project and nothing worth
    // saying about it: "100% unused" on a model you simply have not used reads as a
    // warning about a non-event. The reset time is the honest line.
    if let forecast, forecast.used > 0 {
      switch forecast.verdict {
      case .exhausting(let date):
        line(
          "At this rate, 100% \(date, format: .relative(presentation: .named))", .orange,
          help:
            "Projected from the rate so far in this window. It resets \(relative(forecast.resetsAt))."
        )
      case .ahead(let points):
        line("\(Int(points.rounded())) points ahead of pace", .orange, help: paceHelp)
      case .forfeiting(let points):
        line(
          "Resets \(forecast.resetsAt, format: .relative(presentation: .named)) with \(Int(points.rounded()))% unused",
          .secondary,
          help: "Unused allowance does not carry over to the next week.")
      case .onPace:
        line(
          "~\(Int((forecast.projected * 100).rounded()))% by reset", .secondary,
          help: "Projected from the rate so far in this window.")
      }
    } else if let resetsAt = window?.resetsAt {
      // No forecast: nothing spent yet, too early in the window, the cache is stale,
      // or the window has already rolled. The reset time is the one thing still true.
      if resetsAt < .now {
        // A reset in the past is not a reset "11 hours ago" — it means the cached
        // percentage belongs to a window that no longer exists, and the figure above
        // is the previous window's. Observed on 2026-09-10, when the cache was
        // written two minutes after the five-hour window it described had rolled.
        line("window has since reset", .secondary, help: helpForRolled)
      } else {
        line("resets \(resetsAt, format: .relative(presentation: .named))", .secondary, help: nil)
      }
    }
  }

  private func line(_ text: LocalizedStringKey, _ style: Color, help: String?) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(style)
      .lineLimit(1)
      .help(help ?? "")
  }

  private var helpForRolled: String {
    "This window reset after Claude Code last refreshed its cache, so the percentage above is the previous window's."
  }

  private var paceHelp: String {
    "Compared with the share of the window that has elapsed, weighted by your per-day profile in Settings."
  }

  private func relative(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named))
  }
}
