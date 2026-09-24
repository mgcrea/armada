import Foundation

/// Putting a Claude Code transcript where another account's `claude --resume` can find it.
///
/// **The one place Armada writes into a vendor's transcript folder.** `--resume <id>` looks
/// only in the running account's own `projects/`, so continuing a session on another account
/// cannot be a flag the way forking is: the conversation has to be there first. What is
/// copied is exactly what the session owns under `projects/`: `<encoded cwd>/<id>.jsonl` and,
/// when it exists, the `<id>/` folder beside it holding subagent transcripts and the
/// `tool-results` the transcript points into. Nothing else in either account is touched.
///
/// **The same folder name the source account used**, rather than an encoding worked out here:
/// `TranscriptLocator` records that the encoding is internal and lossy, and the name Claude
/// Code itself chose for this cwd is the one it will look for again.
///
/// **Only whole lines.** The source is usually a session still open and appending, so a copy
/// taken mid-write can end in half a JSON object. The snapshot stops at the last newline.
///
/// **Never overwrites a conversation it does not recognise.** A file already at the target is
/// replaced only when it is an earlier copy of this one, its bytes a prefix of the snapshot,
/// which is what a second handover of the same session finds. Anything else is refused.
///
/// **Bar the bookkeeping Claude Code adds as a session closes.** A conversation carried back
/// to the account it came from finds the original there, and that original usually gained
/// `cost-state`, `last-prompt`, `mode` or `ai-title` lines after the copy left: three of the
/// five round trips on this Mac on 2026-09-24. Those carry no `uuid`, a message always does,
/// so trailing lines without one are set aside before comparing. A message the original gained
/// is a real divergence and is still refused.
nonisolated enum TranscriptHandover {
  enum Failure: Error, Equatable {
    /// The source has no complete line to copy.
    case empty
    /// A different conversation already sits under this id in the target account.
    case conflict(URL)
  }

  /// Copy `transcript` into `projectsDir`, returning where it landed.
  ///
  /// The transcript itself is written atomically. The sidecar folder is best-effort and
  /// file by file, never replacing a file already there: a subagent transcript that fails to
  /// copy costs that subagent's detail, not the conversation.
  @discardableResult
  static func stage(transcript: URL, into projectsDir: URL) throws -> URL {
    let fileManager = FileManager.default
    let sessionFile = transcript.lastPathComponent
    let encoded = transcript.deletingLastPathComponent().lastPathComponent
    let directory = projectsDir.appending(path: encoded, directoryHint: .isDirectory)
    let destination = directory.appending(path: sessionFile, directoryHint: .notDirectory)

    let snapshot = wholeLines(try Data(contentsOf: transcript))
    guard !snapshot.isEmpty else { throw Failure.empty }

    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let existing = try? Data(contentsOf: destination)
    if let existing, !snapshot.starts(with: existing),
      !(conversation(of: existing).map { snapshot.starts(with: $0) } ?? false)
    {
      throw Failure.conflict(destination)
    }
    if existing != snapshot {
      try snapshot.write(to: destination, options: .atomic)
    }

    let sidecarName = String(sessionFile.dropLast(".jsonl".count))
    if !sidecarName.isEmpty {
      copyMissing(
        from: transcript.deletingLastPathComponent().appending(
          path: sidecarName, directoryHint: .isDirectory),
        to: directory.appending(path: sidecarName, directoryHint: .isDirectory))
    }
    return destination
  }

  /// `data` up to and including its last newline.
  static func wholeLines(_ data: Data) -> Data {
    guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
    return data[data.startIndex...last]
  }

  /// `data` without the trailing lines that carry no `uuid`, or nil when no line does: a file
  /// with no message in it is not recognisably any conversation.
  static func conversation(of data: Data) -> Data? {
    var end = wholeLines(data).endIndex
    while end > data.startIndex {
      let body = data[data.startIndex..<(end - 1)]
      let start = body.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
      let line = data[start..<(end - 1)]
      if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        object["uuid"] != nil
      {
        return data[data.startIndex..<end]
      }
      end = start
    }
    return nil
  }

  /// Every file under `source` that `target` lacks, keeping the layout.
  private static func copyMissing(from source: URL, to target: URL) {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return }
    try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    let children =
      (try? fileManager.contentsOfDirectory(
        at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for child in children {
      let destination = target.appending(path: child.lastPathComponent)
      if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        copyMissing(from: child, to: destination)
      } else if !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
        try? fileManager.copyItem(at: child, to: destination)
      }
    }
  }
}
