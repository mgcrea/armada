import Combine
import SwiftUI

/// One Grok Build home: what its sessions have been doing.
///
/// Laid out like `CodexPaneView`, a session list beside a detail, with no usage strip: Grok keeps
/// its weekly allowance off disk, and an empty meter would suggest Armada simply has not read it.
struct GrokPaneView: View {
  let account: GrokAccount

  @State private var selection: String?
  @State private var now = Date()
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    HSplitView {
      GeometryReader { _ in sessions }
        .frame(minWidth: 320, idealWidth: 420)
      GeometryReader { _ in detail }
        .frame(minWidth: 300, idealWidth: 340)
    }
    .navigationTitle(account.displayName)
    .navigationSubtitle(subtitle)
    .onReceive(clock) { now = $0 }
    .onChange(of: account.sessions.sessions.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
  }

  @ViewBuilder private var sessions: some View {
    if account.sessions.sessions.isEmpty {
      ContentUnavailableView {
        Label(
          account.sessions.didScan ? "No recent sessions" : "Reading sessions…",
          systemImage: "sailboat")
      } description: {
        Text(
          "Nothing has run in \(account.displayName) in the last 12 hours. Start a Grok Build session and it appears here within a moment."
        )
      }
    } else {
      List(account.sessions.sessions, selection: $selection) { session in
        GrokSessionRow(session: session, now: now)
          .tag(session.id)
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let selected = account.sessions.sessions.first(where: { $0.id == selection }) {
      GrokSessionDetail(session: selected, now: now)
    } else {
      GrokOverview(account: account)
    }
  }

  private var subtitle: String {
    let live = account.sessions.liveSessions.count
    let total = account.sessions.sessions.count
    let recent = total == 1 ? "1 recent session" : "\(total) recent sessions"
    return live == 0 ? recent : "\(live) live · \(recent)"
  }
}

struct GrokSessionRow: View {
  let session: GrokSession
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      GrokStateDot(state: session.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(session.summary.projectName)
          if session.isHeadless {
            Text("·")
            Text("Headless")
          }
          if session.isFork {
            Text("·")
            Text("Fork")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        if let last = session.lastEventAt ?? session.summary.updatedAt {
          Text(SessionRow.elapsed(from: last, to: now))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help(session.state.isLive ? "Age of the last event" : "Ended this long ago")
        }
        // Context in use, as the other panes show, never the lifetime total.
        if let context = session.context {
          Text(TokenCount.short(context.used))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct GrokSessionDetail: View {
  let session: GrokSession
  let now: Date

  var body: some View {
    Form {
      Section {
        LabeledContent("State") {
          HStack(spacing: 4) {
            GrokStateDot(state: session.state)
            Text(session.state.label)
          }
        }
        LabeledContent("Folder", value: session.summary.cwd)
        if let model = session.summary.model {
          LabeledContent("Model", value: model)
        }
        if let pid = session.pid {
          LabeledContent("Process", value: String(pid))
        }
        if let created = session.summary.createdAt {
          LabeledContent("Started") {
            Text(created, format: .relative(presentation: .named))
          }
        }
      } header: {
        Text(session.displayName)
      }
      if let context = session.context {
        Section("Context") {
          ProgressView(value: Double(min(context.used, context.window)), total: Double(context.window))
          LabeledContent(
            "In use",
            value: "\(TokenCount.short(context.used)) of \(TokenCount.short(context.window))")
        }
      }
      if let usage = session.usage {
        Section("This session") {
          LabeledContent("Turns", value: String(usage.turnCount))
          LabeledContent("Tokens", value: TokenCount.short(usage.totalTokens))
          LabeledContent("Cost", value: usage.costUSD.formatted(.currency(code: "USD")))
        }
      }
      Section {
        LabeledContent("Session ID") {
          Text(session.id).textSelection(.enabled).font(.caption.monospaced())
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// The home itself, with nothing selected.
struct GrokOverview: View {
  let account: GrokAccount

  var body: some View {
    Form {
      Section {
        LabeledContent("Folder", value: account.displayPath)
        LabeledContent("Live sessions", value: String(account.sessions.liveSessions.count))
        LabeledContent("Working", value: String(account.sessions.workingCount))
      }
      Section {
        Text(
          "Grok Build keeps its weekly allowance to its own /usage screen and writes it nowhere Armada can read, so there are no plan limits here."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

struct GrokStateDot: View {
  let state: GrokSessionState

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: 8, height: 8)
      .frame(width: 14, height: 14)
      .help(state.label)
      .accessibilityLabel(state.label)
  }
}

/// One Grok Build home in the sidebar. The badge counts live sessions, as `CodexSidebarRow`'s does.
struct GrokSidebarRow: View {
  let account: GrokAccount

  var body: some View {
    HStack(spacing: 8) {
      GrokIconView(size: 18)
      Text(account.displayName)
        .lineLimit(1)
      Spacer(minLength: 4)
      if account.sessions.workingCount > 0 {
        Circle()
          .fill(GrokSessionState.working.tint)
          .frame(width: 6, height: 6)
          .help("\(account.sessions.workingCount) working")
      }
    }
    .badge(account.sessions.liveSessions.count)
    .help(account.displayPath)
  }
}

/// The Grok app icon, bundled in `Assets.xcassets` as `GrokIcon`.
///
/// The one exception to `VendorIcon`'s no-bundled-artwork rule. Grok Build is a terminal program
/// with no app bundle to ask for, and the Grok.app people do install is a Safari web app whose
/// bundle id is a per-install UUID under `com.apple.Safari.WebApp`, so there is nothing stable to
/// look up. The artwork is that web app's own icon, as grok.com serves it.
struct GrokIconView: View {
  var size: CGFloat = 16

  var body: some View {
    Image("GrokIcon")
      .resizable()
      .frame(width: size, height: size)
  }
}
