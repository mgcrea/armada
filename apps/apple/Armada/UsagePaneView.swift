import AppKit
import Charts
import Combine
import SwiftUI

/// Every window of every account, in one place.
///
/// Commit c156c27 removed a Usage pane on the grounds that two numbers did not
/// justify a sidebar row, and that was right. This one answers the objection rather
/// than ignoring it: it carries the per-model windows the header strip has no room
/// for, the pace and projection for each, and the recorded history drawn as the
/// week's actual climb. The header strip stays — it is the glance; this is the look.
struct UsagePaneView: View {
  @State private var accounts = Accounts.shared
  @State private var history = UsageHistory.shared
  @State private var now = Date()

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored

  /// One second, matching `AccountPaneView`. The relative times in every caption
  /// ("resets in 3 hours") are only honest if something re-renders them.
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      if accounts.all.isEmpty {
        ContentUnavailableView {
          Label("No Claude config folder", systemImage: "folder.badge.questionmark")
        } description: {
          Text("Armada looks for ~/.claude and any ~/.claude-<name> beside it.")
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            ForEach(accounts.all) { account in
              AccountUsageCard(account: account, weights: weights, now: now)
            }
            PaceFooter(weights: weights)
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .navigationTitle("Usage")
    .navigationSubtitle(subtitle)
    .onReceive(clock) { now = $0 }
  }

  private var weights: DayWeights { DayWeights(stored: storedWeights) }

  private var subtitle: String {
    let count = accounts.all.count
    return count == 1 ? "1 account" : "\(count) accounts"
  }
}

/// One account's windows, and its week so far.
struct AccountUsageCard: View {
  let account: Account
  let weights: DayWeights
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        ClaudeIconView(size: 16)
        Text(account.displayName).font(.headline)
        if let plan = account.planLabel {
          Text(plan).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        StalenessBadge(fetchedAt: account.usage?.fetchedAt, now: now)
      }

      if let usage = account.usage, !usage.isEmpty {
        ForEach(rows(for: usage)) { row in
          WindowRow(row: row, weights: weights, fetchedAt: usage.fetchedAt, now: now)
        }
        WeeklyChart(
          accountID: account.id, window: usage.sevenDay, weights: weights,
          fetchedAt: usage.fetchedAt, now: now)
      } else {
        Text(account.didReadUsage ? "No usage data yet" : "Reading usage…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
  }

  /// One row per window the cache lists.
  ///
  /// Prefers the `limits` array, which is the only place the per-model window
  /// appears, and falls back to the two flat keys when it is missing — that array is
  /// a newer shape in the same undocumented cache, and this pane should still say
  /// something on the day it goes away.
  private func rows(for usage: UsageSnapshot) -> [WindowRowModel] {
    let fromLimits = usage.limits.compactMap { limit -> WindowRowModel? in
      guard let length = limit.length else { return nil }
      // Unscoped rows only. A refusal names `five_hour` or `seven_day`, which are
      // the account-wide windows; it says nothing about a per-model row like the
      // weekly Fable one, and correcting that to 100% would be an invention.
      let window =
        limit.scopeModelName == nil
        ? corrected(length, in: usage) ?? limit.window
        : limit.window
      return WindowRowModel(
        id: limit.id, title: limit.title, subtitle: limit.subtitle, window: window,
        length: length, isBinding: limit.isActive)
    }
    if !fromLimits.isEmpty { return fromLimits }
    return [
      corrected(.fiveHour, in: usage).map {
        WindowRowModel(
          id: "five_hour", title: "Session", subtitle: "5 hours", window: $0, length: .fiveHour,
          isBinding: false)
      },
      corrected(.sevenDay, in: usage).map {
        WindowRowModel(
          id: "seven_day", title: "Weekly", subtitle: "7 days", window: $0, length: .sevenDay,
          isBinding: false)
      },
    ].compactMap { $0 }
  }

  private func corrected(_ length: UsageWindowLength, in usage: UsageSnapshot) -> UsageWindow? {
    usage.window(length, correctedBy: account.quotaHit, now: now)
  }
}

struct WindowRowModel: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let window: UsageWindow
  let length: UsageWindowLength
  let isBinding: Bool
}

/// One window: the name, the number, the bar and the verdict.
struct WindowRow: View {
  let row: WindowRowModel
  let weights: DayWeights
  let fetchedAt: Date?
  let now: Date

  var body: some View {
    // Nothing to project from a window a refusal has already closed — see the same
    // guard in `UsageHeader` and `AccountSummary`.
    let forecast =
      row.window.rejectedAt == nil
      ? UsageForecast(
        window: row.window, length: row.length, weights: weights, asOf: fetchedAt, now: now)
      : nil
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(row.title).font(.subheadline)
        Text(row.subtitle).font(.caption2).foregroundStyle(.tertiary)
        if row.isBinding {
          // The vendor's own flag for which window is currently the constraint.
          // Worth surfacing because the binding one is usually not the biggest
          // number, and it is the only one that can actually stop you.
          Text("binding")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.18), in: .capsule)
            .help("The window Claude Code is currently measuring you against.")
        }
        Spacer(minLength: 8)
        UsageFigure(window: row.window, now: now, font: .body)
      }
      UsageBar(
        percent: row.window.utilization, forecast: forecast, height: 8,
        voided: row.window.hasRolled(asOf: now))
      UsageFootnote(window: row.window, forecast: forecast, now: now)
    }
  }
}

/// The weekly window's recorded climb, against the pace it was expected to take.
///
/// Drawn only from samples inside the current cycle — a reset is a discontinuity, and
/// a line that falls from 90% to 2% between two points is a chart lying about a drop
/// that never happened.
struct WeeklyChart: View {
  let accountID: String
  let window: UsageWindow?
  let weights: DayWeights
  let fetchedAt: Date?
  let now: Date

  /// **Enough points, over enough time, to be a line rather than a suggestion.**
  /// Two readings taken minutes apart draw a chart whose only real content is the
  /// pace line and the projection — both of which are computed, not observed. That
  /// reads as evidence and is not, which is the one thing this pane must not do. The
  /// usage cache moves slowly enough that a couple of hours is a low bar.
  private static let minimumSamples = 3
  private static let minimumSpan: TimeInterval = 2 * 60 * 60

  var body: some View {
    if let window, let resetsAt = window.resetsAt,
      let start = UsageWindowLength.sevenDay.start(before: resetsAt, calendar: .current)
    {
      let samples = UsageHistory.shared.samples(for: accountID, since: start)
        .filter { $0.w != nil }
      if samples.count >= Self.minimumSamples, let first = samples.first, let last = samples.last,
        last.t.timeIntervalSince(first.t) >= Self.minimumSpan
      {
        VStack(alignment: .leading, spacing: 4) {
          Text("This week so far").font(.caption).foregroundStyle(.secondary)
          chart(samples: samples, start: start, resetsAt: resetsAt, window: window)
            .frame(height: 110)
        }
        .padding(.top, 4)
      } else {
        // Says why there is no chart rather than leaving a gap, because "nothing
        // recorded yet" and "this feature is broken" look identical otherwise.
        Text("Recording usage — the week's chart appears once there are a few readings.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.top, 2)
      }
    }
  }

  private func chart(samples: [UsageSample], start: Date, resetsAt: Date, window: UsageWindow)
    -> some View
  {
    let forecast = UsageForecast(
      window: window, length: .sevenDay, weights: weights, asOf: fetchedAt, now: now)
    let tint = UsageTint.for(window.utilization)
    return Chart {
      RuleMark(y: .value("Limit", 100))
        .foregroundStyle(.red.opacity(0.35))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

      ForEach(paceCurve(start: start, resetsAt: resetsAt), id: \.date) { point in
        LineMark(
          x: .value("When", point.date), y: .value("Percent", point.percent),
          series: .value("Series", "pace")
        )
        .foregroundStyle(.secondary.opacity(0.6))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }

      ForEach(samples, id: \.t) { sample in
        LineMark(
          x: .value("When", sample.t), y: .value("Percent", sample.w ?? 0),
          series: .value("Series", "used")
        )
        .foregroundStyle(tint)
        .interpolationMethod(.monotone)
      }

      // The projection, dashed from the last real reading to the reset — visibly a
      // different kind of line from the recorded one.
      if let forecast, let last = samples.last {
        ForEach(
          [
            PacePoint(date: last.t, percent: Double(last.w ?? 0)),
            PacePoint(date: resetsAt, percent: forecast.projected * 100),
          ], id: \.date
        ) { point in
          LineMark(
            x: .value("When", point.date), y: .value("Percent", point.percent),
            series: .value("Series", "projected")
          )
          .foregroundStyle(tint.opacity(0.55))
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
        }
      }
    }
    .chartYScale(domain: 0...yMax(samples: samples, forecast: forecast))
    .chartXScale(domain: start...resetsAt)
    .chartYAxis { AxisMarks(values: [0, 50, 100]) }
    .chartXAxis {
      AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday()) }
    }
  }

  private func yMax(samples: [UsageSample], forecast: UsageForecast?) -> Double {
    let observed = samples.compactMap(\.w).max().map(Double.init) ?? 0
    let projected = forecast.map { min($0.projected * 100, 200) } ?? 0
    return max(100, observed, projected) * 1.05
  }

  /// The expected-consumption curve, sampled at each midnight plus both ends, so a
  /// weighted profile shows as the kinked line it is rather than a straight one.
  private func paceCurve(start: Date, resetsAt: Date) -> [PacePoint] {
    let calendar = Calendar.current
    let total = weights.consumed(from: start, to: resetsAt, calendar: calendar)
    guard total > 0 else { return [] }
    var dates = [start]
    var cursor = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
    while let next = cursor, next < resetsAt {
      dates.append(next)
      cursor = calendar.date(byAdding: .day, value: 1, to: next)
    }
    dates.append(resetsAt)
    return dates.map {
      PacePoint(
        date: $0, percent: weights.consumed(from: start, to: $0, calendar: calendar) / total * 100)
    }
  }
}

struct PacePoint: Hashable {
  let date: Date
  let percent: Double
}

/// What the pace line is being measured against, and how to change it.
struct PaceFooter: View {
  let weights: DayWeights

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "calendar")
        .foregroundStyle(.tertiary)
      Text(
        weights.isEven
          ? "Pace assumes an even week."
          : "Pace is weighted by your per-day profile."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Adjust…") { AppDelegate.shared?.showSettings() }
        .buttonStyle(.link)
        .font(.caption)
      Spacer(minLength: 0)
    }
  }
}
