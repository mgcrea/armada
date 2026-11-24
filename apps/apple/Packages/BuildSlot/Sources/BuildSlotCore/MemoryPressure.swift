import Darwin

/// The kernel's memory pressure level, as `kern.memorystatus_vm_pressure_level` reports it.
public enum MemoryPressure: Int, Sendable {
  case normal = 1
  case warning = 2
  case critical = 4

  /// The level now. A sysctl that fails or answers a value it never documented reads as
  /// normal, so a broken read never holds a build back.
  public static func current() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
      size == MemoryLayout<Int32>.size
    else { return .normal }
    return MemoryPressure(rawValue: Int(level)) ?? .normal
  }

  public func blocks(under rule: MemoryRule) -> Bool {
    switch rule {
    case .off: false
    case .critical: self == .critical
    case .warning: self != .normal
    }
  }

  public var word: String {
    switch self {
    case .normal: "normal"
    case .warning: "warning"
    case .critical: "critical"
    }
  }
}
