# Spike code

Throwaway prototypes the findings came from. Not production code; kept so the tests can be
re-run.

| Folder or file | What it tests | Findings |
| --- | --- | --- |
| `SessionWatch.swift`, `drive.sh` | Watching Claude Code sessions, titles and state with FSEvents | [claude-code-sessions.md](../claude-code-sessions.md) |
| `rewake/` | An `asyncRewake` `Stop` hook waking an idle Claude Code session | [reaching-agents.md](../reaching-agents.md#claude-code-asyncrewake-hooks) |
| `identity/` | What a stdio MCP server can learn about the session that started it | [reaching-agents.md](../reaching-agents.md#sender-identity) |
| `delivery/` | MCP notifications, `instructions`, long-poll and channel push, in Claude Code and Codex | [reaching-agents.md](../reaching-agents.md#plain-mcp-notifications-instructions-long-poll) |
| `runtime-cost/` | Startup time and idle memory of a Swift program versus Node | [design.md](../design.md#why-swift-per-session-node-only-once-decided) |
| `codex-liveness/` | How to tell which Codex sessions are live, with no registry to ask | [codex-sessions.md](../codex-sessions.md#which-sessions-are-live) |

Scripts that start a real session use your subscription for a turn or two. They unset the
child-session environment, so the session behaves like one you started yourself.
