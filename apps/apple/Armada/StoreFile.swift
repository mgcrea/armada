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
/// Its own file, and Foundation only, so `make unit` compiles it.
nonisolated enum StoreFile {
  enum Loaded<Value> {
    /// No file: an empty store, which is what a fresh install is.
    case absent
    case decoded(Value)
    /// There, and not readable by this build. Where the original now is, or nil when it could
    /// not be moved, in which case it is still at the store's path.
    case setAside(URL?)
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
    return .setAside(moveAside(url, now: now))
  }

  /// `<name>.bak-<seconds>`, beside the original. Nil when the move failed, which includes a
  /// name already taken in the same second: the original is then left where it is.
  @discardableResult
  static func moveAside(_ url: URL, now: Date = .now) -> URL? {
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
