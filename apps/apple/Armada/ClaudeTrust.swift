import Darwin
import Foundation

/// A saved project, marked trusted in Claude Code's own configuration, so a session started
/// there opens on its prompt rather than on the "Quick safety check" dialog.
///
/// **The one write Armada makes to a vendor's configuration, and it is this narrow on
/// purpose:** one boolean, `projects[<folder>].hasTrustDialogAccepted`, in the account's
/// `.claude.json`, for a folder the person saved as a project. Answering "Yes, I trust this
/// folder" writes the same field, and Claude Code's own messages name it as the way to trust a
/// folder by hand. Saving a project is already that decision: no MCP tool adds one, and
/// `armada_start_session` reaches saved projects only.
///
/// **Why a trusted parent is not enough.** Measured against Claude Code 2.1.270 on 2026-09-15:
/// trust is looked up on the folder and then its parents, but the walk stops at the git root,
/// so a repository under a trusted `~/Projects` still asks. And each account has its own
/// `.claude.json`, so a folder trusted on one account asks again on the next.
///
/// **An edit of the bytes, never a rewrite.** The same file holds the account's sign-in, and
/// Claude Code carries guards against wiping it (its GH #3117). Decoding it with
/// `JSONSerialization` and encoding it again is not lossless: on 2026-09-15 this Mac's
/// `~/.claude.json` came back unequal to itself, on thirteen floating-point costs and timings
/// Claude Code keeps per project. So `trusting` finds the byte range of the one
/// value it changes, or the one place it inserts, and leaves every other byte alone; then parses
/// the result and compares it with the original plus the flag. Anything but equal writes nothing.
///
/// **Under Claude Code's own lock.** Claude Code writes the file holding `<file>.lock`, a
/// directory made with `mkdir`, and re-reads the file once it has it. Taking the same lock means
/// neither side writes over the other. A lock held for more than a moment is left alone and the
/// write skipped, never broken: the dialog then appears, exactly as it did before this existed.
nonisolated enum ClaudeTrust {
  enum Outcome: Equatable, Sendable {
    case alreadyTrusted
    case trusted
    case skipped(String)
  }

  enum Edit: Equatable, Sendable {
    case alreadyTrusted
    case edited(Data)
    case refused(String)
  }

  static let field = "hasTrustDialogAccepted"

  /// The entry Claude Code writes for a folder it has not seen, with the flag set.
  ///
  /// **All of it, not only the flag.** Claude Code 2.1.270 reads a project's entry as it stands
  /// rather than merging it with these defaults (`U7`), so an entry holding the flag alone would
  /// hand it a missing `allowedTools`. None of the 116 entries on this Mac lacks them.
  static let newEntry =
    #"{"allowedTools": [], "mcpContextUris": [], "mcpServers": {}, "enabledMcpjsonServers": [], "#
    + #""disabledMcpjsonServers": [], "hasTrustDialogAccepted": true, "#
    + #""hasClaudeMdExternalIncludesApproved": false, "hasClaudeMdExternalIncludesWarningShown": false}"#

  /// The folder as Claude Code keys it: symlinks resolved, no trailing slash.
  ///
  /// A session's working directory is the physical path, which is why `/tmp` is recorded as
  /// `/private/tmp`. A folder that cannot be resolved keeps its spelling.
  static func key(for folder: String) -> String {
    var path = folder
    if let pointer = realpath(folder, nil) {
      path = String(cString: pointer)
      free(pointer)
    }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  // MARK: - The file

  /// Mark `folder` trusted in `configFile`, the account's `.claude.json`.
  ///
  /// Synchronous, because the session it is for starts a moment later and must find the flag
  /// there. The cost is one small file read, plus at most `lockBudget` when a Claude Code on the
  /// same account is writing at that instant.
  ///
  /// **A file that is not there is not created.** It is where the sign-in lives, and an account
  /// without one is Claude Code's to set up.
  static func ensure(
    folder: String, configFile: URL, lockBudget: Duration = .milliseconds(400)
  ) -> Outcome {
    let file = configFile.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: file) else {
      return .skipped("\(file) does not exist")
    }

    let lock = file + ".lock"
    let deadline = ContinuousClock.now + lockBudget
    while mkdir(lock, 0o755) != 0 {
      guard errno == EEXIST else {
        return .skipped("could not take \(lock): \(String(cString: strerror(errno)))")
      }
      guard ContinuousClock.now < deadline else {
        return .skipped("\(lock) is held, most likely by a Claude Code writing the file")
      }
      usleep(25_000)
    }
    defer { rmdir(lock) }

    // Written beside the real file, so a `.claude.json` symlinked from a dotfiles repository
    // stays a symlink.
    let target =
      realpath(file, nil).map { pointer in
        defer { free(pointer) }
        return String(cString: pointer)
      } ?? file

    guard let data = FileManager.default.contents(atPath: target) else {
      return .skipped("could not read \(target)")
    }
    switch trusting(data, folder: key(for: folder)) {
    case .alreadyTrusted:
      return .alreadyTrusted
    case .refused(let reason):
      return .skipped(reason)
    case .edited(let edited):
      if let failure = replace(target, with: edited) { return .skipped(failure) }
      return .trusted
    }
  }

  /// Write `data` over `path` atomically, keeping the file's permission bits.
  ///
  /// A temporary file in the same directory, then `rename(2)`: a reader sees the old file or
  /// the new one, never half of either. Returns nil on success.
  private static func replace(_ path: String, with data: Data) -> String? {
    var status = stat()
    let mode = stat(path, &status) == 0 ? status.st_mode & 0o7777 : 0o600
    let temporary = path + ".armada-\(UUID().uuidString).tmp"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
      return "could not create \(temporary): \(String(cString: strerror(errno)))"
    }
    let written = data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
    let flushed = written && fchmod(descriptor, mode) == 0 && fsync(descriptor) == 0
    close(descriptor)
    guard flushed, rename(temporary, path) == 0 else {
      let reason = String(cString: strerror(errno))
      unlink(temporary)
      return "could not replace \(path): \(reason)"
    }
    return nil
  }

  // MARK: - The edit

  /// `config` with `projects[folder].hasTrustDialogAccepted` set to `true`, and nothing else
  /// changed. `folder` is used as given; `key(for:)` is the caller's.
  ///
  /// Three shapes, from the most common: the entry has the field (its value is replaced), the
  /// entry is missing it (it is inserted first in the entry), or there is no entry (`newEntry` is
  /// inserted first in `projects`, which is itself inserted when absent). A duplicated key is
  /// taken as its last occurrence, as JavaScript reads it.
  static func trusting(_ config: Data, folder: String) -> Edit {
    let bytes = [UInt8](config)
    let scanner = JSONScanner(bytes: bytes)
    guard let root = scanner.object(at: scanner.skipSpace(from: 0)) else {
      return .refused("the configuration is not a JSON object")
    }
    guard scanner.skipSpace(from: root.end) == bytes.count else {
      return .refused("the configuration has something after its object")
    }

    let insertion: (at: Int, text: String)
    var replacement: Range<Int>?

    if let projects = root.last(named: "projects", in: bytes) {
      guard let entries = scanner.object(at: projects.value.lowerBound) else {
        return .refused("projects is not an object")
      }
      if let entry = entries.last(named: folder, in: bytes) {
        guard let members = scanner.object(at: entry.value.lowerBound) else {
          return .refused("the project's entry is not an object")
        }
        if let flag = members.last(named: field, in: bytes) {
          if bytes[flag.value] == Array("true".utf8)[...] { return .alreadyTrusted }
          replacement = flag.value
          insertion = (flag.value.lowerBound, "true")
        } else {
          insertion = member(members, "\(quoted(field)): true")
        }
      } else {
        insertion = member(entries, "\(quoted(folder)): \(newEntry)")
      }
    } else {
      insertion = member(root, "\"projects\": {\(quoted(folder)): \(newEntry)}")
    }

    var edited = bytes
    edited.replaceSubrange(
      replacement ?? insertion.at..<insertion.at, with: Array(insertion.text.utf8))
    let data = Data(edited)
    guard verify(original: config, edited: data, folder: folder) else {
      return .refused(
        "the edited configuration did not compare equal to the original plus the flag")
    }
    return .edited(data)
  }

  /// Where a new first member of `object` goes, and its text with the comma it needs.
  private static func member(_ object: JSONScanner.Object, _ text: String) -> (Int, String) {
    (object.start + 1, object.members.isEmpty ? text : text + ", ")
  }

  private static func quoted(_ string: String) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }

  /// Both files parsed, the original given the flag the way Claude Code would, and compared.
  ///
  /// The number that `JSONSerialization` cannot write back exactly still parses the same way from
  /// the same text, so an untouched byte range compares equal here whatever it holds.
  private static func verify(original: Data, edited: Data, folder: String) -> Bool {
    guard
      let expected = try? JSONSerialization.jsonObject(with: original, options: .mutableContainers)
        as? NSMutableDictionary,
      let actual = try? JSONSerialization.jsonObject(with: edited) as? NSDictionary,
      let defaults = try? JSONSerialization.jsonObject(
        with: Data(newEntry.utf8), options: .mutableContainers) as? NSMutableDictionary
    else { return false }
    let projects = expected["projects"] as? NSMutableDictionary ?? NSMutableDictionary()
    let entry = projects[folder] as? NSMutableDictionary ?? defaults
    entry[field] = true
    projects[folder] = entry
    expected["projects"] = projects
    return expected.isEqual(actual)
  }
}

/// Just enough of a JSON reader to find byte ranges: objects, their keys, and where each value
/// starts and ends. Validity is `JSONSerialization`'s to judge, afterwards, in `verify`.
nonisolated struct JSONScanner {
  struct Member {
    let key: Range<Int>
    let value: Range<Int>
  }

  struct Object {
    /// The `{`.
    let start: Int
    /// Just past the `}`.
    let end: Int
    let members: [Member]

    /// The last member whose key decodes to exactly `name`, scalar for scalar.
    ///
    /// Scalars rather than `==`, which treats a composed and a decomposed é as one string where
    /// Claude Code's JavaScript sees two keys.
    func last(named name: String, in bytes: [UInt8]) -> Member? {
      members.last { member in
        guard
          let key = try? JSONSerialization.jsonObject(
            with: Data(bytes[member.key]), options: .fragmentsAllowed) as? String
        else { return false }
        return key.unicodeScalars.elementsEqual(name.unicodeScalars)
      }
    }
  }

  let bytes: [UInt8]

  func skipSpace(from index: Int) -> Int {
    var index = index
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    return index
  }

  /// The object starting at `index`, or nil when there is not one there.
  func object(at index: Int) -> Object? {
    guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
    var members: [Member] = []
    var cursor = skipSpace(from: index + 1)
    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "}") {
      return Object(start: index, end: cursor + 1, members: [])
    }
    while cursor < bytes.count {
      guard let keyEnd = stringEnd(at: cursor) else { return nil }
      let key = cursor..<keyEnd
      cursor = skipSpace(from: keyEnd)
      guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { return nil }
      let valueStart = skipSpace(from: cursor + 1)
      guard let valueEnd = valueEnd(at: valueStart) else { return nil }
      members.append(Member(key: key, value: valueStart..<valueEnd))
      cursor = skipSpace(from: valueEnd)
      guard cursor < bytes.count else { return nil }
      if bytes[cursor] == UInt8(ascii: "}") {
        return Object(start: index, end: cursor + 1, members: members)
      }
      guard bytes[cursor] == UInt8(ascii: ",") else { return nil }
      cursor = skipSpace(from: cursor + 1)
    }
    return nil
  }

  /// Just past the closing quote of the string starting at `index`.
  func stringEnd(at index: Int) -> Int? {
    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
    var cursor = index + 1
    while cursor < bytes.count {
      switch bytes[cursor] {
      case UInt8(ascii: "\\"): cursor += 2
      case UInt8(ascii: "\""): return cursor + 1
      default: cursor += 1
      }
    }
    return nil
  }

  /// Just past the value starting at `index`: a string, an object or array with everything
  /// inside, or a number or literal up to the next delimiter.
  func valueEnd(at index: Int) -> Int? {
    guard index < bytes.count else { return nil }
    switch bytes[index] {
    case UInt8(ascii: "\""):
      return stringEnd(at: index)
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      var depth = 0
      var cursor = index
      while cursor < bytes.count {
        switch bytes[cursor] {
        case UInt8(ascii: "\""):
          guard let end = stringEnd(at: cursor) else { return nil }
          cursor = end
          continue
        case UInt8(ascii: "{"), UInt8(ascii: "["):
          depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          depth -= 1
          if depth == 0 { return cursor + 1 }
        default:
          break
        }
        cursor += 1
      }
      return nil
    default:
      var cursor = index
      while cursor < bytes.count,
        ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
          .contains(bytes[cursor])
      {
        cursor += 1
      }
      return cursor > index ? cursor : nil
    }
  }
}
