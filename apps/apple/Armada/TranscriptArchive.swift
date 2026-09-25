import Darwin
import Foundation

/// Copying an account's transcripts into a folder the person chose, and keeping them there.
///
/// **Why it exists.** Claude Code deletes a transcript 30 days after its last write by default,
/// and with it the only record of the conversation. An archive on a NAS or an external disk
/// outlives that. Armada writes to a local path and nothing else: whatever carries the folder
/// off the Mac is something the person mounted, so the app still makes no request of its own.
///
/// **Only a folder that says it is an archive is written into, and only its account folders
/// are ever pruned.** A folder the person picks gets an `Armada Archive` folder inside it,
/// unless it already is one, which `armada-archive.json` at its top says. That manifest also
/// maps each account to its folder name, assigned once, so renaming an account or adding a
/// second one with the same folder name moves nothing.
///
/// **The layout mirrors the source**, so a copy can be read or put back by hand:
///
/// - Claude: `<account>/projects/…`, everything under the account's `projects/`, which is the
///   transcripts, their `<id>/` sidecars (subagents, tool results) and the auto memory.
/// - Codex: `<account>/sessions/YYYY/MM/DD/rollout-….jsonl`. A rollout Codex has moved into
///   `archived_sessions/` goes back under its date, read from its name, so moving it is not a
///   second copy.
///
/// **A transcript is appended to, whole lines only, and never overwritten.** Each pass
/// compares the copy against the source's same bytes at its start and just before its end; when
/// they match, only what the source gained is written, up to its last newline. When they do not,
/// the source was rewritten, and the old copy is kept beside the new one as `<name>~1.jsonl`.
/// A live session is therefore safe to copy mid-turn, and a copy cut short by a crash or an
/// unplugged disk carries on from where it stopped. Other files — tool results, memory — are
/// replaced when their size or date changes.
///
/// **The copy takes the source's modification date.** That is what the next pass's quick
/// check reads, and what retention measures a copy's age by: when the session last wrote,
/// not when it reached the archive.
///
/// **Nothing is removed unless a retention period is set.** A source that is gone leaves its
/// copy, which is the point. With a period set, a copy older than it is deleted, and a source
/// older than it is not copied, so the two rules never fight over the same file.
nonisolated enum TranscriptArchive {
  enum Vendor: String, Codable, Sendable {
    case claude
    case codex
  }

  /// One account to copy, as the controller resolved it.
  struct Source: Hashable, Sendable {
    let account: String
    let vendor: Vendor
    /// Claude: the config folder. Codex: the home.
    let base: URL
    /// What the manifest names it, for someone reading the archive.
    let label: String
  }

  /// What the archive's top says about itself.
  struct Manifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
      var folder: String
      var vendor: Vendor
      var label: String
      var path: String
    }

    var format = 1
    /// By account id: the config folder or home path.
    var accounts: [String: Entry] = [:]
  }

  /// One file to keep a copy of.
  struct Item: Sendable {
    let url: URL
    /// Under the account's folder in the archive.
    let relativePath: String
    let size: Int64
    let mtime: Double
  }

  enum Outcome: Equatable, Sendable {
    case unchanged
    /// A file the archive did not have.
    case copied(Int64)
    /// Lines appended to a copy already there.
    case appended(Int64)
    /// A rewritten transcript: the old copy was set aside and a new one started.
    case versioned(Int64)
    /// Past the retention period, so not copied.
    case tooOld
  }

  struct Report: Equatable, Sendable {
    var filesSeen = 0
    var filesCopied = 0
    var filesAppended = 0
    var filesVersioned = 0
    var filesPruned = 0
    var bytesWritten: Int64 = 0
    var failures = 0
    /// The first failure, worded for the pane.
    var firstFailure: String?

    mutating func record(_ outcome: Outcome) {
      switch outcome {
      case .unchanged, .tooOld: break
      case .copied(let bytes):
        filesCopied += 1
        bytesWritten += bytes
      case .appended(let bytes):
        filesAppended += 1
        bytesWritten += bytes
      case .versioned(let bytes):
        filesVersioned += 1
        bytesWritten += bytes
      }
    }

    mutating func fail(_ path: String, _ error: Error) {
      failures += 1
      if firstFailure == nil { firstFailure = "\(path): \(error.localizedDescription)" }
    }
  }

  static let folderName = "Armada Archive"
  static let manifestName = "armada-archive.json"
  static let chunkBytes = 1 << 20
  static let probeBytes: Int64 = 4_096

  // MARK: - The archive's folder

  /// Where the archive lives inside the folder the person picked.
  static func root(forPicked picked: URL) -> URL {
    let marker = picked.appending(path: manifestName, directoryHint: .notDirectory)
    if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
      || picked.lastPathComponent == folderName
    {
      return picked
    }
    return picked.appending(path: folderName, directoryHint: .isDirectory)
  }

  static func readManifest(at root: URL) -> Manifest? {
    let url = root.appending(path: manifestName, directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Manifest.self, from: data)
  }

  static func writeManifest(_ manifest: Manifest, at root: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: root.appending(path: manifestName, directoryHint: .notDirectory), options: .atomic)
  }

  /// `sources` entered in `manifest`, each keeping the folder it was given the first time.
  ///
  /// A new account takes its config folder's name without the dot — `claude-skitrust`,
  /// `codex` — and a number after it when another account already has that name.
  static func assign(_ sources: [Source], in manifest: Manifest) -> Manifest {
    var manifest = manifest
    for source in sources {
      if var entry = manifest.accounts[source.account] {
        entry.label = source.label
        manifest.accounts[source.account] = entry
        continue
      }
      var base = source.base.lastPathComponent
      while base.hasPrefix(".") { base.removeFirst() }
      base = String(base.map { $0 == "/" || $0 == ":" ? "-" : $0 })
      if base.isEmpty { base = source.vendor.rawValue }
      let taken = Set(manifest.accounts.values.map { $0.folder.lowercased() })
      var folder = base
      var number = 2
      while taken.contains(folder.lowercased()) {
        folder = "\(base)-\(number)"
        number += 1
      }
      manifest.accounts[source.account] = Manifest.Entry(
        folder: folder, vendor: source.vendor, label: source.label,
        path: source.base.path(percentEncoded: false))
    }
    return manifest
  }

  // MARK: - Finding files

  static func enumerate(_ source: Source) -> [Item] {
    switch source.vendor {
    case .claude:
      let projects = source.base.appending(path: "projects", directoryHint: .isDirectory)
      return walk(projects).map { item(url: $0.url, relative: "projects/\($0.relative)") }
        .compactMap { $0 }
    case .codex:
      var byName: [String: Item] = [:]
      let sessions = source.base.appending(path: "sessions", directoryHint: .isDirectory)
      for file in walk(sessions) where isRollout(file.url.lastPathComponent) {
        guard let item = item(url: file.url, relative: "sessions/\(file.relative)") else {
          continue
        }
        byName[file.url.lastPathComponent] = item
      }
      let archived = source.base.appending(path: "archived_sessions", directoryHint: .isDirectory)
      for file in walk(archived) where isRollout(file.url.lastPathComponent) {
        let name = file.url.lastPathComponent
        guard let item = item(url: file.url, relative: "sessions/\(codexDay(name))/\(name)")
        else { continue }
        // Mid-move, the same rollout can be in both. The longer one is the newer.
        if let other = byName[name], other.size >= item.size { continue }
        byName[name] = item
      }
      return Array(byName.values)
    }
  }

  static func isRollout(_ name: String) -> Bool {
    name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
  }

  /// `rollout-2026-09-11T07-01-34-<uuid>.jsonl` → `2026/09/11`, the folder Codex files it
  /// under, which is the local date and matches the name. `archived` when the name has none.
  static func codexDay(_ name: String) -> String {
    let body = name.dropFirst("rollout-".count)
    let parts = body.prefix(10).split(separator: "-")
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
    else { return "archived" }
    return parts.joined(separator: "/")
  }

  /// Every regular file under `root`, symlinks and dot-files left out.
  private static func walk(_ root: URL) -> [(url: URL, relative: String)] {
    let path = root.path(percentEncoded: false)
    guard let walker = FileManager.default.enumerator(atPath: path) else { return [] }
    var files: [(URL, String)] = []
    for case let relative as String in walker {
      if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
      files.append((root.appending(path: relative, directoryHint: .notDirectory), relative))
    }
    return files
  }

  private static func item(url: URL, relative: String) -> Item? {
    guard let info = stat(url), info.st_mode & S_IFMT == S_IFREG else { return nil }
    return Item(url: url, relativePath: relative, size: Int64(info.st_size), mtime: mtime(info))
  }

  private static func stat(_ url: URL) -> Darwin.stat? {
    var info = Darwin.stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
    return info
  }

  private static func mtime(_ info: Darwin.stat) -> Double {
    Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
  }

  // MARK: - Copying one file

  /// Bring the copy of `item` under `folder` up to date.
  static func sync(_ item: Item, into folder: URL, cutoff: Double?) throws -> Outcome {
    if let cutoff, item.mtime < cutoff { return .tooOld }
    let target = folder.appending(path: item.relativePath, directoryHint: .notDirectory)
    let existing = stat(target)
    if let existing, Int64(existing.st_size) == item.size,
      abs(mtime(existing) - item.mtime) < 1
    {
      return .unchanged
    }
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

    guard item.relativePath.hasSuffix(".jsonl") else {
      try replace(target, with: item.url, length: nil)
      setDate(target, item.mtime)
      return .copied(item.size)
    }

    guard let existing else {
      let written = try replace(target, with: item.url, length: try wholeLength(item.url))
      guard written > 0 else { return .unchanged }
      setDate(target, item.mtime)
      return .copied(written)
    }

    let copied = Int64(existing.st_size)
    if copied <= item.size, try isPrefix(target, of: item.url, length: copied) {
      let written = try append(from: item.url, offset: copied, to: target)
      if written > 0 { setDate(target, item.mtime) }
      return written > 0 ? .appended(written) : .unchanged
    }

    try FileManager.default.moveItem(at: target, to: nextVersion(of: target))
    let written = try replace(target, with: item.url, length: try wholeLength(item.url))
    setDate(target, item.mtime)
    return .versioned(written)
  }

  /// The source's length up to and including its last newline.
  static func wholeLength(_ url: URL) throws -> Int64 {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var end = try handle.seekToEnd()
    while end > 0 {
      let start = end > UInt64(chunkBytes) ? end - UInt64(chunkBytes) : 0
      try handle.seek(toOffset: start)
      let data = try handle.read(upToCount: Int(end - start)) ?? Data()
      if let last = data.lastIndex(of: UInt8(ascii: "\n")) {
        return Int64(start) + Int64(last - data.startIndex) + 1
      }
      end = start
    }
    return 0
  }

  /// Whether the copy's `length` bytes are the source's first `length`, judged by the first
  /// and last few kilobytes of that range, which is what tells an append from a rewrite.
  static func isPrefix(_ copy: URL, of source: URL, length: Int64) throws -> Bool {
    guard length > 0 else { return true }
    let a = try FileHandle(forReadingFrom: copy)
    defer { try? a.close() }
    let b = try FileHandle(forReadingFrom: source)
    defer { try? b.close() }
    let headLength = Int(min(probeBytes, length))
    let tailStart = UInt64(max(0, length - probeBytes))
    for (offset, count) in [(UInt64(0), headLength), (tailStart, Int(length - Int64(tailStart)))] {
      try a.seek(toOffset: offset)
      try b.seek(toOffset: offset)
      guard try a.read(upToCount: count) == b.read(upToCount: count) else { return false }
    }
    return true
  }

  /// Write `length` bytes of `source` (all of it when nil) to a temporary file beside `target`,
  /// then move it into place, so an interrupted copy never leaves a half file under the name.
  @discardableResult
  private static func replace(_ target: URL, with source: URL, length: Int64?) throws -> Int64 {
    if length == 0 { return 0 }
    let temporary = target.deletingLastPathComponent().appending(
      path: ".\(target.lastPathComponent).armada-\(UUID().uuidString.prefix(8))",
      directoryHint: .notDirectory)
    guard
      FileManager.default.createFile(atPath: temporary.path(percentEncoded: false), contents: nil)
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
    do {
      let written = try copyBytes(from: source, offset: 0, length: length, to: temporary)
      // rename(2) rather than `replaceItemAt`: it replaces in one step on a local disk and on
      // SMB alike, and needs no original to exist.
      guard rename(temporary.path(percentEncoded: false), target.path(percentEncoded: false)) == 0
      else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return written
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  /// Append the source's whole lines past `offset` to `target`.
  private static func append(from source: URL, offset: Int64, to target: URL) throws -> Int64 {
    let end = try wholeLength(source)
    guard end > offset else { return 0 }
    return try copyBytes(from: source, offset: offset, length: end - offset, to: target)
  }

  /// Stream `length` bytes (to the end when nil) from `offset` onto the end of `target`.
  private static func copyBytes(
    from source: URL, offset: Int64, length: Int64?, to target: URL
  ) throws -> Int64 {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: target)
    defer { try? output.close() }
    try output.seekToEnd()
    try input.seek(toOffset: UInt64(offset))
    var remaining = length ?? .max
    var written: Int64 = 0
    while remaining > 0 {
      try Task.checkCancellation()
      let count = Int(min(Int64(chunkBytes), remaining))
      guard let data = try input.read(upToCount: count), !data.isEmpty else { break }
      try output.write(contentsOf: data)
      written += Int64(data.count)
      remaining -= Int64(data.count)
    }
    try output.synchronize()
    return written
  }

  /// `name~1.jsonl`, or the first number not yet taken.
  static func nextVersion(of target: URL) -> URL {
    let directory = target.deletingLastPathComponent()
    let stem = target.deletingPathExtension().lastPathComponent
    let ext = target.pathExtension
    var number = 1
    while true {
      let candidate = directory.appending(
        path: "\(stem)~\(number).\(ext)", directoryHint: .notDirectory)
      if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
      number += 1
    }
  }

  private static func setDate(_ url: URL, _ mtime: Double) {
    try? FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: mtime)],
      ofItemAtPath: url.path(percentEncoded: false))
  }

  // MARK: - Retention

  /// Delete every file under the manifest's account folders last written before `cutoff`,
  /// then the folders that leaves empty. Returns how many files went.
  ///
  /// Only the folders the manifest names, so a file the person keeps elsewhere in the archive's
  /// folder is never looked at, and the manifest itself is never a candidate.
  static func prune(root: URL, manifest: Manifest, cutoff: Double) -> Int {
    let fileManager = FileManager.default
    var removed = 0
    for entry in manifest.accounts.values {
      guard !entry.folder.isEmpty, !entry.folder.contains("/"), !entry.folder.hasPrefix(".")
      else { continue }
      let folder = root.appending(path: entry.folder, directoryHint: .isDirectory)
      guard let walker = fileManager.enumerator(atPath: folder.path(percentEncoded: false))
      else { continue }
      var directories: [URL] = []
      for case let relative as String in walker {
        let url = folder.appending(path: relative)
        guard let info = stat(url) else { continue }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: directories.append(url)
        case S_IFREG where mtime(info) < cutoff:
          if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        default: break
        }
      }
      // Deepest first, so a parent is empty by the time it is reached.
      for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
        if (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?
          .isEmpty == true
        {
          try? fileManager.removeItem(at: directory)
        }
      }
    }
    return removed
  }

  /// The date retention measures from, or nil for keep forever.
  static func cutoff(days: Int, now: Date) -> Double? {
    days > 0 ? now.timeIntervalSince1970 - Double(days) * 86_400 : nil
  }
}
