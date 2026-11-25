import Foundation
import Testing

@testable import ArmadaProcess

/// The four cases measured on 2026-10-12, moved here from `make unit` with the file they check.
@Suite struct LoginShellTests {
  private func run(_ shell: String, _ flags: [String], _ script: String, timeout: TimeInterval)
    async -> (output: String?, seconds: Double)
  {
    let started = ContinuousClock.now
    let data = await LoginShell.run(shell: shell, flags: flags, script: script, timeout: timeout)
    let elapsed = ContinuousClock.now - started
    return (
      data.map { String(decoding: $0, as: UTF8.self) },
      Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    )
  }

  @Test func whatTheScriptPrintsIsTheResult() async {
    #expect(await run("/bin/zsh", ["-fc"], "printf hello", timeout: 5).output == "hello")
  }

  @Test func aHungInteractiveZshIsCutOffThoughItIgnoresSIGTERM() async {
    let hung = await run("/bin/zsh", ["-fic"], "sleep 5; printf survived", timeout: 0.5)
    #expect(hung.output == nil)
    #expect(hung.seconds < 3)
  }

  @Test func aJobTheProfileLeavesRunningDoesNotHoldTheResultBack() async {
    let orphan = await run("/bin/zsh", ["-fc"], "(sleep 5 &); printf done", timeout: 5)
    #expect(orphan.output == "done")
    #expect(orphan.seconds < 3)
  }

  @Test func aJobThatWritesAfterTheShellExitedIsNotKilledForIt() async throws {
    // On a pipe Armada had stopped reading, the late `echo` would raise SIGPIPE and the job
    // would die before it reached `touch`.
    let marker = FileManager.default.temporaryDirectory.appending(
      path: "armada-late-\(UUID().uuidString)", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: marker) }
    let script = "(sleep 0.5; echo late; touch '\(marker.path)') & printf done"
    #expect(await run("/bin/zsh", ["-fc"], script, timeout: 5).output == "done")
    try? await Task.sleep(for: .seconds(1.5))
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func norDoesAHungInteractiveBash() async {
    let bash = await run("/bin/bash", ["--norc", "--noprofile", "-ic"], "sleep 5", timeout: 0.5)
    #expect(bash.output == nil)
    #expect(bash.seconds < 3)
  }
}
