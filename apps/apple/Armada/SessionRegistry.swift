import Darwin
import Foundation

/// One live Claude Code session, as `~/.claude/sessions/<pid>.json` describes it.
///
/// Undocumented Claude Code internals: the format can change in any release, so
/// every field beyond the three this app actually needs is optional, read leniently
/// (see `init(from:)`), and a file that fails to decode is skipped rather than fatal. `docs/claude-code-sessions.md`
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

  /// Whether this file was written by one of Armada's own `claude` probes rather than
  /// by a session.
  ///
  /// **A probe registers itself.** `ClaudeControl` spawns a headless `claude` for each
  /// control request, and on 2.1.269 that process writes `sessions/<pid>.json` like any
  /// other — `"kind": "interactive"`, `"entrypoint": "sdk-cli"`, the cwd it was run in
  /// (measured 2026-09-14). `ContextProbe` runs in the selected session's cwd, so
  /// selecting a row put a second row for the same project beside it for the second or
  /// so the probe lived, and the usage probe did the same from the home directory.
  ///
  /// **The parent, not the entrypoint.** `sdk-cli` is also what every Agent SDK app
  /// writes, and those are sessions someone wants to see. Nothing in Armada but
  /// `ClaudeControl` spawns a process — New Session hands a `.command` file to the
  /// terminal, which becomes the parent — and the registry pid is the spawned process
  /// itself, not a child of it (checked the same day). So a registry whose process is
  /// Armada's own child is a probe, exactly, with no pid list to keep in step with the
  /// spawns and no window between a spawn and its file appearing.
  var isArmadaProbe: Bool {
    ProcessAncestry.parent(of: pid) == getpid()
  }

  /// Whether this is a headless `claude` some tool ran in the temporary directory — a
  /// plugin's summarizer, not a session.
  ///
  /// **The remember plugin's `t-XX` rows.** Its hooks summarize a session by running
  /// `claude -p --no-session-persistence` with the cwd set to Python's
  /// `tempfile.gettempdir()`, so a registry appears for the few seconds it runs and no
  /// transcript ever does. Measured 2026-09-28 on 2.1.283: `"kind": "interactive"`,
  /// `"entrypoint": "sdk-cli"`, `"name": "t-fc"` — the `T` of `/var/folders/…/T`,
  /// lowercased. Nothing in the file says `-p`, and `sdk-cli` is every Agent SDK app
  /// (see `isArmadaProbe`), so the folder is the only signal.
  ///
  /// **The temporary directory itself, not anything under it.** `ProjectPath.isTemporary`
  /// is a prefix test, and a session someone started in `/tmp/scratch` is still theirs.
  /// Nobody opens a conversation in the per-user `T` folder on purpose.
  var isTemporaryDirectorySpawn: Bool {
    Self.temporaryDirectory.contains(ProjectPath.normalize(cwd))
  }

  /// The per-user temporary directory both ways it is spelled.
  ///
  /// The registry records the resolved `/private/var/folders/…/T`, while
  /// `NSTemporaryDirectory` answers `/var/folders/…/T/`. `realpath` is what bridges them:
  /// `URL.resolvingSymlinksInPath` leaves `/var` as it is (measured the same day).
  nonisolated private static let temporaryDirectory: Set<String> = {
    let spelled = NSTemporaryDirectory()
    var spellings: Set<String> = [ProjectPath.normalize(spelled)]
    if let resolved = realpath(spelled, nil) {
      spellings.insert(ProjectPath.normalize(String(cString: resolved)))
      free(resolved)
    }
    return spellings
  }()
}

extension SessionRegistry {
  private enum Field: String, CodingKey {
    case pid, sessionId, cwd, name, startedAt, version, entrypoint, nameSource, status
    case waitingFor, statusUpdatedAt, kind, updatedAt
  }

  /// The three fields this app cannot do without are required; every other one is read
  /// if it decodes and nil if it does not.
  ///
  /// **One odd field costs that field, not the session.** The synthesized decoder failed
  /// the whole file on a type it did not expect, and because every session's file has the
  /// same shape, a Claude Code release that changed one optional field would have emptied
  /// the window at once.
  init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: Field.self)
    func optional<T: Decodable>(_ type: T.Type, _ key: Field) -> T? {
      (try? fields.decodeIfPresent(type, forKey: key)) ?? nil
    }
    self.init(
      pid: try fields.decode(Int32.self, forKey: .pid),
      sessionId: try fields.decode(String.self, forKey: .sessionId),
      cwd: try fields.decode(String.self, forKey: .cwd),
      name: optional(String.self, .name),
      startedAt: optional(Int.self, .startedAt),
      version: optional(String.self, .version),
      entrypoint: optional(String.self, .entrypoint),
      nameSource: optional(String.self, .nameSource),
      status: optional(String.self, .status),
      waitingFor: optional(String.self, .waitingFor),
      statusUpdatedAt: optional(Int.self, .statusUpdatedAt),
      kind: optional(String.self, .kind),
      updatedAt: optional(Int.self, .updatedAt))
  }

  /// Decode every registry file in `sessionsDir`.
  ///
  /// **Filters to `.json`.** Each registry file sits beside a `<pid>.<hash>.key`
  /// file (mode 0600) that this app has no use for and cannot parse; without the
  /// filter every session would produce one phantom failed decode per sweep.
  ///
  /// A file caught mid-write fails to decode and is simply left out — the next
  /// FSEvents tick picks it up.
  static func scan(in sessionsDir: URL) -> [SessionRegistry] {
    scanReporting(in: sessionsDir).registries
  }

  /// `scan`, and the live pids whose file is there but did not decode.
  ///
  /// **Claude Code writes the file in place**, not to a temporary file renamed over it
  /// (2.1.296: `writeFile` on `<pid>.json`), so a read can land mid-write. The pid comes
  /// from the file's name, which is the one thing a torn file still says; see `carried`.
  static func scanReporting(in sessionsDir: URL)
    -> (registries: [SessionRegistry], undecoded: Set<Int32>)
  {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path(percentEncoded: false)))
      ?? []
    let decoder = JSONDecoder()
    var registries: [SessionRegistry] = []
    var undecoded: Set<Int32> = []
    for name in names where name.hasSuffix(".json") {
      let url = sessionsDir.appending(path: name, directoryHint: .notDirectory)
      guard let data = try? Data(contentsOf: url),
        let registry = try? decoder.decode(SessionRegistry.self, from: data)
      else {
        if let pid = Int32(name.dropLast(".json".count)), isAlive(pid: pid) {
          undecoded.insert(pid)
        }
        continue
      }
      registries.append(registry)
    }
    return (
      registries.filter { $0.isAlive && !$0.isArmadaProbe && !$0.isTemporaryDirectorySpawn },
      undecoded
    )
  }

  /// What a scan found, plus each held registry whose file was there and did not decode.
  ///
  /// **A torn read is not a session ending.** Dropping the session would discard what it
  /// keeps once seen (`quotaHit`, `cacheTTL`, `sessionModelID`, the compaction), rerun its
  /// deep scan and clear the selection, only to adopt it again a moment later. The copy
  /// held stands in until the next scan reads the file whole.
  static func carried(
    held: [SessionRegistry], scanned: (registries: [SessionRegistry], undecoded: Set<Int32>)
  ) -> [SessionRegistry] {
    let found = Set(scanned.registries.map(\.pid))
    return scanned.registries
      + held.filter { scanned.undecoded.contains($0.pid) && !found.contains($0.pid) }
  }
}
