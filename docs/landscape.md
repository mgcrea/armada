# Landscape

Checked 2026-09-09 and 2026-09-10. Competitors were judged from their READMEs and product
pages, not by using them.

## Standards

### A2A (Agent2Agent)

- **Real and finished.** Governed by the Linux Foundation (named as author on
  https://a2a-protocol.org), Apache-2.0. The `a2aproject/A2A` repo was created 2025-03-25;
  **v1.0.0 shipped 2026-03-12** and v1.0.1 on 2026-05-28. About 25.7k stars.
- **SDKs:** Python, JavaScript (`@a2a-js/sdk` 1.1.0, published 2026-08-26, one dependency:
  `jose`), Java, Go, .NET and Rust, plus a conformance kit (`a2a-tck`) and an inspector.
  **No Swift SDK.**
- **v1.0 is defined in protobuf** (`specification/a2a.proto`), with gRPC and HTTP+JSON
  bindings. Its RPCs: `SendMessage`, `SendStreamingMessage`, `GetTask`, `ListTasks`,
  `CancelTask`, `SubscribeToTask`, `Create/Get/List/DeleteTaskPushNotificationConfig`,
  `GetExtendedAgentCard`. The 0.x JSON-RPC names such as `message/send` are gone.
- **Task states:** submitted, working, completed, failed, canceled, input-required, rejected,
  auth-required, unspecified.
- **Agent card required fields:** `name`, `description`, `supported_interfaces`, `version`,
  `capabilities`, `default_input_modes`, `default_output_modes`, `skills`. Discovery is a
  well-known URL (`/.well-known/agent-card.json`) or a curated registry.
- **Official position: complementary to MCP.** MCP connects an agent to tools; A2A connects
  agents as peers. A2A's docs call wrapping agents as MCP tools inefficient, "because agents
  are designed to negotiate directly".
- **Claude Code and Anthropic support none of it** as of this check.
- Prior art bridging the two: `GongRzhe/A2A-MCP-Server` (about 150 stars).

### MCP

Client-to-server by design. An MCP server can't push anything to the model: plain
notifications are dropped by both Claude Code and Codex. See
[reaching-agents.md](reaching-agents.md).

## Built into Claude Code

`ListAgents` and `SendMessage` (on by default), agent teams (experimental), agent view, and
channels (research preview). See [reaching-agents.md](reaching-agents.md#claude-code-built-ins).

## Session monitors (native macOS)

At least five: [Claude Control](https://github.com/sverrirsig/claude-control),
[Claudoscope](https://github.com/cordwainersmith/Claudoscope), Chive,
[TokenEater](https://github.com/AThevon/TokenEater) (also covers VS Code-family extensions),
and c9watch. All Claude Code only.

## Limit trackers (menu bar)

Eight or more, mostly free: [Claude Usage
Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (also Codex),
[Usagebar](https://usagebar.com/),
[claude-codex-limits](https://github.com/ArrivaRUS/claude-codex-limits),
[SessionWatcher](https://sessionwatcher.com/claude), [Claude
Tracker](https://claudetracker.com/), [ClaudeUsageBar](https://www.claudeusagebar.com/),
Usage4Claude, and steipete's [CodexBar](https://github.com/steipete/codexbar).

## Cross-vendor orchestrators

- **[Claudexor](https://github.com/razzant/claudexor)** (MIT, TypeScript, v3.10.2, about 440
  stars). Runs the Codex, Claude Code, Cursor, OpenCode and Antigravity CLIs headless behind
  one interface. Races the same task across agents, with reviewers from a different model
  family; honest cost and quota accounting ("unknown cost is never $0"); several
  subscriptions per vendor with automatic switching at quota limits; a signed DMG with a
  bundled daemon; remote SSH hosts. It tells users to "log in through Claudexor, not the bare
  vendor CLI"; see the terms concerns in
  [limits-accounts-and-terms.md](limits-accounts-and-terms.md).
- **[Claw Orchestrator](https://github.com/Enderfga/claw-orchestrator)** (MIT, TypeScript,
  about 570 stars). Persistent programmable sessions over the same CLIs, groups of agents
  voting in separate worktrees, fan-out, Planner/Coder/Reviewer loops, and a 77-tool API
  over MCP and ACP.
- **[AppHandoff](https://apphandoff.com/blog/multi-agent-orchestration-claude-code-cursor-codex):**
  hosted MCP coordination (tickets, roles, contracts).
- Cursor shipped parallel-agent orchestration in April 2026.

**What they share:** they run agents in their own runtime rather than watching sessions
started in an editor, and their multi-agent features all go through a central coordinator.
No agent messages another directly.

## The gap Armada targets

Messages between agents across vendors and accounts, for the sessions the user already runs
in their editor. Plus detecting sessions blocked on approval, which no product advertised.
