import Foundation

/// One Antigravity CLI conversation as Armada shows it.
///
/// Its row in `conversation_summaries.db` may be missing: a conversation opened in the TUI and
/// not prompted yet holds its lock before `agy` writes one. The transcript's tokens are added
/// up a stretch at a time, from `transcriptOffset`, as `AntigravityWatcher` reads them.
@Observable
final class AntigravitySession: Identifiable {
  /// `conversation_id`, a lowercase UUID, which is also the brain and lock name.
  let id: String
  let transcriptURL: URL

  var summary: AntigravityFiles.Summary?
  /// The row's folder, or `last_conversations.json`'s when the row names none; `""` when
  /// neither does.
  var cwd: String
  var state: AntigravitySessionState = .ended
  /// The `agy` process holding the presence lock, while one does.
  var holder: AntigravityPresence.Holder?
  /// The newest transcript step's time.
  var lastEventAt: Date?
  var model: String?
  var inputTokens = 0
  var outputTokens = 0
  var cacheReadTokens = 0
  var lastPrompt: String?

  /// Where the next transcript read starts: just past the last whole line read.
  var transcriptOffset = 0
  /// The transcript's size at the last read, so an unchanged one is not opened.
  var transcriptSize = 0

  init(id: String, transcriptURL: URL, summary: AntigravityFiles.Summary?, cwd: String) {
    self.id = id
    self.transcriptURL = transcriptURL
    self.summary = summary
    self.cwd = cwd
  }

  static let previewLength = 60

  /// The TUI's title, else the first prompt's first line cut at `previewLength`, else the folder.
  var displayName: String {
    if let title = summary?.title { return title }
    if let line = summary?.preview?.split(whereSeparator: \.isNewline).first {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return String(trimmed.prefix(Self.previewLength)) }
    }
    return projectName
  }

  var projectName: String {
    cwd.isEmpty ? "Unknown folder" : URL(filePath: cwd).lastPathComponent
  }

  var pid: Int32? { holder?.pid }

  /// The newest transcript step, else the row's last write: what "last activity" means here.
  var lastActivity: Date? { lastEventAt ?? summary?.lastModified }

  var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens }
}
