import Foundation

/// When a shim holds a build back for memory: never, while the system says critical, or while it
/// says warning or critical.
public enum MemoryRule: String, Codable, Sendable, CaseIterable {
  case off, critical, warning
}

/// `settings.json`, written by the app and read by the tool on every poll. Whatever the file
/// holds, a load gives usable values: a missing or broken file is the defaults, an unknown rule
/// is `.warning`, and numbers out of range are clamped, because a bad file must never stop a
/// build.
public struct BuildSlotSettings: Codable, Equatable, Sendable {
  public var version = 1
  public var slots = 2
  public var memoryRule = MemoryRule.warning
  public var memoryWaitCapSeconds = 600
  public var slotWaitCapSeconds = 1800

  public static let defaults = BuildSlotSettings()
  public static let slotRange = 1...8

  public init() {}

  private enum CodingKeys: String, CodingKey {
    case version, slots, memoryRule, memoryWaitCapSeconds, slotWaitCapSeconds
  }

  /// Field by field, so one bad value costs only that value.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.defaults
    version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? defaults.version
    let slots = (try? container.decodeIfPresent(Int.self, forKey: .slots)) ?? defaults.slots
    self.slots = min(max(slots, Self.slotRange.lowerBound), Self.slotRange.upperBound)
    let rule = (try? container.decodeIfPresent(String.self, forKey: .memoryRule)) ?? nil
    memoryRule = rule.flatMap(MemoryRule.init(rawValue:)) ?? defaults.memoryRule
    let memoryCap = (try? container.decodeIfPresent(Int.self, forKey: .memoryWaitCapSeconds))
    memoryWaitCapSeconds = max(0, memoryCap ?? defaults.memoryWaitCapSeconds)
    let slotCap = (try? container.decodeIfPresent(Int.self, forKey: .slotWaitCapSeconds))
    slotWaitCapSeconds = max(0, slotCap ?? defaults.slotWaitCapSeconds)
  }

  public static func load(from url: URL) -> BuildSlotSettings {
    guard let data = try? Data(contentsOf: url),
      let settings = try? JSONDecoder().decode(BuildSlotSettings.self, from: data)
    else { return .defaults }
    return settings
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}
