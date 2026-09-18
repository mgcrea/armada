import AppKit
import SwiftUI

/// Reading one session's transcript, kept off the main actor until it is a list of rows.
///
/// A whole transcript costs 16ms for 6MB and 32ms for 24MB (measured 2026-09-18), which is
/// small enough that this needs no offset index and no paging — the file is read once, whole,
/// and the view never touches disk again except to reopen a single cut entry.
///
/// It is still not main-actor work: 32ms is two dropped frames, and the read itself is
/// unbounded on a file nobody has measured yet. `load` hands both to a detached task.
@Observable
final class TranscriptReader {
  private(set) var entries: [TranscriptLog.Entry] = []
  private(set) var isLoading = false
  private(set) var failure: String?
  private(set) var url: URL?

  /// Entries the person has opened out. Ids rather than indices: a live tail appends, and an
  /// index-keyed set would silently move what is expanded.
  var expanded: Set<String> = []
  /// Full text for the entries that were cut, filled in only when one is opened.
  private(set) var reopened: [String: String] = [:]

  /// Where the tail read should resume. The file grows; nothing before this is re-parsed.
  private var readThrough = 0

  func load(_ url: URL) {
    guard url != self.url else { return }
    self.url = url
    entries = []
    expanded = []
    reopened = [:]
    readThrough = 0
    isLoading = true
    failure = nil

    Task {
      let loaded = await Task.detached(priority: .userInitiated) {
        TranscriptLog.whole(of: url)
      }.value
      guard url == self.url else { return }  // a different session was picked meanwhile
      if let loaded {
        entries = loaded
        readThrough = loaded.last?.line.upperBound ?? 0
      } else {
        failure = "\(url.lastPathComponent) could not be read."
      }
      isLoading = false
    }
  }

  /// Take whatever has been appended since the last read.
  ///
  /// **Appends, never rebuilds.** A 64KB tail parses in 0.3ms, so this is cheap enough to
  /// run on every FSEvents write the way `SessionWatcher` already does for the title — but
  /// only if what it produces is diffed rather than assigned. Reassigning `entries` would
  /// hand `ForEach` a whole new array and rebuild every visible row on every write.
  func refresh() {
    guard let url, !isLoading else { return }
    Task {
      let tail = await Task.detached(priority: .utility) {
        TranscriptLog.tail(of: url, bytes: 64 * 1024)
      }.value
      guard let tail, url == self.url else { return }
      let known = Set(entries.map(\.id))
      let fresh = tail.filter { $0.line.lowerBound >= readThrough && !known.contains($0.id) }
      guard !fresh.isEmpty else { return }
      entries.append(contentsOf: fresh)
      readThrough = fresh.last?.line.upperBound ?? readThrough
    }
  }

  func isExpanded(_ entry: TranscriptLog.Entry) -> Bool { expanded.contains(entry.id) }

  /// What to draw for an entry: the cut text, or the whole thing once it has been asked for.
  func text(for entry: TranscriptLog.Entry) -> String {
    reopened[entry.id] ?? entry.text
  }

  func toggle(_ entry: TranscriptLog.Entry) {
    if expanded.remove(entry.id) != nil { return }
    expanded.insert(entry.id)
    // One seek and one line, measured at 0.1–0.3ms even for the largest entry in a 24MB
    // transcript — cheaper than the hop off the main actor and back would cost.
    if entry.truncated, reopened[entry.id] == nil, let url,
      let full = TranscriptLog.fullText(of: entry, in: url)
    {
      reopened[entry.id] = full
    }
  }
}

/// One session's conversation.
///
/// A `List`, not a `ScrollView` + `LazyVStack`. On macOS `List` is AppKit-table-backed and
/// recycles its rows; `LazyVStack` builds lazily but holds layout state for everything it has
/// ever shown, so a long scroll back through a transcript grows without bound.
/// `VoiceConversationView` uses the other one and is right to — it holds a handful of
/// exchanges, and a transcript is three orders of magnitude away from that.
struct TranscriptPane: View {
  let url: URL
  let title: String

  @State private var reader = TranscriptReader()
  @State private var showThinking = true
  @State private var showTools = true

  @AppStorage(TranscriptStyle.defaultsKey) private var storedStyle = TranscriptStyle.fallback.stored

  private var style: TranscriptStyle { TranscriptStyle(stored: storedStyle) }

  private var visible: [TranscriptLog.Entry] {
    reader.entries.filter { entry in
      switch entry.kind {
      case .thinking: showThinking
      case .toolUse, .toolResult: showTools
      default: true
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      content
      Divider()
      footer
    }
    .navigationTitle(title)
    .background(TranscriptBackground(style: style))
    .onAppear { reader.load(url) }
    .onChange(of: url) { reader.load(url) }
  }

  @ViewBuilder private var content: some View {
    if reader.isLoading {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let failure = reader.failure {
      ContentUnavailableView(
        "Nothing to Read", systemImage: "doc.questionmark", description: Text(failure))
    } else if reader.entries.isEmpty {
      ContentUnavailableView(
        "Never Prompted", systemImage: "text.bubble",
        description: Text("This session has no transcript yet."))
    } else {
      List {
        ForEach(visible) { entry in
          EntryRow(
            entry: entry, text: reader.text(for: entry), isExpanded: reader.isExpanded(entry)
          ) {
            reader.toggle(entry)
          }
          .listRowSeparator(.hidden)
          .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
          .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      // The window opens at the end, which is where a transcript is read from.
      .defaultScrollAnchor(.bottom)
      // Let the window's material through. Without this the List paints its own
      // background over the blur and every style looks like Solid.
      .scrollContentBackground(.hidden)
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Toggle("Thinking", isOn: $showThinking).toggleStyle(.checkbox)
      Toggle("Tools", isOn: $showTools).toggleStyle(.checkbox)
      Spacer(minLength: 12)
      Text("\(visible.count) of \(reader.entries.count)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Button("Refresh") { reader.refresh() }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    // `.bar` is itself a material and reads correctly over any of the four.
    .background(.bar)
  }
}

/// The window's material, behind everything.
///
/// `NSVisualEffectView` for the first three and SwiftUI's own glass for the fourth, because
/// they are genuinely different things: the effect view is a blur of what is behind the
/// window, and Liquid Glass is a lensing material macOS 26 draws itself. There is no
/// `NSVisualEffectView.Material` that means "glass", and faking one would be a worse
/// frosted rather than a glass.
private struct TranscriptBackground: View {
  let style: TranscriptStyle

  var body: some View {
    switch style {
    case .solid:
      // Named rather than left to the window: the window is transparent whenever any other
      // style has been picked, and this has to put the background back.
      Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    case .frosted:
      VisualEffect(material: .sidebar).ignoresSafeArea()
    case .desktop:
      VisualEffect(material: .underWindowBackground).ignoresSafeArea()
    case .glass:
      Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea()
    }
  }
}

/// An `NSVisualEffectView`, which SwiftUI has no first-class equivalent of.
///
/// `.behindWindow` blending, which is the one that samples the desktop and the windows under
/// this one; `.withinWindow` would sample Armada's own content and render as nothing here,
/// since this view *is* the bottom of the window.
///
/// `state: .active` rather than `.followsWindowActiveState`: a transcript being read beside
/// the editor it is about is nearly always in an inactive window, and the system's inactive
/// appearance flattens the material to a grey that looks like the setting failed.
private struct VisualEffect: NSViewRepresentable {
  let material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.state = .active
    view.material = material
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
  }
}

/// One row.
///
/// `Equatable`, and the conformance is the point: `List` re-evaluates a visible row's body
/// whenever anything above it changes, and a transcript row's body is text layout. Comparing
/// four fields is cheaper than laying out 2KB again.
private struct EntryRow: View, Equatable {
  let entry: TranscriptLog.Entry
  let text: String
  let isExpanded: Bool
  let toggle: () -> Void

  static func == (a: EntryRow, b: EntryRow) -> Bool {
    a.entry.id == b.entry.id && a.text == b.text && a.isExpanded == b.isExpanded
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      header
      body(of: entry)
      if entry.truncated {
        Button(isExpanded ? "Show less" : "Show all \(size)", action: toggle)
          .buttonStyle(.link)
          .font(.caption)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).foregroundStyle(tint).font(.caption)
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
      if let at = entry.at {
        // The timestamp is a raw ISO8601 string and stays one until a row is on screen.
        // Thirty conversions rather than two thousand — see `TranscriptLog.Entry.at`.
        Text(at.dropFirst(11).prefix(8))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private func body(of entry: TranscriptLog.Entry) -> some View {
    switch entry.kind {
    case .toolUse:
      Text(text)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(isExpanded ? nil : 2)
        .textSelection(.enabled)
    case .toolResult:
      Text(text)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        // Collapsed by default: a tool result is context for the turn around it, and a
        // 2KB one unfolded pushes the conversation off the screen.
        .lineLimit(isExpanded ? nil : 6)
        .textSelection(.enabled)
    case .thinking:
      Text(text)
        .font(.callout.italic())
        .foregroundStyle(.secondary)
        .lineLimit(isExpanded ? nil : 4)
        .textSelection(.enabled)
    case .user:
      Text(text)
        .font(.body.weight(.medium))
        .textSelection(.enabled)
    case .assistant:
      // Plain text, not markdown. `AttributedString(markdown:)` per row costs real time on
      // the main actor, and plain text is also the answer to rendering hostile transcript
      // content: there is no link, no image and no remote fetch in a `Text`.
      Text(text).textSelection(.enabled)
    case .notice:
      Label(text, systemImage: "arrow.triangle.merge")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  private var size: String {
    ByteCountFormatter.string(fromByteCount: Int64(entry.fullBytes), countStyle: .file)
  }

  private var label: String {
    switch entry.kind {
    case .user: "You"
    case .assistant: "Agent"
    case .thinking: "Thinking"
    case .toolUse: entry.tool ?? "Tool"
    case .toolResult: "Result"
    case .notice: "Session"
    }
  }

  private var symbol: String {
    switch entry.kind {
    case .user: "person.fill"
    case .assistant: "sparkle"
    case .thinking: "bubble.left.and.text.bubble.right"
    case .toolUse: "terminal"
    case .toolResult: "arrow.turn.down.right"
    case .notice: "arrow.triangle.merge"
    }
  }

  private var tint: Color {
    switch entry.kind {
    case .user: .primary
    case .assistant: .accentColor
    case .thinking: .secondary
    case .toolUse: .purple
    case .toolResult: .secondary
    case .notice: .orange
    }
  }
}
