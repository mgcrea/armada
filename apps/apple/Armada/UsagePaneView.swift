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
  @State private var codex = CodexAccounts.shared
  @State private var grok = GrokAccounts.shared
  @State private var history = UsageHistory.shared
  @State private var now = AppClock.now

  @AppStorage(DayWeights.defaultsKey) private var storedWeights = DayWeights.evenStored
  @AppStorage(WorkingHours.defaultsKey) private var storedHours = WorkingHours.flatStored

  /// One second, matching `AccountPaneView`. The relative times in every caption
  /// ("resets in 3 hours") are only honest if something re-renders them.
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      if accounts.all.isEmpty && codex.isEmpty && grok.isEmpty {
        ContentUnavailableView {
          Label("No agents found", systemImage: "folder.badge.questionmark")
        } description: {
          Text(
            "Armada looks for ~/.claude and any ~/.claude-<name> beside it, for ~/.codex, and for ~/.grok."
          )
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            ForEach(accounts.all) { account in
              AccountUsageCard(account: account, profile: profile, now: now)
            }
            // After the Claude cards, in the sidebar's order. Not interleaved and not
            // merged: these are separate plans from separate vendors, and the one
            // thing this pane must never invite is reading two vendors' percentages
            // as one budget.
            ForEach(codex.all) { account in
              CodexUsageCard(account: account, profile: profile, now: now)
            }
            ForEach(grok.all) { account in
              GrokUsageCard(account: account, profile: profile, now: now)
            }
            PaceFooter(profile: profile)
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .navigationTitle("Usage")
    .navigationSubtitle(subtitle)
    .onReceive(clock) { _ in now = AppClock.now }
  }

  private var profile: PaceProfile {
    PaceProfile(storedDays: storedWeights, storedHours: storedHours)
  }

  /// Counts cards, not accounts, and says so in the vendors' own words when they
  /// differ — "3 accounts" over two Claude organizations and a Codex home is three
  /// of nothing in particular.
  private var subtitle: String {
    let claude = accounts.all.count
    let codexCount = codex.all.count
    let grokCount = grok.all.count
    if codexCount == 0 && grokCount == 0 {
      return claude == 1 ? "1 account" : "\(claude) accounts"
    }
    return [
      claude == 0 ? nil : claude == 1 ? "1 Claude account" : "\(claude) Claude accounts",
      codexCount == 0 ? nil : codexCount == 1 ? "1 Codex home" : "\(codexCount) Codex homes",
      grokCount == 0 ? nil : grokCount == 1 ? "1 Grok Build home" : "\(grokCount) Grok Build homes",
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

/// One account's windows, and its week so far.
struct AccountUsageCard: View {
  let account: Account
  let profile: PaceProfile
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
        StalenessBadge(
          fetchedAt: account.usage?.fetchedAt, now: now,
          source: account.usage?.source ?? .cache)
      }

      if let usage = account.usage, !usage.isEmpty {
        ForEach(rows(for: usage)) { row in
          WindowRow(row: row, profile: profile, fetchedAt: usage.fetchedAt, now: now)
        }
        WeeklyChart(
          accountID: account.id, window: usage.sevenDay, profile: profile,
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
        length: length, isBinding: limit.isActive,
        menuBarLimit: MenuBarLimit(
          accountID: account.id, length: length, model: limit.scopeModelName))
    }
    if !fromLimits.isEmpty { return fromLimits }
    return [
      corrected(.fiveHour, in: usage).map {
        WindowRowModel(
          id: "five_hour", title: "Session", subtitle: "5 hours", window: $0, length: .fiveHour,
          isBinding: false, menuBarLimit: MenuBarLimit(accountID: account.id, length: .fiveHour))
      },
      corrected(.sevenDay, in: usage).map {
        WindowRowModel(
          id: "seven_day", title: "Weekly", subtitle: "7 days", window: $0, length: .sevenDay,
          isBinding: false, menuBarLimit: MenuBarLimit(accountID: account.id, length: .sevenDay))
      },
    ].compactMap { $0 }
  }

  private func corrected(_ length: UsageWindowLength, in usage: UsageSnapshot) -> UsageWindow? {
    usage.window(length, correctedBy: account.quotaHit, now: now)
  }
}

/// One Codex home's windows, and its week so far.
///
/// Deliberately the same card as `AccountUsageCard`, down to the row heights, and it
/// reuses every part below the header — `CodexRateLimits.asSnapshot` hands the shared
/// views the shape they already take. What differs is only what genuinely differs
/// between the vendors:
///
/// - **no `limits` array**, so two flat windows rather than a per-model breakdown;
/// - **no quota correction**, because a refusal is read out of a Claude transcript
///   and Codex's logs have not been mined for the equivalent;
/// - **no "binding" flag**, which is Claude's own marker for the window it is
///   measuring you against.
struct CodexUsageCard: View {
  let account: CodexAccount
  let profile: PaceProfile
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        CodexIconView(size: 16)
        Text(account.displayName).font(.headline)
        if let plan = account.planLabel {
          Text(plan).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        StalenessBadge(fetchedAt: account.usage?.observedAt, now: now, source: .sessionLog)
      }

      if let usage = account.usage, !usage.isEmpty {
        let snapshot = usage.asSnapshot
        ForEach(rows(for: snapshot)) { row in
          WindowRow(row: row, profile: profile, fetchedAt: snapshot.fetchedAt, now: now)
        }
        WeeklyChart(
          accountID: account.id, window: snapshot.sevenDay, profile: profile,
          fetchedAt: snapshot.fetchedAt, now: now)
      } else {
        Text(account.sessions.didScan ? "No usage reported yet" : "Reading usage…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
  }

  private func rows(for snapshot: UsageSnapshot) -> [WindowRowModel] {
    [
      snapshot.fiveHour.map {
        WindowRowModel(
          id: "codex-five-hour", title: "Session", subtitle: "5 hours", window: $0,
          length: .fiveHour, isBinding: false,
          menuBarLimit: MenuBarLimit(accountID: account.id, length: .fiveHour))
      },
      snapshot.sevenDay.map {
        WindowRowModel(
          id: "codex-seven-day", title: "Weekly", subtitle: "7 days", window: $0,
          length: .sevenDay, isBinding: false,
          menuBarLimit: MenuBarLimit(accountID: account.id, length: .sevenDay))
      },
    ].compactMap { $0 }
  }
}

/// One Grok Build home's allowance, and its week so far.
///
/// `CodexUsageCard`'s shape with one row: Grok has a single credit allowance across every model,
/// weekly on the plan measured. A monthly period has no `UsageWindowLength` to pace against, so
/// it shows as a plain figure.
struct GrokUsageCard: View {
  let account: GrokAccount
  let profile: PaceProfile
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        GrokIconView(size: 16)
        Text(account.displayName).font(.headline)
        if let plan = account.planLabel {
          Text(plan).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        StalenessBadge(fetchedAt: account.usage?.observedAt, now: now, source: .live)
      }

      if let usage = account.usage {
        if let window = usage.window(.sevenDay) {
          WindowRow(
            row: WindowRowModel(
              id: "grok-seven-day", title: "Weekly", subtitle: "7 days", window: window,
              length: .sevenDay, isBinding: false,
              menuBarLimit: MenuBarLimit(accountID: account.id, length: .sevenDay)),
            profile: profile, fetchedAt: usage.observedAt, now: now)
          WeeklyChart(
            accountID: account.id, window: window, profile: profile, fetchedAt: usage.observedAt,
            now: now)
        } else {
          Text("\(usage.utilization)% of the \(usage.period ?? "current") allowance used")
            .font(.callout)
        }
      } else {
        Text("Reading usage…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
  }
}

struct WindowRowModel: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let window: UsageWindow
  let length: UsageWindowLength
  let isBinding: Bool
  let menuBarLimit: MenuBarLimit
}

/// One window: the name, the number, the bar and the verdict.
struct WindowRow: View {
  let row: WindowRowModel
  let profile: PaceProfile
  let fetchedAt: Date?
  let now: Date

  @State private var hovering = false

  var body: some View {
    // Nothing to project from a window a refusal has already closed — see the same
    // guard in `UsageHeader` and `AccountSummary`.
    let forecast =
      row.window.rejectedAt == nil
      ? UsageForecast(
        window: row.window, length: row.length, profile: profile, asOf: fetchedAt, now: now)
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
        MenuBarStar(limit: row.menuBarLimit, rowHovered: hovering)
        Spacer(minLength: 8)
        UsageFigure(window: row.window, now: now, font: .body)
      }
      // 11pt for the reason `CompactMeter` gives: the tick used to add 3pt to
      // whatever the track asked for, and this pane was sized against the result.
      UsageBar(
        percent: row.window.utilization, forecast: forecast, height: 11,
        voided: row.window.hasRolled(asOf: now))
      UsageFootnote(window: row.window, forecast: forecast, now: now)
    }
    // The whole row, gaps included, or the star only appears over the text.
    .contentShape(.rect)
    .onHover { hovering = $0 }
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
  let profile: PaceProfile
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
      window: window, length: .sevenDay, profile: profile, asOf: fetchedAt, now: now)
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
      if let projected = forecast?.projected, let last = samples.last {
        ForEach(
          [
            PacePoint(date: last.t, percent: Double(last.w ?? 0)),
            PacePoint(date: resetsAt, percent: projected * 100),
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
    let projected = forecast?.projected.map { min($0 * 100, 200) } ?? 0
    return max(100, observed, projected) * 1.05
  }

  /// The expected-consumption curve through every boundary of the profile, so the day
  /// weights show as kinks and nights weighted down as flat stretches.
  ///
  /// One walk, summed as it goes. The pane re-renders every second, and asking
  /// `consumed(from: start)` afresh for each of the twenty-odd points a week of working
  /// hours has would walk the whole week that many times per tick.
  private func paceCurve(start: Date, resetsAt: Date) -> [PacePoint] {
    let calendar = Calendar.current
    var points = [PacePoint(date: start, percent: 0)]
    var cursor = start
    var total: Double = 0
    for next in profile.boundaries(from: start, to: resetsAt, calendar: calendar) {
      total += profile.weight(at: cursor, calendar: calendar) * next.timeIntervalSince(cursor)
      points.append(PacePoint(date: next, percent: total))
      cursor = next
    }
    guard total > 0 else { return [] }
    return points.map { PacePoint(date: $0.date, percent: $0.percent / total * 100) }
  }
}

struct PacePoint: Hashable {
  let date: Date
  let percent: Double
}

/// What the pace line is being measured against, and how to change it.
struct PaceFooter: View {
  let profile: PaceProfile

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "calendar")
        .foregroundStyle(.tertiary)
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Adjust…") { AppDelegate.shared?.showSettings() }
        .buttonStyle(.link)
        .font(.caption)
      Spacer(minLength: 0)
    }
  }

  private var caption: LocalizedStringKey {
    switch (profile.days.isEven, profile.hours.isFlat) {
    case (true, true): "Pace assumes an even week."
    case (false, true): "Pace is weighted by your per-day profile."
    case (true, false): "Pace is weighted by your working hours."
    case (false, false): "Pace is weighted by your days and working hours."
    }
  }
}
