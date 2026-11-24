import BuildSlotCore
import Testing

// Which live session a holder or waiter belongs to. Claude Code and Grok Build record a pid, so
// an ancestor names the session; Codex records none, so only its cwd can, and only when one
// session is the unambiguous deepest match.
struct SessionMatchTests {
  private func candidate(_ id: String, _ vendor: String, pid: Int32? = nil, cwd: String = "/r")
    -> MatchCandidate
  {
    MatchCandidate(id: id, vendor: vendor, pid: pid, cwd: cwd, title: id)
  }

  @Test func claudeByPid() {
    let claude = candidate("c", "claude", pid: 650)
    #expect(
      SessionMatch.match(
        ancestors: [700, 650, 1], ancestorNames: ["zsh", "claude", "launchd"], holderCwd: "/r",
        candidates: [candidate("o", "claude", pid: 900), claude]) == claude)
  }

  @Test func grokByPid() {
    let grok = candidate("g", "grok", pid: 650)
    #expect(
      SessionMatch.match(
        ancestors: [700, 650, 1], ancestorNames: ["zsh", "grok", "launchd"], holderCwd: "/r",
        candidates: [grok]) == grok)
  }

  @Test func nearestPidWins() {
    let outer = candidate("outer", "claude", pid: 650)
    let inner = candidate("inner", "claude", pid: 700)
    #expect(
      SessionMatch.match(
        ancestors: [700, 650], ancestorNames: ["claude", "claude"], holderCwd: "/r",
        candidates: [outer, inner]) == inner)
  }

  @Test func codexByCwd() {
    let codex = candidate("x", "codex", cwd: "/r")
    #expect(
      SessionMatch.match(
        ancestors: [700, 650], ancestorNames: ["zsh", "codex"], holderCwd: "/r/apps/apple",
        candidates: [codex]) == codex)
  }

  @Test func codexExactCwd() {
    let codex = candidate("x", "codex", cwd: "/r/apps")
    #expect(
      SessionMatch.match(
        ancestors: [700], ancestorNames: ["codex"], holderCwd: "/r/apps", candidates: [codex])
        == codex)
  }

  @Test func codexAmbiguous() {
    #expect(
      SessionMatch.match(
        ancestors: [700, 650], ancestorNames: ["zsh", "codex"], holderCwd: "/r/apps/apple",
        candidates: [candidate("a", "codex", cwd: "/r"), candidate("b", "codex", cwd: "/r")])
        == nil)
  }

  @Test func codexDeepestWins() {
    let deep = candidate("deep", "codex", cwd: "/r/apps")
    #expect(
      SessionMatch.match(
        ancestors: [700, 650], ancestorNames: ["zsh", "codex"], holderCwd: "/r/apps/apple",
        candidates: [candidate("shallow", "codex", cwd: "/r"), deep]) == deep)
  }

  @Test func noCodexAncestorNoCwdMatch() {
    #expect(
      SessionMatch.match(
        ancestors: [700, 650], ancestorNames: ["zsh", "Terminal"], holderCwd: "/r/apps/apple",
        candidates: [candidate("x", "codex", cwd: "/r")]) == nil)
  }

  @Test func prefixByComponent() {
    #expect(
      SessionMatch.match(
        ancestors: [700], ancestorNames: ["codex"], holderCwd: "/r/apple",
        candidates: [candidate("x", "codex", cwd: "/r/app")]) == nil)
  }

  @Test func cwdMatchIgnoresOtherVendors() {
    #expect(
      SessionMatch.match(
        ancestors: [700], ancestorNames: ["codex"], holderCwd: "/r/apps",
        candidates: [candidate("c", "claude", pid: 9, cwd: "/r")]) == nil)
  }

  @Test func trailingSlashOnCandidateCwd() {
    let codex = candidate("x", "codex", cwd: "/r/")
    #expect(
      SessionMatch.match(
        ancestors: [700], ancestorNames: ["codex"], holderCwd: "/r/apps", candidates: [codex])
        == codex)
  }
}
