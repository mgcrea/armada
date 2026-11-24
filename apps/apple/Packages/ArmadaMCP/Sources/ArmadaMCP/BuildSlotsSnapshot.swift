import Foundation

/// The machine-wide build queue: its settings, the Mac's memory pressure, and who holds and who
/// waits for each slot.
///
/// **A hop of its own**, read by `armada_get_build_slots` and, for one field per session, by
/// `armada_get_fleet` and `armada_get_session`. The app hands over what its queue monitor last
/// read; no tool call reads the lock files itself.
///
/// **Plain strings, not BuildSlotCore's types**, so this package never depends on the queue's
/// own: `memoryRule` is `off`, `critical` or `warning`, `memoryPressure` `normal`, `warning` or
/// `critical`.
public struct BuildSlotsSnapshot: Sendable {
  /// Settings ▸ Build Slots' switch. Off, the shims run builds unqueued, but a build started
  /// under another Armada's shims can still hold a slot, so the lists may not be empty.
  public let enabled: Bool
  public let slots: Int
  public let memoryRule: String
  public let memoryPressure: String
  public let holders: [Entry]
  public let waiters: [Entry]

  public init(
    enabled: Bool, slots: Int, memoryRule: String, memoryPressure: String, holders: [Entry],
    waiters: [Entry]
  ) {
    self.enabled = enabled
    self.slots = slots
    self.memoryRule = memoryRule
    self.memoryPressure = memoryPressure
    self.holders = holders
    self.waiters = waiters
  }

  /// What a source with no queue answers: switched off, nobody in it.
  public static let empty = BuildSlotsSnapshot(
    enabled: false, slots: 2, memoryRule: "warning", memoryPressure: "normal", holders: [],
    waiters: [])

  /// One build or test run in the queue.
  public struct Entry: Sendable {
    /// The slot held; nil for a waiter.
    public let slot: Int?
    /// The shim's pid.
    public let pid: Int32
    public let label: String
    public let cwd: String
    /// `swift` or `xcodebuild`.
    public let tool: String
    public let argv: [String]
    /// When it took its slot, or when it started waiting.
    public let since: Date
    /// A waiter while a slot stands free: what holds it back is memory, not the queue.
    public let waitsOnMemory: Bool
    /// The session that started it, when Armada could tell.
    public let session: SessionRef?

    public init(
      slot: Int?, pid: Int32, label: String, cwd: String, tool: String, argv: [String],
      since: Date, waitsOnMemory: Bool, session: SessionRef?
    ) {
      self.slot = slot
      self.pid = pid
      self.label = label
      self.cwd = cwd
      self.tool = tool
      self.argv = argv
      self.since = since
      self.waitsOnMemory = waitsOnMemory
      self.session = session
    }
  }

  public struct SessionRef: Sendable {
    public let id: String
    /// `claude`, `codex` or `grok`.
    public let vendor: String
    public let title: String

    public init(id: String, vendor: String, title: String) {
      self.id = id
      self.vendor = vendor
      self.title = title
    }
  }
}
