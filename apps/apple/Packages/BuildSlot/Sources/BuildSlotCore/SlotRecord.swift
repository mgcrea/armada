import Foundation

/// What a holder writes into `slots/N.lock`, and a waiter into `waiting/<pid>.lock`. A reader
/// trusts it only while `F_GETLK` names `pid` as the file's holder: a dead holder's record stays
/// on disk.
public struct SlotRecord: Codable, Equatable, Sendable {
  public var version: Int
  public var pid: Int32
  public var processStart: Date?
  /// Set by a holder.
  public var startedAt: Date?
  /// Set by a waiter, in place of `startedAt`.
  public var waitingSince: Date?
  public var cwd: String
  public var label: String
  public var tool: String
  public var argv: [String]

  public init(
    version: Int = 1, pid: Int32, processStart: Date?, startedAt: Date?, waitingSince: Date?,
    cwd: String, label: String, tool: String, argv: [String]
  ) {
    self.version = version
    self.pid = pid
    self.processStart = processStart
    self.startedAt = startedAt
    self.waitingSince = waitingSince
    self.cwd = cwd
    self.label = label
    self.tool = tool
    self.argv = argv
  }

  static let maxArguments = 20
  static let maxArgvBytes = 2048
  static let ellipsis = "…"

  /// `argv` cut to at most 20 arguments and 2048 bytes, so a record stays one small read. The
  /// last argument kept is cut short when it alone would pass the byte cap, and `…` follows as
  /// an argument of its own whenever anything was left out.
  public static func truncated(_ argv: [String]) -> [String] {
    var kept: [String] = []
    var bytes = 0
    for argument in argv {
      guard kept.count < maxArguments else { break }
      let size = argument.utf8.count
      if bytes + size <= maxArgvBytes {
        kept.append(argument)
        bytes += size
        continue
      }
      var cut = ""
      for character in argument {
        let next = character.utf8.count
        if bytes + cut.utf8.count + next > maxArgvBytes { break }
        cut.append(character)
      }
      if !cut.isEmpty { kept.append(cut) }
      return kept + [ellipsis]
    }
    return kept.count < argv.count ? kept + [ellipsis] : kept
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// nil for anything that is not a record: an empty file a holder has not written yet, or a
  /// torn read.
  public static func decoded(from data: Data) -> SlotRecord? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SlotRecord.self, from: data)
  }
}
