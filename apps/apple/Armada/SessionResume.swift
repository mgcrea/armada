import Foundation

/// Finding an ended Claude Code session and checking it can be continued, for whoever asks:
/// `armada_start_session` with `resume`, and Resume under a project's "Recently ended".
///
/// **Never one that is open.** Resuming a live session puts two writers on one transcript,
/// which is why the app's own action on a live session is Fork. Three checks stand in front of
/// that: no watched session has the id, the transcript has not been written in
/// `SessionStarterBridge.recentWrite` seconds, and the account is found by where the transcript is rather than by what the caller
/// says. The folder must be inside a saved project, the same boundary a fresh start keeps.
///
/// Refusals are typed and worded by the caller: an agent is told which tool to call next, and a
/// person is not.
@MainActor
enum SessionResume {
  /// How much of a transcript's head is read for the folder it ran in. Every entry after the
  /// first few carries `cwd`, so this is generous.
  static let cwdSearchBytes = 256 * 1024

  struct Target {
    let account: Account
    let transcript: URL
    let cwd: String
    let project: Project
  }

  enum Refusal {
    case live(Session)
    case noTranscript
    case recentWrite(seconds: Int)
    case noFolder
    case notInProject(cwd: String)
    case folderGone(cwd: String)
  }

  enum Preparation {
    case ready(Target)
    case refused(Refusal)
  }

  /// - Parameter accountID: the account to look in first. A conversation continued on another
  ///   account has a transcript under the same id in both, and a row that names one means it.
  static func prepare(_ id: String, preferring accountID: String? = nil, now: Date) -> Preparation {
    var accounts = Accounts.shared.all
    for account in accounts {
      if let live = account.sessions.sessions.first(where: { $0.id == id }) {
        return .refused(.live(live))
      }
    }
    if let accountID, let index = accounts.firstIndex(where: { $0.id == accountID }) {
      accounts.insert(accounts.remove(at: index), at: 0)
    }

    var found: (Account, URL)?
    for account in accounts {
      if let url = TranscriptLocator.find(sessionId: id, cwd: "", in: account.folder.projectsDir) {
        found = (account, url)
        break
      }
    }
    guard let (account, transcript) = found else { return .refused(.noTranscript) }

    let path = transcript.path(percentEncoded: false)
    if let modified = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]
      as? Date, now.timeIntervalSince(modified) < SessionStarterBridge.recentWrite
    {
      return .refused(.recentWrite(seconds: max(0, Int(now.timeIntervalSince(modified)))))
    }

    guard let cwd = recordedFolder(of: transcript) else { return .refused(.noFolder) }
    guard let project = ProjectStore.shared.project(containing: cwd) else {
      return .refused(.notInProject(cwd: cwd))
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return .refused(.folderGone(cwd: cwd)) }

    return .ready(Target(account: account, transcript: transcript, cwd: cwd, project: project))
  }

  private static func recordedFolder(of transcript: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: cwdSearchBytes) else { return nil }
    for line in head.split(separator: 0x0A) {
      guard line.range(of: Data(#""cwd":"#.utf8)) != nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let cwd = object["cwd"] as? String, !cwd.isEmpty
      else { continue }
      return cwd
    }
    return nil
  }
}
