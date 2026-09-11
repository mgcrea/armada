import Combine
import SwiftUI

/// The 5-hour and 7-day plan limits.
struct UsagePaneView: View {
  @State private var tracker = UsageTracker.shared

  /// Drives the relative reset times, which are wrong the moment they stop moving.
  @State private var now = Date()
  private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      if let snapshot = tracker.snapshot, !snapshot.isEmpty {
        Form {
          Section {
            UsageMeter(title: "Session", subtitle: "5-hour window", window: snapshot.fiveHour)
            UsageMeter(title: "Weekly", subtitle: "7-day window", window: snapshot.sevenDay)
          }
          Section {
            StalenessRow(fetchedAt: snapshot.fetchedAt, now: now)
          }
        }
        .formStyle(.grouped)
      } else {
        ContentUnavailableView {
          Label("No usage data", systemImage: "gauge.with.dots.needle.bottom.50percent")
        } description: {
          Text(
            tracker.didRead
              ? "~/.claude.json has no cached usage yet. Claude Code writes it after its first API response."
              : "Reading ~/.claude.json…")
        }
      }
    }
    .navigationTitle("Usage")
    .onReceive(clock) { now = $0 }
  }
}

/// One window's meter row.
struct UsageMeter: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let window: UsageWindow?

  var body: some View {
    LabeledContent {
      if let window {
        VStack(alignment: .trailing, spacing: 4) {
          Text("\(window.utilization)%")
            .font(.title3.monospacedDigit())
            .contentTransition(.numericText())
          ProgressView(value: Double(window.utilization), total: 100)
            .progressViewStyle(.linear)
            .tint(tint(for: window.utilization))
            .frame(width: 180)
          if let resetsAt = window.resetsAt {
            Text("resets \(resetsAt, format: .relative(presentation: .named))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("—").foregroundStyle(.secondary)
      }
    } label: {
      Text(title)
      Text(subtitle)
    }
  }

  private func tint(for percent: Int) -> Color {
    switch percent {
    case ..<70: .green
    case ..<90: .orange
    default: .red
    }
  }
}

/// How old the cached figures are.
///
/// `cachedUsageUtilization` carries `fetchedAtMs` because it is a cache, not a
/// live reading: Claude Code refreshes it when an API response happens to update
/// it, which can be hours ago on an idle account. Showing the age is what stops
/// a stale percentage from reading as the current one.
struct StalenessRow: View {
  let fetchedAt: Date?
  let now: Date

  /// Below this, the numbers are current enough to state without qualification.
  private static let fresh: TimeInterval = 5 * 60
  /// Above this, they are old enough that the pane should look unsure.
  private static let stale: TimeInterval = 60 * 60

  var body: some View {
    if let fetchedAt {
      let age = now.timeIntervalSince(fetchedAt)
      LabeledContent("Last updated") {
        HStack(spacing: 6) {
          if age > Self.stale {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          Text(fetchedAt, format: .relative(presentation: .named))
            .foregroundStyle(age > Self.fresh ? .secondary : .primary)
        }
      }
      if age > Self.stale {
        Text(
          "Claude Code refreshes this cache when it next talks to the API, so these figures may be behind."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}
