# Armada

A native macOS app for running many coding agents at once: see every Claude Code and
Codex session across your accounts, track plan limits, and let agents message each other.

**Status on 2026-09-13: the app is built and runs**, covering two of v1's three features —
the session dashboard and plan limits, per Claude account and, as a spike, per Codex home —
plus starting a session in a project on a chosen account, which the original scope had left
out. Messaging is designed and not started. See [implementation.md](implementation.md).

## Start here

| Doc | What it holds |
| --- | --- |
| [implementation.md](implementation.md) | What exists today, the traps in it, how to verify it. **Read first if you are touching the code.** |
| [design.md](design.md) | Decisions, architecture, message flow, open questions. **Read first if you are extending the plan.** |
| [reaching-agents.md](reaching-agents.md) | Measured: every way to get a message to a waiting agent, and how to tell who sent one |
| [claude-code-sessions.md](claude-code-sessions.md) | Measured: reading Claude Code sessions, titles and state from disk |
| [focusing-sessions.md](focusing-sessions.md) | Measured: how a session's pid resolves to the app hosting it, and what that cannot reach |
| [codex-sessions.md](codex-sessions.md) | Measured: Codex's equivalents — session logs, liveness, titles, limits, hooks |
| [limits-accounts-and-terms.md](limits-accounts-and-terms.md) | Plan-limit data, multiple accounts, and what Anthropic's terms allow |
| [landscape.md](landscape.md) | Competitors and standards (A2A) |
| [spike/](spike/README.md) | Throwaway code the measurements came from |
| [releasing.md](releasing.md) | Cutting a release: the secrets CI needs, the version copies it checks, and the push order |

## Related repos

- `~/Projects/mgcrea/mgcrea-ai/mcp-a2a`: unreleased TypeScript A2A bridge. Its A2A peer is
  kept, off by default. Its relay and tools are superseded for v1 messaging.
- `~/Developer/github/swift-mcp-kit`: the author's Swift MCP library. Armada's app uses its
  protocol core (`MCPKit`).
- `~/Projects/apps/bastion`: Swift 6 menu-bar app by the same author. Source for the app
  shell, merging entries into client config files, and the embedded-Node pattern.

## Next steps

The dashboard half of the design shipped ahead of sections 3–5 being written, so those
sections are now partly answered by working code — read
[implementation.md](implementation.md) before writing them up.

1. Cut the first release, 1.0.0, following [releasing.md](releasing.md). The site, the payment
   link and the licence Worker are live; the signed build is what is missing.
2. Review design section 2 (message flow) — the one v1 feature with nothing built.
3. Write sections 3–5: dashboard data, error handling, testing.
4. Run the tests listed in [design.md](design.md#tests-to-run-before-building).
5. Verify the unanswered-`tool_use` rule against a deliberately long tool call
   ([claude-code-sessions.md](claude-code-sessions.md) open question 1). The app ships it as
   best-effort and says so; that is the measurement that would let it stop hedging.
