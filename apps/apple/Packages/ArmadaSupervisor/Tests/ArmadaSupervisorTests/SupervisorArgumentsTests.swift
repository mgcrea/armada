import Foundation
import Testing

@testable import ArmadaSupervisor

@Suite("Supervisor arguments")
struct SupervisorArgumentsTests {
  private let argv = SupervisorArguments.arguments(
    mcpConfig: "/tmp/voice/armada-mcp.json", resume: nil)

  /// The value following `flag`, which must appear exactly once.
  private func value(after flag: String, in arguments: [String]) -> String? {
    guard arguments.filter({ $0 == flag }).count == 1, let index = arguments.firstIndex(of: flag),
      index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
  }

  @Test("built-in tools are off and only Armada's server is loaded")
  func lockdown() {
    #expect(value(after: "--tools", in: argv) == "")
    #expect(argv.contains("--strict-mcp-config"))
    #expect(value(after: "--mcp-config", in: argv) == "/tmp/voice/armada-mcp.json")
    #expect(value(after: "--setting-sources", in: argv) == "local")
    #expect(argv.contains("--disable-slash-commands"))
  }

  @Test("voice may call the read tools and is denied the one that starts sessions")
  func tools() {
    let allowed = value(after: "--allowedTools", in: argv)?.split(separator: ",").map(String.init)
    #expect(
      allowed == [
        "mcp__armada__armada_needs_attention", "mcp__armada__armada_get_fleet",
        "mcp__armada__armada_get_session", "mcp__armada__armada_get_usage",
        "mcp__armada__armada_get_projects", "mcp__armada__armada_read_transcript",
      ])
    #expect(value(after: "--disallowedTools", in: argv) == "mcp__armada__armada_start_session")
    #expect(allowed?.contains { $0.contains("start_session") } == false)
  }

  @Test("nothing that skips permissions or sign-in is ever passed")
  func noBypass() {
    for argument in argv {
      #expect(!argument.contains("dangerously"))
      #expect(!argument.contains("bypassPermissions"))
      #expect(argument != "--bare")
      #expect(argument != "--safe-mode")
    }
  }

  @Test("stream-json in and out, on a print session")
  func streaming() {
    #expect(argv.first == "-p")
    #expect(value(after: "--input-format", in: argv) == "stream-json")
    #expect(value(after: "--output-format", in: argv) == "stream-json")
    #expect(argv.contains("--verbose"))
    #expect(argv.contains("--include-partial-messages"))
  }

  @Test("resume only when a session id is known")
  func resume() {
    #expect(!argv.contains("--resume"))
    let resumed = SupervisorArguments.arguments(mcpConfig: "/tmp/x.json", resume: "5f401944")
    #expect(value(after: "--resume", in: resumed) == "5f401944")
  }

  @Test("the brief gains a language sentence only when a reply language is fixed")
  func replyLanguage() throws {
    #expect(value(after: "--append-system-prompt", in: argv) == VoiceBrief.text)
    let english = SupervisorArguments.arguments(
      mcpConfig: "/tmp/x.json", resume: nil, replyLanguage: .fixed("en"))
    let brief = try #require(value(after: "--append-system-prompt", in: english))
    let sentence = try #require(ReplyLanguage.fixed("en").instruction)
    #expect(brief == VoiceBrief.text + " " + sentence)
  }

  @Test("a question survives quotes and newlines, one line per frame")
  func userFrame() throws {
    let data = SupervisorArguments.userFrame("What did \"Bastion\" say?\nAnd why?")
    #expect(data.last == 0x0A)
    #expect(data.dropLast().contains(0x0A) == false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["type"] as? String == "user")
    let message = try #require(object["message"] as? [String: Any])
    #expect(message["role"] as? String == "user")
    #expect(message["content"] as? String == "What did \"Bastion\" say?\nAnd why?")
  }

  @Test("the interrupt frame is a control request with Armada's id")
  func interruptFrame() throws {
    let object = try #require(
      try JSONSerialization.jsonObject(with: SupervisorArguments.interruptFrame) as? [String: Any])
    #expect(object["type"] as? String == "control_request")
    #expect(object["request_id"] as? String == SupervisorArguments.interruptRequestID)
    #expect((object["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
  }

  @Test("inherited session variables are dropped, the person's own configuration is kept")
  func environment() {
    let base = [
      "PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1",
      "CLAUDE_CODE_SESSION_ID": "abc", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CONFIG_DIR": "/x",
    ]
    #expect(
      SupervisorArguments.environment(from: base)
        == ["PATH": "/usr/bin", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CONFIG_DIR": "/x"])
  }

  @Test("tool labels resolve prefixed and bare names")
  func labels() {
    #expect(
      ToolLabels.label(for: "mcp__armada__armada_needs_attention") == "Checking who needs you…")
    #expect(ToolLabels.label(for: "armada_get_usage") == "Checking your plan limits…")
    #expect(ToolLabels.label(for: "something_new") == "Working…")
    for tool in SupervisorArguments.readTools {
      #expect(ToolLabels.label(for: tool) != "Working…", "\(tool) has no label")
    }
  }
}
