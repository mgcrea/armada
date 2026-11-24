import BuildSlotCore
import SwiftUI

/// Settings ▸ Build Slots: the switch that installs the `swift` and `xcodebuild` shims, how many
/// builds run at once, the memory rule, and the queue as it stands.
///
/// The two wait caps in `settings.json` have no control here: they are the tool's safety net,
/// not something to tune.
struct BuildSlotsPane: View {
  @State private var buildSlots = BuildSlots.shared
  @State private var monitor = BuildSlotMonitor.shared

  var body: some View {
    Form {
      Section {
        Toggle(isOn: Binding(get: { buildSlots.isEnabled }, set: { buildSlots.setEnabled($0) })) {
          Text("Queue builds")
          Text(
            "Puts `swift` and `xcodebuild` shims in ~/.local/bin, so `swift build`, `swift test` and `xcodebuild` builds and tests from every agent and terminal on this Mac wait for a free slot."
          )
        }
        if !buildSlots.installsShims {
          Text(
            "Debug builds don't install the shims; run this build's `Contents/Helpers/buildslot install` to test them."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if buildSlots.isEnabled {
          if let warning = buildSlots.pathWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
          ForEach(buildSlots.installReport?.refused ?? [], id: \.self) { tool in
            Label(
              "~/.local/bin/\(tool.rawValue) was not written by Armada, so it was left alone.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
          }
          if let error = buildSlots.installReport?.error {
            Label("The shims could not be installed: \(error).", systemImage: "xmark.octagon")
              .foregroundStyle(.red)
          }
        }
      } footer: {
        Text("Xcode's own builds, `xcrun swift` and `swift run` don't queue.")
      }

      Section {
        Stepper(value: $buildSlots.settings.slots, in: BuildSlotSettings.slotRange) {
          LabeledContent("Slots", value: "\(buildSlots.settings.slots)")
        }
        Picker("Memory", selection: $buildSlots.settings.memoryRule) {
          ForEach(MemoryRule.allCases, id: \.self) { rule in
            Text(Self.label(rule)).tag(rule)
          }
        }
        if let error = buildSlots.settingsError {
          Text("Armada could not save these settings: \(error)")
            .font(.caption)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Limits")
      } footer: {
        Text(
          "Slots is how many builds and tests run at once. A build waiting on memory starts only while another slot is held, so one always runs."
        )
      }

      Section {
        if monitor.holders.isEmpty && monitor.waiters.isEmpty {
          Text("Nothing is building.").foregroundStyle(.secondary)
        } else {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            ForEach(monitor.holders + monitor.waiters) { entry in
              BuildSlotEntryRow(entry: entry, now: context.date)
            }
          }
        }
      } header: {
        Text("Queue")
      } footer: {
        Text("Memory pressure is \(monitor.pressure.word).")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Build Slots")
    .task { buildSlots.checkPath() }
  }

  static func label(_ rule: MemoryRule) -> String {
    switch rule {
    case .off: "Off"
    case .critical: "Wait while critical"
    case .warning: "Wait while under pressure"
    }
  }
}

/// One holder or waiter: who, what, how long, and for which session.
private struct BuildSlotEntryRow: View {
  let entry: MonitoredEntry
  let now: Date

  private var state: String {
    // As stored, the number the shim prints in "got slot N".
    if let slot = entry.slot { return "Slot \(slot)" }
    return entry.waitsOnMemory ? "Waiting on memory" : "Waiting"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack {
        Text(entry.record.label)
        Spacer()
        Text(state).foregroundStyle(entry.isHolding ? .primary : .secondary)
      }
      Text(
        [entry.command, entry.age(at: now), entry.session?.title ?? "Terminal"]
          .filter { !$0.isEmpty }
          .joined(separator: " · ")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
