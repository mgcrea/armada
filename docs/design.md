# Armada design

Status on 2026-09-10: **design in progress, nothing built.** Section 1 is decided, section 2
is drafted and waiting for review, sections 3–5 are notes only. After section 5 comes a
written spec, then an implementation plan.

> **Update 2026-09-11: parts of this are built.** The session dashboard and plan limits
> exist and run, per Claude account and — added the same day as a spike — per Codex home,
> ahead of sections 3–5 being written. So where this doc and the app disagree about those
> two, the app is what happened and [implementation.md](implementation.md) describes it.
> Section 3's Codex bullets in particular were written before anyone had read a rollout;
> [codex-sessions.md](codex-sessions.md) now has the measurements. Everything in section 1's messaging
> architecture (`hubctl`, the socket, hook installation, the messaging MCP surface) is still
> design only, and still the plan. This doc is not stale as a *plan*; it is just no longer the only
> place to look.

Markers: **Decided** (agreed with the author), **Drafted** (proposed, not yet reviewed),
**Open** (needs a decision or a test). This doc states conclusions; the evidence is in the
findings docs listed in [README.md](README.md).

## What Armada is

A native macOS menu-bar app for someone running many coding agents at once. The reference
case is 16 or more concurrent Claude Code sessions in the VS Code extension. It shows every
session across vendors and accounts, tracks plan limits, and lets agents message each other.

## Why a standalone app (Decided)

- **Security.** Owning the code and the release channel is a requirement for client work.
- **Flexibility.** Features come from the author's needs, not a host product's positioning.
- **Research.** The factory is the product. Armada is the instrument for studying how to get
  more output from agents.

The market is crowded (see [landscape.md](landscape.md)). That was weighed and accepted:
Armada is primarily a research instrument. Why it isn't a Bastion feature or an MCP server
is in the decision log.

## Scope (Decided)

- **v1 watches; it doesn't host agents.** It observes sessions started in VS Code, a
  terminal, or the Codex app. **Amended 2026-09-13:** it now also *starts* them — New
  Session opens a terminal window with `claude` or `codex` running in a chosen project on
  a chosen account, which is the same thing the person would have typed. Armada does not
  own the process, hold its pipes or talk to it, and the session comes back through the
  watchers like any other. Whether Armada ever *hosts* an agent — owning the process and
  driving the conversation — is still undecided and still out of v1. **Amended 2026-09-15:** it
  also starts one when an agent asks, through `armada_start_session` — behind the MCP server's
  Allow writes switch, only in a folder the person saved as a project, with an optional opening
  message. The terms are unchanged: a terminal window, a session Armada does not own, and every
  permission still asked of the person.
- **Armada never holds vendor credentials.** No "sign in with Claude", and nothing reads or
  stores OAuth tokens. See [limits-accounts-and-terms.md](limits-accounts-and-terms.md).
- **Local only.** One Mac, several accounts per vendor, across vendors. No sync between
  machines, no multi-user.
- **Vendors in v1:** Claude Code and Codex.
- **The product name** can't use "Claude Code" or "Anthropic".

## v1 features (Decided)

1. **Session dashboard** across accounts and vendors: title, project, account, and state
   (working, waiting for you, blocked on approval, idle).
2. **Limits per account:** 5-hour and 7-day windows with reset times.
3. **Direct messages between agents.** Claude Code's built-in `SendMessage` already covers
   Claude-to-Claude within one account, so v1's value is messages across vendors and
   across accounts.

## Roadmap (ideas, after v1)

- **Shared project board:** agents post findings, decisions and blockers per project.
- **Task handoff between agents,** using the A2A task model. The receiver treats a task as a
  proposal it may accept. mcp-a2a's A2A peer is the starting point.
- **App suggests, you forward:** Armada spots when one agent's output matters to another
  and proposes forwarding it.
- **Research instrumentation** from Claude Code's OpenTelemetry export: tokens, cost,
  active time, time blocked on the user, per session, prompt and account.
- **On-demand triage agent** that reads across all sessions ("which should I look at
  first?"). **Shipped 2026-09-14 as the supervisor**: a read-only loopback MCP endpoint in the
  app, and a Claude Code session started with it attached. Next: an "allow actions" switch for
  a focus tool. Voice shipped on 2026-09-15, below.
- **Voice for the supervisor.** **Shipped 2026-09-15** as Settings ▸ Voice: a global shortcut,
  on-device speech recognition, a headless `claude` Armada runs that answers through the MCP server, and
  the reply spoken on the Mac. It rests on this research:
  - **Neither route to Claude takes audio.** The Messages API accepts text and images only;
    [an audio content type](https://github.com/anthropics/anthropic-sdk-python/issues/1198)
    was requested on 2026-02-23 and is open. Codex CLI removed its push-to-talk in 0.118.0 and
    added realtime audio conversations in 0.145.0, but only inside its own client.
  - **Claude Code's own `/voice`** is push-to-talk dictation into its prompt, transcribed on
    Anthropic's servers, free of usage and only for Claude.ai sign-ins
    ([docs](https://code.claude.com/docs/en/voice-dictation)). It needs the terminal focused
    and never speaks a reply, which is the gap Armada's voice fills. In a Terminal supervisor
    it works today with no change to Armada.
  - **Recognition: Parakeet v3, and Apple's dictation until it is there.** Apple's
    `DictationTranscriber` has to be given one locale before you speak, which does not work for a
    French speaker who uses English words. Parakeet TDT 0.6B v3, through FluidAudio, works out
    which of 25 languages is spoken. On four recorded French questions it detected French every
    time and heard "Salut Armada" and "roadmap" where Apple heard "Hermana" and "Run map", in
    0.07–0.14 s a question against 0.2–0.4 s; Apple spelled one project name better. It is not
    the most accurate open model on French (Canary-1B-v2, Qwen3-ASR and Cohere Transcribe score
    better on published benchmarks), but it has a maintained Swift path and was already on the
    Mac. FluidAudio's streaming managers are English-only or a weaker multilingual model, so live
    words come from transcribing the growing buffer again every half second, at most 0.125 s a
    pass.
  - **Synthesis: a system voice, or Kokoro once downloaded.** `AVSpeechSynthesizer`, one
    sentence at a time as the reply streams, is the default. Checked on 2026-09-15: neither
    macOS 26 nor 27 added a synthesis voice apps can use, and Siri's voices are not open to them.
    Kokoro-82M, through FluidAudio's `KokoroAneManager`, is Apache-2.0 for code and weights, about
    95 MB, runs on the Neural Engine, and turns text into phonemes with a lexicon and a small G2P
    model rather than GPL eSpeak. NVIDIA's Magpie TTS was the other candidate: it tied Kokoro on
    Artificial Analysis's arena (Elo 1061 each) at 364M parameters, its open weights have no voice
    cloning, and its one usable Mac port is pre-1.0. Kokoro is opt-in and never makes an answer
    wait: a sentence goes to the system voice while Kokoro loads or when it fails.
  - **No wake phrase.** Any always-listening detector keeps the orange microphone dot on all
    day, and Porcupine validates its key over the network. macOS's Vocal Shortcuts could
    trigger voice without Armada listening at all, and remains an option.

  Audio never leaves the Mac. `make audit` gains one entitlement, the microphone, and one network
  allowance: FluidAudio's model downloader, built into its own `ArmadaSpeech` framework so the
  allowance names one binary, and run only from the Download buttons, one for each model.

## Security model (Drafted)

**In scope:** an agent that has picked up malicious instructions and misuses messaging to
steer other agents.

**Out of scope:** other programs running as the same macOS user. They can already rewrite
agents' configs and read transcripts, so nothing in Armada changes their reach.

Why messaging needs this: **Claude acts on text delivered by a hook** (verified), whereas it
refused the same request delivered through a channel. Whatever delivers messages can steer
every agent on the machine. So:

- **The router decides** whether a message is delivered, never the sender.
- **Who may message whom** is an explicit policy per pair of agents.
- An optional **confirm-before-delivery** mode asks the user first.
- Every delivered message is **labeled** with the sender's vendor, account and session name,
  and says it came through Armada.
- Every message goes to an **audit log**.
- Armada holds **no vendor credentials**.

## 1. Architecture (Decided)

### Components

One signed app bundle with three parts.

**The app** (menu bar, launches at login) is the only long-running process. It owns:

- a Unix socket server;
- the message router: queue, permissions, confirmation prompts, audit log;
- session watching: for each Claude config folder, the session list, transcripts and usage
  cache; for Codex, the session logs;
- MCP handling for agents' `send_message` and `list_agents` calls, using swift-mcp-kit's
  protocol core;
- the dashboard.

**`hubctl`** (working name), a small signed Swift program in the bundle. Nothing talks to
the socket except through it:

- `hubctl event` is called by hooks to report session events.
- `hubctl wait` is Claude's `Stop` rewake hook. It waits for a message addressed to its
  session, confirms receipt, prints it, and exits with code 2.
- `hubctl mcp` is the stdio MCP server each agent starts. It's a thin relay: it forwards MCP
  messages to the app over the socket, tagged with its parent PID, and returns the answers.
  It has no tool logic of its own.

**Config entries Armada installs** in each account: the hooks and the `hubctl mcp` server
entry. For Claude Code, that's `settings.json` in each config folder; for Codex,
`hooks.json` or `config.toml`. They're merged in with backups and removable in one click.
Bastion already does this kind of merge (`ClientWiring.swift`, `ClientWiringTOML.swift`,
`ClientWiringMerge.swift`).

### Rules that follow from using a socket

- **Agents never wait on Armada.** If the socket isn't there, `hubctl` exits 0 at once. A
  closed app means no messages, never a stuck agent.
- **Launch at login is on by default,** because nothing works while the app is closed.
- **State is rebuilt at launch.** Hook events fired while the app was closed are lost. The
  dashboard rebuilds from disk (session lists, transcripts, Codex logs); only the exact
  timing of that window's events is gone.
- **The message queue is saved to disk,** so quitting or updating doesn't drop messages that
  haven't been delivered.
- **The socket is locked down.** It lives in a folder only the user can open, and each
  connection is checked for the user's ID and for Armada's own signed `hubctl`. That keeps
  other programs off it; who may message whom is still the router's call.
- **Delivery is confirmed.** `hubctl wait` acknowledges receipt before exiting, so a message
  counts as delivered only once the agent has it.

### Hard constraints

- **Each agent must start its own `hubctl mcp`.** The sender is identified by the relay's
  parent process (section 2). Never run it as a Bastion-supervised server: Bastion starts
  its children itself and shares one child across clients.
- **Armada can't be App-Sandboxed.** It writes into other tools' config files (`~/.claude`,
  `~/.codex`). Distributed with Developer ID, like Bastion.

### Why Swift per session, Node only once (Decided)

Two processes run for every open session: the MCP relay the whole time, and Claude's `wait`
hook while the session is idle. Their cost multiplies with the number of sessions, which is
exactly what Armada exists to scale.

Measured on this Mac, each process idle and blocked on stdin, against Bastion's embedded
Node v24.18.0:

| | Swift (`swiftc -O`) | Node |
| --- | --- | --- |
| Size | 54 KB binary | 116 MB runtime |
| Cold start (read stdin, env, parent PID) | 4.0 ms | 24.3 ms |
| Physical footprint (`vmmap --summary`) | 1.6 MB | 12.1 MB bare; 35.6 MB with MCP SDK + zod |
| RSS (counts shared memory, overstates both) | 5.6 MB | 44.8 MB bare; 71.4 MB with MCP SDK + zod |

At 16 sessions that's about **750 MB for a Node relay plus waiter, versus under 100 MB in
Swift.** Startup time alone wouldn't decide it; memory does. So:

- **Per session, Swift:** `hubctl`.
- **Once per machine, Node:** mcp-a2a's A2A peer, off by default. There's no official Swift
  A2A SDK.

Script: [spike/runtime-cost/measure.sh](spike/runtime-cost/measure.sh).

### Libraries

- **swift-mcp-kit** (`~/Developer/github/swift-mcp-kit`, v1.0.0). Armada uses `MCPKit`, its
  dependency-free protocol core. The seam is
  `MCPServer.respond(to:allowWrites:) async -> MCPResponse`. Parsing is tied to HTTP today
  (`Dialect.parse(headers:body:)`), and responses carry an `httpStatus`, so **a non-HTTP
  path has to be added**: framing for messages relayed over the socket, plus remembering
  each connection's negotiated protocol version for clients that use the `initialize`
  handshake. In tests, Claude Code negotiated `2025-11-25` and Codex `2025-06-18` over
  stdio; `MCPKit` speaks both, plus `2026-07-28`. Follow Almanac's pattern (`AlmanacMCP`: a
  `ToolTable` built over a data-source protocol, tested against a fake).
- **Not `MCPKitLoopback` for messaging.** One shared bearer token over HTTP can't tell which
  session is calling, and it would put that token in every agent's config.
- **`MCPKitLoopback` for the supervisor.** The objection above is about messaging, where the
  sender's identity decides delivery. The supervisor endpoint has one caller, the person who
  started the session and holds the token, asking read-only questions. See the decision log.
- **mcp-a2a** (`~/Projects/mgcrea/mgcrea-ai/mcp-a2a`, TypeScript, v0.1.0, unreleased, 87
  passing tests). Its **A2A peer** (daemon on `127.0.0.1:41241`, agent card, incoming A2A
  tasks) stays, **off by default**. Its stdio relay and its 12 `a2a_*` tools are superseded
  for v1 messaging. Its design carries over: incoming requests are proposals, answering is a
  gated write, responses are shaped, and the long-poll wait is capped at 240s with a fix for
  missed wake-ups. Its `FileTaskStore` is used directly by the tools, `createServer`, the
  daemon and the executor, with no interface in between. When Armada replaces the store,
  isolate the peer or move it onto a socket client, so it keeps passing its tests.

## 2. How a message moves (Drafted, awaiting review)

### Sending

1. An agent calls `send_message(to, text)` through its `hubctl mcp` relay.
2. The relay forwards the call over the socket, along with who's sending:
   - **Claude Code (verified):** the app looks up the relay's parent PID in the Claude
     session list. This survives `/clear`.
   - **Codex (to test):** a `PreToolUse` hook on the send tool first asks Armada for a
     one-time token and adds it to the call's arguments with `updatedInput`. The relay
     forwards it, and Armada matches it to the hook's real `session_id`. The model can't
     forge a token Armada issued moments earlier for a single use.
3. The router finds the recipient by name, checks who may message whom, asks the user first
   if confirm-before-delivery is on for that pair, saves the message to the queue, and
   writes an audit entry.

### Delivering to Claude Code

**Armada cannot use Claude Code's own peer socket for this. Tested 2026-09-13.** The
alternative was attractive on paper — `/tmp/cc-socks/<pid>.sock` already implements
delivery, idle subscription and receipts, and using it would drop a per-session process
and keep the Claude half of the app read-only. It does not work, for a structural reason:

> The inbox authenticates the **connecting process**, not the bearer of a token. The
> server reads the peer's pid off the socket and looks up that pid's own session key; a
> connection from a pid with no registered session is dropped as unauthenticated. The
> control was run against one session started for the purpose: a `SendMessage` from a
> sibling session landed twice in its output, while a direct connection carrying the
> correct `peerToken` from a plain process landed nothing. Same socket, same session,
> same minute. See
> [reaching-agents.md](reaching-agents.md#the-transport-underneath-sendmessage).

Armada is a GUI app, not a session, so it can never be that pid. **The hook path below is
therefore the design, not a fallback**, and `hubctl wait` is not redundant.

- **Idle:** its `Stop` hook's `hubctl wait` is already connected. Armada sends the message,
  `wait` acknowledges it and exits with code 2, and Claude wakes within about a second
  (verified in the terminal and in VS Code's stream-json mode).
- **Busy:** the message waits. When the turn ends, the new `wait` gets it immediately.
  **The registry now says which state a session is in** — `status` is `busy` / `waiting` /
  `idle` since 2.1.269, with `waitingFor` naming what a waiting one wants — so the router
  can know whether to expect a prompt delivery or a queued one without inferring it and
  without a hook firing first.
- **Idle for longer than the hook's timeout:** unreachable until its next turn ends. How
  long a timeout holds is open, and remains the one real gap in this path.

### Delivering to Codex

- **Codex can't be woken while idle.**
- **Mid-turn:** when the turn ends, a `Stop` hook returns `decision: "block"` with the
  message as `reason`, and Codex keeps going.
- **Idle:** the message arrives as context the next time the user prompts it
  (`UserPromptSubmit` with `additionalContext`).
- **Optional listening mode:** the agent calls a `wait_for_message` tool that blocks for up
  to 240s and gets called again. Codex hard-fails tool calls at 300s.

### What the recipient sees

Every message is labeled with the sender's vendor, account and session name, and says it
came through Armada.

### Addressing

**Cross-account addressing is the thing Armada uniquely provides, and it is now measured.**
Claude Code's own `ListAgents`, run from a session in `~/.claude-skitrust`, listed 15 peers
and **not one** of the eight live sessions in `~/.claude` — because the session registry
lives inside each config folder and the tool reads only its own. The transport underneath
has no such boundary: one `cc-socks` directory per uid held both accounts' sockets
interleaved. So the split is discovery, not reach, and `ClaudeConfigFolder.discoverAll()`
is the half Claude Code does not have.

`list_agents` returns names agents can use:

- **Claude Code:** the session `name` from the session list (for example `bastion-ae`). It
  stays the same across `/clear`. Whether it survives a resume is unknown, since a resumed
  session gets a new `sessionId` and a new session-list entry.
- **Codex:** there's no name, so Armada assigns one from the project plus a short session ID.

## 3. Dashboard data (To write)

Facts to design from:

- **Claude sessions:** each config folder's `sessions/<pid>.json`, with `claude agents
  --json` as a fallback. The title is the **newest** `ai-title` in the transcript; reading
  the last 64KB finds it 96% of the time. Resumed and never-prompted sessions have no title
  on disk. See [claude-code-sessions.md](claude-code-sessions.md).
- **Claude state:** once hooks are installed, documented events cover it: `SessionStart`,
  `UserPromptSubmit`, `Stop`, `PermissionRequest` (the moment approval is requested),
  `Notification` (`permission_prompt` after about 6s, `idle_prompt`, `agent_needs_input`,
  `agent_completed`) and `SessionEnd`. Each carries `session_id` and `transcript_path`.
  Transcripts fill in sessions that started before Armada: a last entry with
  `stop_reason: end_turn` means waiting for the user; an unanswered `tool_use` means a tool
  is running or approval is pending, which hooks tell apart.
- **Codex sessions:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, with explicit
  `task_started` and `task_complete` events, plus Codex hooks. ~~Titles not studied.~~
  **Measured 2026-09-11:** titles are in `session_index.jsonl`; liveness is a flock in
  `thread-writer-locks/`, held for the whole session, and is the *only* place a
  never-prompted session appears; a subagent's `session_meta.session_id` is its parent's.
  See [codex-sessions.md](codex-sessions.md).
- **Limits:** Claude's status-line JSON documents `rate_limits.five_hour` and `seven_day`,
  but very likely never runs in VS Code. The fallback is `cachedUsageUtilization` in the
  account's `.claude.json` (undocumented, cached). Codex writes `rate_limits.primary` and
  `secondary` in every `token_count` event. See
  [limits-accounts-and-terms.md](limits-accounts-and-terms.md).
- **Accounts:** found by locating Claude config folders and Codex homes. **The two are not
  symmetrical, deliberately.** Claude Code's own docs name the `~/.claude-<name>` sibling
  pattern, so scanning for it finds real accounts; Codex documents `CODEX_HOME` with no
  naming convention, so Armada takes `~/.codex` plus whatever `CODEX_HOME` says and invents
  nothing.

## 4. Error handling (To write)

Cases to cover:

- Armada closed or crashed: hooks fail open, events are lost, the queue persists.
- Recipient unreachable (Claude idle past its hook timeout, Codex idle): show "queued,
  waiting for its next turn".
- `wait` killed between receiving and acknowledging: choose at-least-once delivery with a
  message ID the recipient can de-duplicate, or at-most-once.
- A session-list file left behind by a crashed session: check PID liveness. **This is
  Claude-only reasoning.** Codex's liveness marker is an empty lock file with no pid in it,
  so there is nothing to check and a crash-orphaned lock is indistinguishable from a live
  session. `flock(LOCK_SH|LOCK_NB)` would test it and is refused: taking even a shared lock
  on a file Codex holds exclusively could stop a real session starting.
- Config drift: the user edits or removes Armada's hooks, or a merge fails.
- Codex hooks not firing in some setups (reported upstream, unverified): warn per session.
- A stale limits cache: show its age.

## 5. Testing (To write)

Starting points:

- Swift unit tests for the router's policy, identity lookup (parent PID against a fixture
  session list), and the `MCPKit` non-HTTP path.
- `hubctl` against a real socket, including failing open when the socket is absent.
- End-to-end drivers that run real sessions in a pty, from [spike/](spike/README.md),
  in terminal and stream-json modes. The real VS Code panel still needs a manual check.
- mcp-a2a's A2A peer keeps its test suite green.

## Open questions

- **Rewake in the real VS Code panel:** is a turn that arrives unprompted displayed? The
  stream-json emulation passed.
- **How long a session stays reachable:** does a long `timeout` (an hour or more) hold on an
  `asyncRewake` hook? The settings schema only requires a positive number.
- **Codex sender identity:** does the `PreToolUse` token work end to end?
- ~~**Codex process model:** does one Codex process host several conversations?~~
  **Answered 2026-09-11: yes.** `codex … app-server` is a host for the VS Code extension —
  three were running here — and one `codex` process was seen holding writer locks for two
  threads at once. So a Codex process never identifies a session, which is why Armada's
  liveness is per-lock and never per-process.
- **Claude limits in VS Code:** confirm the status line doesn't run there, and find where
  `.claude.json` lives under a non-default `CLAUDE_CONFIG_DIR`.
- **Multiple accounts:** can `claudeCode.environmentVariables` set `CLAUDE_CONFIG_DIR` per
  VS Code workspace? Do separate `CODEX_HOME`s share credentials when Codex uses the
  keychain?
- **Does `SendMessage` reach sessions under a different `CLAUDE_CONFIG_DIR`?** Partly
  answered 2026-09-12: the **transport** already does — the socket directory is per uid,
  not per config folder, and this Mac's held both accounts' sessions at once. What does
  not cross is **discovery**, since the registry lives inside each folder. So the untested
  half is whether `SendMessage` accepts an address it did not enumerate. See
  [reaching-agents.md](reaching-agents.md#the-transport-underneath-sendmessage).
- **Addressing across a resume:** does a resumed Claude session keep its `name`?
- ~~**Does the peer socket carry control requests?**~~ **Answered 2026-09-12: no.** The
  socket is a messaging inbox with no query verb of any kind — see
  [claude-code-sessions.md](claude-code-sessions.md#what-cannot-be-reconstructed-and-the-route-that-could).
  Superseded, kept for the record: `get_context_usage` returns the exact
  `/context` breakdown, and is answered only by whoever owns a session's stdin/stdout or by
  the Remote Control bridge. If `/tmp/cc-socks/<pid>.sock` also accepts a `control_request`,
  a watcher can have it locally. See
  [claude-code-sessions.md](claude-code-sessions.md#what-cannot-be-reconstructed-and-the-route-that-could).

## Tests to run before building

In order of risk to the design:

1. The Codex `PreToolUse` token, end to end. Identity for one of the two vendors rests on it.
2. `asyncRewake` in the real VS Code panel.
3. A long `asyncRewake` timeout.
4. Codex delivery through a `Stop` block and through `UserPromptSubmit` context, in an
   interactive Codex session.
5. The remaining open questions.

Start from [spike/rewake/](spike/rewake/run.sh) and [spike/identity/](spike/identity/run.sh).

## Decision log

| Date | Decision | Alternatives rejected, and why |
| --- | --- | --- |
| 2026-09-09 | Claude-to-Claude messaging needs nothing new | `SendMessage` and `ListAgents` are on by default |
| 2026-09-09 | An A2A MCP server would be a dedicated server, not part of Bastion (later superseded by the app) | Bastion's gateway is deliberately stateless, closes every connection, authenticates before routing, and has no session model or daemon; A2A needs the opposite |
| 2026-09-10 | A standalone native app, not only an MCP server | Monitoring isn't MCP-shaped; the app is the long-running process an MCP-only design lacked |
| 2026-09-10 | Standalone, not a Bastion feature | Security (own release channel), flexibility, research; the crowded market was accepted |
| 2026-09-10 | v1 watches sessions rather than running them | Running agents (Claudexor's model) raises subscription-terms questions for client distribution; the author works in the VS Code extension |
| 2026-09-13 | Deliver to Claude Code through Armada's own hook path, not through Claude Code's peer socket | The peer socket authenticates the connecting pid against its own session key, so a non-session process is dropped even holding the correct `peerToken` — measured against a session started for the test. Would otherwise have removed a per-session process and all `settings.json` writes for the Claude half |
| 2026-09-13 | Cross-account messaging stays a reason to build this | Measured: the socket namespace is per-uid and already shared, but `ListAgents` sees only its own config folder. Reach was never the obstacle; discovery is, and Armada already enumerates every folder |
| 2026-09-12 | Context usage is read from transcripts, exact figures only, no estimated categories | `get_context_usage` gives the real breakdown but only to whoever owns the session's pipes or holds Remote Control, both out of scope; re-tokenizing attachment text by character count would put a guess in a table of measurements. **New input to the "watch, don't launch" decision above: a session Armada launched itself would yield the exact breakdown for free.** |
| 2026-09-12 | The prefix breakdown comes from a probe Armada spawns, the per-session figures stay on transcripts | The row above rests on "only to whoever owns the session's pipes", which turned out to be wrong: a headless `claude` answers `get_context_usage` too. It answers about **itself** — same project and config, empty conversation — so it supplies exactly the part a transcript cannot (system prompt, tools, memory files, skills) and none of the part a transcript already has. `ContextProbe` and `ContextCompositions` ship it, cached per project. Kept as a second row rather than a correction to the first: the first decision was right on the evidence it had, and this one only became possible once a probe existed for `get_usage`. |
| 2026-09-10 | No Claude sign-in; no credentials held | Anthropic's terms bar third-party Claude.ai login and credential handling |
| 2026-09-10 | Local, several accounts per vendor, across vendors | Multi-machine sync and multi-user weren't needed |
| 2026-09-10 | Direct messages first; board, handoff and forward-suggestions on the roadmap | — |
| 2026-09-13 | Armada starts sessions, by handing a startup script to the user's terminal | The line the scope drew was between *watching* and *running*, and the feature that was actually wanted sits on the watching side of a better line: starting a session is one launch and no ownership, where hosting one means a process per session, its pipes, and a chat UI. The two rejected routes were AppleScript, which puts an Automation consent prompt in front of a button the person just clicked, and a headless `claude` Armada owns — measured at 128MB RSS and three MCP children per idle process in `ClaudeControl`, before any UI to talk to it exists. A script also happens to be the only place the account can be set: the launching process's environment does not reach the new window (measured 2026-09-13). |
| 2026-09-10 | App plus a local Unix socket | Message folders (no socket, events survive the app closing; recommended at the time); a separate background service (two processes, too much for v1) |
| 2026-09-10 | Swift per session, Node only once | All Node by adapting mcp-a2a (about 750 MB at 16 sessions); all Swift (drops the A2A peer; no Swift A2A SDK) |
| 2026-09-10 | mcp-a2a's A2A peer kept, off by default | Dropping working, tested code that the handoff stage needs |
| 2026-09-10 | swift-mcp-kit's core used in the app; its HTTP listener not used for messaging | A shared bearer token can't identify sessions |
| 2026-09-14 | The supervisor is a Claude Code session attached to a read-only loopback MCP endpoint in the app | Does not reverse the row above: that refused the listener for *messaging*, where one shared token cannot say which session is calling. The supervisor has one identity — the person, who starts the session and holds the token — and every tool reads. Rejected: a chat pane calling a model API (a second network exception, a stored credential, and per-token cost where the session already runs on the person's plan); a chat pane on Apple's on-device model (free and private, too small to reason over transcripts); a stdio server binary (a per-session process, and a transport the kit does not have); voice in the first cut (Claude's API takes no audio, so voice is on-device speech around this same text session, and can follow). |
| 2026-09-15 | Projects: a saved list of folders, with token figures from one background ledger over every transcript, rolled up per project when shown | Starting sessions needed a place that is not an account, and per-project spend needed history no live session holds. One incremental indexer (SQLite, every file's cursor, dedupe keys and daily totals committed together) covers the past and the present from one source, and keying it by folder means adding or nesting a project needs no rescan. Rejected: recording each finished session from `.claude.json`'s `last*` figures plus a separate backfill (two sources that disagree, and a race that loses a session); a JSON ledger with a binary seen-log (the crash recovery SQLite gives for free, written by hand); dollar figures (a price table is an estimate that goes stale, where every other figure in the app is read). Measured on the first pass: 2,719 files, 3.8 GB, 11.5 s. |
| 2026-09-15 | An agent may start a session, behind the kit's write gate, in saved projects only | The supervisor could see work but not dispatch it. Kept narrow on purpose: registered with `gate: .requiresWrites` so it is neither listed nor callable until Allow writes is on; saved projects only; a fresh session, never a resume; an opening message refused if it starts with `-`, `!` or `/` and carried in a 0600 file, never the script; throttled to one launch per ten seconds; and not pre-allowed in the supervisor, so Claude Code asks the person first. Rejected: any folder (the weakest boundary for the least gain); pre-allowing it (a hostile transcript read by the supervisor could start work unseen). |
| 2026-09-15 | Voice runs a headless `claude` Armada owns, only while you talk to it | Reverses the letter of the 2026-09-10 "watches rather than runs" row and of the 2026-09-13 rejection of an owned headless `claude`, for one feature and on purpose. What made those right does not hold here: the terms worry was automated use, and each voice turn is one question a person has just spoken, with nothing looped or scheduled; the cost worry was a process per session, and this is one process for one conversation, closed after five idle minutes. It runs the user's own unmodified `claude` on their own sign-in, with `--tools ""`, only Armada's MCP server and its six read tools (`armada_start_session` denied by name), and user settings left out. Rejected: the Terminal supervisor with each question delivered by a hook (a window stays open, and hook delivery is not built); Apple's on-device model (too small to reason over transcripts, as the 2026-09-14 row found); a wake phrase (the orange microphone dot on all day, and a detector to ship and tune). Measured first: docs/claude-code-sessions.md, "Driving a headless session over stream-json". |
| 2026-09-15 | Voice recognizes speech with Parakeet v3 from FluidAudio's shared models folder, and offers a download when it is missing | Multilingual was the requirement, and Apple's recognizer takes one locale per question; Parakeet was measured against it on the person's own recordings (the Voice bullet above). Chosen with it: a named `make audit` allowance for FluidAudio's downloader, isolated in the `ArmadaSpeech` framework, rather than a trimmed fork of FluidAudio (less to maintain, a weaker claim); a download the person starts, which makes the model the second network exception; and Apple's dictation until the model is there. Rejected: reading Cadence's own copy (macOS's app-data prompt, and a dependency on another app's container); FluidAudio's streaming managers (English-only, or a separate multilingual model weaker on French); bundling the model (480 MB in every download). |
| 2026-09-15 | Voice can read replies with Kokoro-82M from FluidAudio, downloaded when asked for, with the system voice as default and fallback | Apple offers apps no better voice in macOS 26 or 27, and FluidAudio was already linked for Parakeet, so Kokoro adds no framework and no new kind of allowance. Chosen with it: the choice kept in the existing voice key behind a `kokoro:` prefix, so nothing migrates; the system voice for any sentence Kokoro is not ready for or fails on, so an answer never waits on its first compile; no offer on macOS 26.4–26.5.x, where Apple's BNNS crashes synthesis. Rejected: NVIDIA Magpie TTS (tied on quality at four times the size, five fixed voices, no mature Mac port); PocketTTS in the same package (CC-BY-4.0 weights, and streaming a short sentence does not need); a cloud voice (a third network exception, carrying every reply's text). |
| 2026-09-15 | Projects are one sidebar row under Usage, opening a list-and-detail pane, not a sidebar section | A project spans accounts, so a section of them beside the account sections read as one more kind of account, and the details it opens (live sessions, tokens by model, account and folder, the settings) want a pane's width. The pane is split the way an account's is, so the list and one project's details sit side by side. It keeps the last project selected, where an account pane keeps no selection, because it has no overview to show instead. Rejected, both tried and turned down on sight: a Projects section above the accounts; the same section below them with a divider between. |
| 2026-09-15 | A saved project is marked trusted in Claude Code's `.claude.json` when a session starts there | Every new session in a project opened on Claude Code's "Quick safety check": trust is per account, and its walk up the parents stops at the git root, so a trusted `~/Projects` does not reach a repository inside it. Saving the project is the decision the dialog asks for, and no agent can save one. Reverses, for this one field, the rule that nothing is written to a vendor's config. Kept narrow: one boolean, for saved projects only, taken under Claude Code's own `<file>.lock`, written as an edit of those bytes alone and compared with the original before it lands, because a `JSONSerialization` round trip of the real file was not lossless. Rejected: `--dangerously-skip-permissions` (drops every permission prompt, not only this one); `CLAUDE_CODE_SANDBOXED=1` (undocumented, and it turns off other workspace checks); decoding and rewriting the file (lossy, and it holds the sign-in). Codex keeps its own trust in `config.toml` and is not touched yet. |
| 2026-09-16 | Fresh Claude Code sessions can open as a tab in the project's VS Code window, behind a Settings switch | People who work in VS Code want the session where the project already is. The extension's `open` link opens a tab but goes to whichever window VS Code last focused, so it is sent only after Accessibility has raised the window titled with the project's folder and VS Code keeps it focused. The account is set only when Armada opens the window, via VS Code's bundled `code` run with the login shell's environment, since a window keeps the environment it was opened with. A window that is already open is used only when every extension host agrees on the account. An opening message is typed in, not sent. Rejected: pressing Return for the person (the keystroke goes wherever focus is at that moment); writing `claudeCode.environmentVariables` (writes the person's settings); `session=<id>` for forks (it resumes). Forks, Codex and the supervisor stay in the terminal. See [focusing-sessions.md](focusing-sessions.md#starting-a-session-in-a-projects-window). |
| 2026-09-10 | Deliver to Claude with an `asyncRewake` hook, not channels | Channels are interactive-only, a research preview, not configurable in VS Code, and their content was refused |
