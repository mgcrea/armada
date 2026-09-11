import SwiftUI

/// One session in a list: state, title, project, age.
struct SessionRow: View {
  let session: Session
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      StateDot(state: session.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(session.registry.projectName)
          if let reason = session.untitledReason {
            Text("·")
            Text(reason)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      if let started = session.registry.startedAtDate {
        Text(Self.elapsed(from: started, to: now))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  /// Wall-clock age of the session, as `2h 14m` / `14m` / `43s`.
  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    let (hours, minutes) = (seconds / 3600, (seconds % 3600) / 60)
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
  }
}

struct StateDot: View {
  let state: SessionState

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: 8, height: 8)
      // A hollow ring for the inferred state, so "running a tool" does not claim
      // the same confidence as a state that came from an actual write.
      .overlay {
        if state.isBestEffort {
          Circle().stroke(state.tint, lineWidth: 1).frame(width: 13, height: 13)
        }
      }
      .frame(width: 14, height: 14)
      .help(state.isBestEffort ? "\(state.label) (inferred)" : state.label)
      .accessibilityLabel(state.label)
  }
}

struct SessionDetail: View {
  let session: Session?
  let account: Account

  var body: some View {
    Form {
      if let session {
        Section {
          LabeledContent("State") {
            HStack(spacing: 6) {
              StateDot(state: session.state)
              Text(session.state.label)
            }
          }
          if session.state.isBestEffort {
            Text(
              "Inferred from an unanswered tool_use in the transcript. Claude Code writes nothing while a tool runs, and this cannot tell a running tool from one waiting for your approval."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        Section("Session") {
          LabeledContent("Project", value: session.registry.projectName)
          LabeledContent("Folder", value: session.registry.cwd)
            .lineLimit(3)
            .truncationMode(.head)
          LabeledContent("PID", value: String(session.registry.pid))
          if let version = session.registry.version {
            LabeledContent("Claude Code", value: version)
          }
          if let entrypoint = session.registry.entrypoint {
            LabeledContent("Started from", value: entrypoint)
          }
        }
        if session.title == nil, let reason = session.untitledReason {
          Section("No title") {
            Text(reason).foregroundStyle(.secondary)
            Text(
              session.transcript == nil
                ? "A session that has never been prompted has no transcript, so there is nothing to take a title from."
                : "A resumed session gets a new id and a transcript with no title in it, and no link back to the original."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("No session selected").foregroundStyle(.secondary)
      }

      // Which folder this row came from. Cheap to show and the thing that makes
      // two accounts legible: the same project can be open in both.
      Section("Account") {
        LabeledContent("Organization", value: account.displayName)
        if let plan = account.planLabel {
          LabeledContent("Plan", value: plan)
        }
        LabeledContent("Config folder", value: account.displayPath)
          .lineLimit(2)
          .truncationMode(.head)
      }
    }
    .formStyle(.grouped)
  }
}
