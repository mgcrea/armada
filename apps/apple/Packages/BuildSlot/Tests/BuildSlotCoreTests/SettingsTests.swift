import BuildSlotCore
import Foundation
import Testing

// Settings the app writes and the tool reads on every poll, the memory rule, the slot record's
// argv cap and the two fixed paths.
struct SettingsTests {
  private func load(_ json: String) throws -> BuildSlotSettings {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("buildslot-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(json.utf8).write(to: url)
    return BuildSlotSettings.load(from: url)
  }

  @Test func defaultsWhenMissing() {
    let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/settings.json")
    #expect(BuildSlotSettings.load(from: url) == .defaults)
  }

  @Test func defaultsWhenGarbage() throws {
    #expect(try load("{") == .defaults)
  }

  @Test func clampsSlots() throws {
    #expect(try load(#"{"slots":0}"#).slots == 1)
    #expect(try load(#"{"slots":99}"#).slots == 8)
  }

  @Test func clampsCapsAtZero() throws {
    let settings = try load(#"{"memoryWaitCapSeconds":-5,"slotWaitCapSeconds":-1}"#)
    #expect(settings.memoryWaitCapSeconds == 0)
    #expect(settings.slotWaitCapSeconds == 0)
  }

  @Test func clampsCapsAtADay() throws {
    let settings = try load(#"{"memoryWaitCapSeconds":900000,"slotWaitCapSeconds":9000000000}"#)
    #expect(settings.memoryWaitCapSeconds == 86_400)
    #expect(settings.slotWaitCapSeconds == 86_400)
  }

  @Test func unknownRuleIsWarning() throws {
    #expect(try load(#"{"memoryRule":"sometimes"}"#).memoryRule == .warning)
  }

  @Test func roundTrips() throws {
    var settings = BuildSlotSettings.defaults
    settings.slots = 3
    settings.memoryRule = .critical
    settings.memoryWaitCapSeconds = 120
    settings.slotWaitCapSeconds = 900
    let data = try settings.encoded()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("buildslot-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    #expect(BuildSlotSettings.load(from: url) == settings)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(object.keys) == [
        "version", "slots", "memoryRule", "memoryWaitCapSeconds", "slotWaitCapSeconds",
      ])
  }

  @Test func pressureBlocks() {
    #expect(MemoryPressure.warning.blocks(under: .warning))
    #expect(!MemoryPressure.warning.blocks(under: .critical))
    #expect(MemoryPressure.critical.blocks(under: .critical))
    #expect(MemoryPressure.critical.blocks(under: .warning))
    for pressure in [MemoryPressure.normal, .warning, .critical] {
      #expect(!pressure.blocks(under: .off))
    }
    for rule in MemoryRule.allCases {
      #expect(!MemoryPressure.normal.blocks(under: rule))
    }
  }

  @Test func truncatesArgv() {
    let many = (0..<25).map { "arg\($0)" }
    #expect(SlotRecord.truncated(many) == Array(many.prefix(20)) + ["…"])

    let long = SlotRecord.truncated([String(repeating: "x", count: 5000)])
    #expect(long.count == 2)
    #expect(long[0].utf8.count <= 2048)
    #expect(long[1] == "…")

    #expect(SlotRecord.truncated(["swift", "test"]) == ["swift", "test"])
  }

  @Test func recordDatesAreISO8601() throws {
    let date = Date(timeIntervalSince1970: 1_795_000_000)
    let data = try record(pid: 42, startedAt: date).encoded()
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["startedAt"] as? String == "2026-11-18T11:06:40Z")
    #expect(SlotRecord.decoded(from: data) == record(pid: 42, startedAt: date))
  }

  @Test func pathsHonourOverrides() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let overridden = BuildSlotPaths.standard(
      environment: ["ARMADA_BUILDSLOT_DIR": "/x", "ARMADA_BUILDSLOT_SETTINGS": "/y.json"],
      uid: 501, home: home)
    #expect(overridden.lockRoot.path == "/x")
    #expect(overridden.settingsFile.path == "/y.json")

    let standard = BuildSlotPaths.standard(environment: [:], uid: 501, home: home)
    #expect(standard.lockRoot.path == "/private/tmp/armada-build-slots-501")
    #expect(
      standard.settingsFile.path
        == "/Users/someone/Library/Application Support/Armada/build-slots/settings.json")
    #expect(standard.slotFile(1).path == "/private/tmp/armada-build-slots-501/slots/1.lock")
    #expect(
      standard.waitingFile(pid: 77).path == "/private/tmp/armada-build-slots-501/waiting/77.lock")
    #expect(
      standard.waitingTempFile(pid: 77).path
        == "/private/tmp/armada-build-slots-501/waiting/.77.tmp")
  }
}
