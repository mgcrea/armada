import Foundation

/// `Session` and `CodexSession` as rows of the session list. See `SessionListItem`.
///
/// **In a file of their own, apart from `SessionOrder`.** The ordering and grouping are
/// pure functions of the protocol, and `make unit` compiles `SessionOrder.swift` beside
/// a fake item to check that every comparator is a total order. These two conformances
/// are what would drag the watchers' whole object graph into that build.
///
/// **`@MainActor` conformances**, because both types are main-actor `@Observable`
/// objects and every requirement reads their live state. Swift 6 refuses a plain
/// conformance here as a data race; an isolated one says what is true, that a session
/// can only be sorted where it can be read, and every caller — the panes and
/// `SessionOrder` — is on the main actor already.
extension Session: @MainActor SessionListItem {
  var projectName: String { registry.projectName }
  var projectPath: String { registry.cwd }
  var startedAt: Date? { registry.startedAtDate }

  /// The registry's own `updatedAt` first, then the transcript, then the start time.
  ///
  /// **`updatedAt` is the authority and the other two are fallbacks.** Claude Code
  /// rewrites the registry on every status change, so it moves for a session waiting
  /// on a permission prompt — which writes no transcript and which the mtime seeding
  /// in `SessionWatcher.refreshTitle` therefore cannot see. `lastWrite` still covers
  /// a folder on an older build that writes no `updatedAt`, and `startedAt` covers a
  /// session that has never been prompted and so has no transcript at all.
  var lastActivity: Date? {
    registry.updatedAtDate ?? lastWrite ?? registry.startedAtDate
  }

  var stateKey: String { state.rawValue }
  var stateLabel: String { state.label }
  var stateRank: Int {
    switch state {
    case .waiting: 0
    case .working: 1
    case .runningTool: 2
    case .idle: 3
    }
  }

  var contextTokens: Int? { context?.total }
}

extension CodexSession: @MainActor SessionListItem {
  var projectName: String { meta.projectName }
  var projectPath: String { meta.cwd }
  var startedAt: Date? { meta.startedAt }
  var lastActivity: Date? { lastEventAt ?? meta.startedAt }

  var stateKey: String { state.rawValue }
  var stateLabel: String { state.label }
  var stateRank: Int {
    switch state {
    case .awaitingInput: 0
    case .working: 1
    case .ended: 2
    }
  }

  /// `context`, not `totalTokens`. Codex is the only vendor that reports a cumulative
  /// figure, and putting it here would make one column mean occupancy in the Claude
  /// pane and lifetime spend in the Codex one. `totalTokens` keeps its own row in
  /// `CodexSessionDetail`, which is where a number with no counterpart belongs.
  var contextTokens: Int? { context?.total }
}
