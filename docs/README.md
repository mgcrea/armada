# Armada

A native macOS app for running many coding agents at once: see every Claude Code and
Codex session across your accounts, track plan limits, and let agents message each other.

**Status on 2026-09-10: design in progress, nothing built.** The architecture is settled;
the message flow is drafted and waiting for review. Three design sections remain, then a
written spec and an implementation plan.

## Start here

| Doc | What it holds |
| --- | --- |
| [design.md](design.md) | Decisions, architecture, message flow, open questions, next steps. **Read first.** |
| [reaching-agents.md](reaching-agents.md) | Measured: every way to get a message to a waiting agent, and how to tell who sent one |
| [claude-code-sessions.md](claude-code-sessions.md) | Measured: reading Claude Code sessions, titles and state from disk |
| [codex-sessions.md](codex-sessions.md) | Codex's equivalents: session logs, limits, hooks |
| [limits-accounts-and-terms.md](limits-accounts-and-terms.md) | Plan-limit data, multiple accounts, and what Anthropic's terms allow |
| [landscape.md](landscape.md) | Competitors and standards (A2A) |
| [spike/](spike/README.md) | Throwaway code the measurements came from |

## Related repos

- `~/Projects/mgcrea/mgcrea-ai/mcp-a2a`: unreleased TypeScript A2A bridge. Its A2A peer is
  kept, off by default. Its relay and tools are superseded for v1 messaging.
- `~/Developer/github/swift-mcp-kit`: the author's Swift MCP library. Armada's app uses its
  protocol core (`MCPKit`).
- `~/Projects/apps/bastion`: Swift 6 menu-bar app by the same author. Source for the app
  shell, merging entries into client config files, and the embedded-Node pattern.

## Next steps

1. Review design section 2 (message flow).
2. Write sections 3–5: dashboard data, error handling, testing.
3. Run the tests listed in [design.md](design.md#tests-to-run-before-building).
4. Turn the design into a spec, then an implementation plan.
