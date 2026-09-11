import Darwin
import Foundation

/// One live Claude Code session, as `~/.claude/sessions/<pid>.json` describes it.
///
/// Undocumented Claude Code internals: the format can change in any release, so
/// every field beyond the four this app actually needs is optional and a file
/// that fails to decode is skipped rather than fatal. `docs/claude-code-sessions.md`
/// has the full shape.
struct SessionRegistry: Decodable, Identifiable, Sendable, Hashable {
  let pid: Int32
  let sessionId: String
  let cwd: String

  /// Derived from the project directory plus a short suffix (`bastion-ae`). **Not
  /// the human title** — that lives in the transcript as an `ai-title` entry.
  let name: String?

  /// Epoch **milliseconds**, not a date string. Confirmed against live files:
  /// `"startedAt":1789048625438`.
  let startedAt: Int?

  let version: String?
  let entrypoint: String?

  /// `"derived"` for a name Claude Code built from the directory.
  let nameSource: String?

  var id: String { sessionId }

  var startedAtDate: Date? {
    startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
  }

  /// The last path component of `cwd` — the project, as a person would name it.
  var projectName: String {
    URL(filePath: cwd).lastPathComponent
  }

  /// Whether the process is still there.
  ///
  /// The registry prunes itself and the file is deleted when shutdown *starts*,
  /// about 0.5–2s before the process actually exits — but a crashed session can
  /// leave its file behind, so this is checked defensively on every sweep.
  /// `EPERM` means the pid exists and belongs to somebody else.
  static func isAlive(pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  var isAlive: Bool { Self.isAlive(pid: pid) }
}

extension SessionRegistry {
  /// Decode every registry file in `sessionsDir`.
  ///
  /// **Filters to `.json`.** Each registry file sits beside a `<pid>.<hash>.key`
  /// file (mode 0600) that this app has no use for and cannot parse; without the
  /// filter every session would produce one phantom failed decode per sweep.
  ///
  /// A file caught mid-write fails to decode and is simply left out — the next
  /// FSEvents tick picks it up.
  static func scan(in sessionsDir: URL) -> [SessionRegistry] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path(percentEncoded: false)))
      ?? []
    let decoder = JSONDecoder()
    return
      names
      .filter { $0.hasSuffix(".json") }
      .compactMap { name -> SessionRegistry? in
        let url = sessionsDir.appending(path: name, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url),
          let registry = try? decoder.decode(SessionRegistry.self, from: data)
        else { return nil }
        return registry
      }
      .filter(\.isAlive)
  }
}
