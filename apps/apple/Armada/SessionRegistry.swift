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

  /// What Claude Code says this session is doing: `"busy"`, `"waiting"` or `"idle"`.
  ///
  /// **Reported, not inferred**, and the reason `SessionState` no longer has to guess.
  /// Read off the live registries on 2.1.269 (2026-09-12) and confirmed against the
  /// CLI's own reading of the same field, which maps busy → active, waiting → blocked,
  /// anything else → idle. Optional because a folder on an older build writes none.
  let status: String?

  /// Why the session is waiting, when it is — `"permission prompt"`, `"dialog open"`,
  /// `"input needed"`, `"sandbox request"`.
  ///
  /// **Free-form display text, never a value to branch on.** The CLI builds it from a
  /// per-dialog table, so the set is open and grows with every new prompt kind. Show
  /// it; do not compare it. `status` is the closed vocabulary.
  let waitingFor: String?

  /// When `status` last changed. Epoch milliseconds.
  let statusUpdatedAt: Int?

  /// `"interactive"` for a session someone is sitting in front of.
  let kind: String?

  /// Epoch **milliseconds**, like `startedAt`. Claude Code rewrites the registry file
  /// whenever the session's status changes, so this is the honest "last activity" —
  /// and it is strictly better than the transcript's mtime, because a session parked
  /// on a permission prompt writes no transcript but does move this.
  ///
  /// Optional like everything else here: it appeared partway through the 2.1.x line
  /// (present in all five live registries on 2.1.269, 2026-09-12), and a folder still
  /// running an older build simply has none. See `Session.lastActivity` for the
  /// fallback chain.
  let updatedAt: Int?

  var updatedAtDate: Date? {
    updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
  }

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
