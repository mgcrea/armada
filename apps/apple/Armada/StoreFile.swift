import Foundation

/// Reading one of Armada's own files under `AppInfo.supportDirectory`, telling "not there"
/// from "there and unreadable".
///
/// **A file this build cannot read is moved aside, never overwritten.** `ProjectStore` has
/// always done this; `UsageHistory` folded the two together, `try?` on the read and `try?` on
/// the decode, and either failure became an empty history that the next sample wrote over the
/// original. A downgrade meeting a field this build does not know cost a month of samples.
///
/// So the original goes to `<name>.bak-<seconds>` beside it, where a person can look at it or
/// put it back, and the store starts empty with nothing left at its path to write over. When
/// even the move fails, the original is still in place and the caller is told so, and must not
/// write until a person has looked.
///
/// **That answer is a case of its own, and `write` takes it.** It used to be a nil inside
/// `.setAside`, and ProjectStore dropped it: a folder the move could not write into, or a name
/// already taken, and the store started empty and saved over the original the first time a
/// project was added. Now a store keeps the `Unreadable` the load handed it and passes it to
/// every write, which refuses for the rest of the session.
///
/// Its own file, and Foundation only, so `make unit` compiles it.
nonisolated enum StoreFile {
  /// There, not readable by this build, and still at the store's path because the move aside
  /// failed. Thrown by `write` in place of saving over it.
  struct Unreadable: LocalizedError {
    let file: URL

    var errorDescription: String? {
      "\(file.lastPathComponent) could not be read or moved aside, so Armada will not write over "
        + "it. Fix or remove the file, then relaunch Armada."
    }
  }

  enum Loaded<Value> {
    /// No file: an empty store, which is what a fresh install is.
    case absent
    case decoded(Value)
    /// There, not readable by this build, and moved here: nothing is left at the store's path.
    case setAside(URL)
    /// There, not readable, and not moved either. The store keeps this for `write`.
    case unreadable(Unreadable)
  }

  static func load<Value>(
    _ url: URL, now: Date = .now, decode: (Data) throws -> Value
  ) -> Loaded<Value> {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return .absent
    }
    if let data = try? Data(contentsOf: url), let value = try? decode(data) {
      return .decoded(value)
    }
    guard let aside = moveAside(url, now: now) else { return .unreadable(Unreadable(file: url)) }
    return .setAside(aside)
  }

  /// Save a store's file, or throw `unreadable` when the load left one at this path.
  ///
  /// A required argument rather than a flag each store checks for itself, so a store cannot
  /// write without having said what its load found.
  static func write(_ data: Data, to url: URL, blockedBy unreadable: Unreadable?) throws {
    if let unreadable { throw unreadable }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  /// `<name>.bak-<seconds>`, beside the original. Nil when the move failed, which includes a
  /// name already taken in the same second: the original is then left where it is.
  private static func moveAside(_ url: URL, now: Date) -> URL? {
    let stamp = Int(now.timeIntervalSince1970)
    let aside = url.deletingLastPathComponent().appending(
      path: "\(url.lastPathComponent).bak-\(stamp)")
    do {
      try FileManager.default.moveItem(at: url, to: aside)
      return aside
    } catch {
      return nil
    }
  }
}
