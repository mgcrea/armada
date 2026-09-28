import Foundation
import MCPKit
import Testing

@testable import ArmadaMCP

@Suite("schedule tools")
struct ScheduleToolsTests {

  private func table(_ store: FakeScheduleStore, source: any FleetSource = FakeFleetSource())
    -> ToolTable
  {
    Tools.table(
      source: source, starter: FakeSessionStarter(), closer: FakeSessionCloser(),
      sender: FakeMessageSender(), focuser: FakeSessionFocuser(), schedules: store)
  }

  private func call(
    _ name: String, _ arguments: JSONValue = .object([:]),
    store: FakeScheduleStore = FakeScheduleStore(), source: any FleetSource = FakeFleetSource(),
    allowWrites: Bool = true
  ) async -> ToolResult {
    await table(store, source: source).call(
      name: name, arguments: arguments, allowWrites: allowWrites)
  }

  @Test("The list is read-only and always listed; save and delete only behind the switch")
  func listing() throws {
    let t = table(FakeScheduleStore())
    let read = t.listing(allowWrites: false).map(\.name)
    #expect(read.contains("armada_list_schedules"))
    #expect(!read.contains("armada_save_schedule"))
    #expect(!read.contains("armada_delete_schedule"))
    let save = try #require(
      t.listing(allowWrites: true).first { $0.name == "armada_save_schedule" })
    #expect(save.gate == .requiresWrites)
    #expect(save.annotations.destructiveHint == false)
    #expect(save.annotations.idempotentHint == false)
    let delete = try #require(
      t.listing(allowWrites: true).first { $0.name == "armada_delete_schedule" })
    #expect(delete.annotations.destructiveHint == true)
    #expect(Tools.readToolNames.contains("armada_list_schedules"))
  }

  @Test("Listing returns every row, with prompts cut to chars")
  func list() async throws {
    let result = await call("armada_list_schedules", ["chars": 100])
    #expect(!result.isError)
    let rows = try #require(result.structuredContent?["schedules"]?.arrayValue)
    #expect(rows.count == 2)
    #expect(rows[0]["id"] == .string("daily-intel"))
    #expect(rows[0]["accountId"] == .string("/Users/me/.codex"))
    #expect(rows[0]["summary"] == .string("daily at 07:00"))
    #expect(rows[0]["editable"] == .bool(true))
    let prompt = try #require(rows[0]["prompt"]?.stringValue)
    #expect(prompt.count == 101)
    #expect(prompt.hasSuffix("…"))
    #expect(rows[1]["editable"] == .bool(false))
    #expect(rows[1]["prompt"] == nil)
    #expect(rows[1]["readOnlyReason"]?.stringValue?.contains("Claude app") == true)
    #expect(result.text.contains("2 schedules"))
  }

  @Test("An unlicensed Armada says it is watching nothing")
  func listNotEntitled() async {
    let store = FakeScheduleStore()
    store.isEntitled = false
    let result = await call("armada_list_schedules", store: store)
    #expect(result.structuredContent?["watching"] == .bool(false))
  }

  @Test("Listing filters by vendor, and refuses an unknown one")
  func listVendor() async throws {
    let codex = await call("armada_list_schedules", ["vendor": "codex"])
    #expect(try #require(codex.structuredContent?["schedules"]?.arrayValue).count == 1)
    let bad = await call("armada_list_schedules", ["vendor": "cursor"])
    #expect(bad.isError)
    #expect(bad.text.contains("codex or claude"))
  }

  @Test("An empty list says where schedules come from")
  func emptyList() async {
    let store = FakeScheduleStore()
    store.rows = []
    let result = await call("armada_list_schedules", store: store)
    #expect(result.text.contains("No scheduled tasks"))
  }

  @Test("With writes off, save and delete are refused and nothing is written")
  func gateOff() async {
    let store = FakeScheduleStore()
    let save = await call(
      "armada_save_schedule",
      ["name": "x", "prompt": "y", "rrule": "RRULE:FREQ=DAILY", "project": "armada"],
      store: store, allowWrites: false)
    let delete = await call(
      "armada_delete_schedule", ["id": "daily-intel"], store: store, allowWrites: false)
    #expect(save.isError && save.text.contains("Allow writes"))
    #expect(delete.isError)
    #expect(store.saveRequests.isEmpty && store.deleteRequests.isEmpty)
  }

  @Test("An unlicensed Armada saves and deletes nothing, even without `project`")
  func notEntitled() async {
    let store = FakeScheduleStore()
    let source = FakeFleetSource()
    source.projectsFixture = FakeFleetSource.projects(isEntitled: false)
    let update = await call(
      "armada_save_schedule", ["id": "daily-intel", "status": "paused"], store: store,
      source: source)
    let delete = await call(
      "armada_delete_schedule", ["id": "daily-intel"], store: store, source: source)
    #expect(update.isError)
    #expect(delete.isError)
    #expect(store.saveRequests.isEmpty && store.deleteRequests.isEmpty)
  }

  @Test("A create resolves the project and passes every field through")
  func create() async throws {
    let store = FakeScheduleStore()
    let result = await call(
      "armada_save_schedule",
      [
        "name": "Daily intel", "prompt": "Research.", "rrule": "RRULE:FREQ=DAILY;BYHOUR=7",
        "project": "armada", "model": "gpt-5.5", "reasoningEffort": "high", "status": "paused",
      ], store: store)
    #expect(!result.isError)
    let request = try #require(store.saveRequests.first)
    #expect(request.id == nil)
    #expect(request.projectID == FakeFleetSource.armadaProject)
    #expect(request.rrule == "RRULE:FREQ=DAILY;BYHOUR=7")
    #expect(request.status == "paused")
    #expect(result.text.contains("Scheduled Daily intel"))
    #expect(result.structuredContent?["schedule"]?["created"] == .bool(true))
  }

  @Test("A paused save says Codex will not run it, not that it runs it")
  func savePausedAnswer() async throws {
    let store = FakeScheduleStore()
    store.outcome = .saved(
      ScheduleChange(
        id: "daily-intel", name: "Daily intel", account: "Codex", summary: "daily at 07:00",
        status: "paused", created: false))
    let result = await call(
      "armada_save_schedule", ["id": "daily-intel", "status": "paused"], store: store)
    #expect(!result.isError)
    #expect(!result.text.contains("Codex runs it."))
    #expect(result.text.contains("Codex will not run it until it is active."))
  }

  @Test("A create without its required fields is refused before the store")
  func createMissing() async {
    let store = FakeScheduleStore()
    let result = await call(
      "armada_save_schedule", ["name": "x", "project": "armada"], store: store)
    #expect(result.isError)
    #expect(result.text.contains("prompt") && result.text.contains("rrule"))
    #expect(store.saveRequests.isEmpty)
  }

  @Test("An update needs only the id, and omitted fields stay nil for the app to keep")
  func update() async throws {
    let store = FakeScheduleStore()
    let result = await call(
      "armada_save_schedule", ["id": "daily-intel", "status": "paused"], store: store)
    #expect(!result.isError)
    let request = try #require(store.saveRequests.first)
    #expect(request == SaveScheduleRequest(id: "daily-intel", status: "paused"))
  }

  @Test("An unsaved project, a bad status and a long prompt are refused")
  func refusals() async {
    let store = FakeScheduleStore()
    let project = await call(
      "armada_save_schedule",
      ["name": "x", "prompt": "y", "rrule": "RRULE:FREQ=DAILY", "project": "nowhere"],
      store: store)
    #expect(project.isError && project.text.contains("No project matches"))
    let status = await call("armada_save_schedule", ["id": "a", "status": "soon"], store: store)
    #expect(status.isError && status.text.contains("active or paused"))
    let long = await call(
      "armada_save_schedule",
      ["id": "a", "prompt": .string(String(repeating: "x", count: 16_001))], store: store)
    #expect(long.isError && long.text.contains("16000"))
    #expect(store.saveRequests.isEmpty)
  }

  @Test("The store's refusal comes back word for word")
  func storeRefusal() async {
    let store = FakeScheduleStore()
    store.outcome = .refused("RRULE:FREQ=YEARLY is not hourly, daily or weekly.")
    let result = await call(
      "armada_save_schedule", ["id": "a", "rrule": "RRULE:FREQ=YEARLY"], store: store)
    #expect(result.isError)
    #expect(result.text == "RRULE:FREQ=YEARLY is not hourly, daily or weekly.")
  }

  @Test("Delete passes the id and account through and reports what went")
  func delete() async throws {
    let store = FakeScheduleStore()
    store.outcome = .deleted(
      ScheduleChange(
        id: "daily-intel", name: "Daily intel", account: "Codex", summary: "daily at 07:00",
        status: "active", created: false))
    let result = await call(
      "armada_delete_schedule", ["id": "daily-intel", "account": "Codex"], store: store)
    #expect(!result.isError)
    #expect(store.deleteRequests == [DeleteScheduleRequest(id: "daily-intel", account: "Codex")])
    #expect(result.text.contains("Removed Daily intel"))
  }

  @Test("Delete without an id is refused before the store")
  func deleteMissingID() async {
    let store = FakeScheduleStore()
    let result = await call("armada_delete_schedule", [:], store: store)
    #expect(result.isError)
    #expect(result.text.contains("Pass `id`"))
    #expect(store.deleteRequests.isEmpty)
  }
}
