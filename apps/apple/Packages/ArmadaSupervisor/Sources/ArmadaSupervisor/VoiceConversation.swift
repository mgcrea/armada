/// The conversation voice's next `claude` may resume.
///
/// **Resumed only on the same account and the same brief.** A resumed conversation keeps the
/// system prompt it began with (see `VoiceBrief`), so once the reply language, the instructions
/// or Allow writes have changed, resuming would go on answering by the old rules. A new
/// conversation is the only way the new brief is read.
public struct VoiceConversation: Equatable, Sendable {
  public let folder: String
  public let sessionID: String
  public let brief: String

  public init(folder: String, sessionID: String, brief: String) {
    self.folder = folder
    self.sessionID = sessionID
    self.brief = brief
  }

  /// The session a `claude` on `folder` with `brief` should resume, or nil for a new conversation.
  public func sessionToResume(folder: String, brief: String) -> String? {
    folder == self.folder && brief == self.brief ? sessionID : nil
  }
}
