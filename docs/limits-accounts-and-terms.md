# Limits, accounts and terms

Checked 2026-09-10. The terms section is a reading of Anthropic's published documents, not
legal advice.

## What Anthropic's terms allow

Sources: Claude Code's [legal and compliance
page](https://code.claude.com/docs/en/legal-and-compliance), the Agent SDK overview, the
headless docs, and the [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
(effective 2025-10-08).

**Allowed:** a user signing in to the **unmodified** `claude` program with their own
subscription, through Anthropic's own sign-in flow, and running it headless. The headless
docs treat subscription login as the normal path; only `--bare` requires an API key.

**Limited to ordinary use:** "Advertised usage limits for Pro and Max plans assume
ordinary, individual usage of Claude Code and the Agent SDK." No threshold is given. The
Consumer Terms also bar access "through automated or non-human means, whether through a bot,
script, or otherwise", except through an API key "or where we otherwise explicitly permit
it".

**Not allowed for third-party apps:**

- "Anthropic does not permit third-party developers to offer Claude.ai login into their own
  applications, or to route requests through Free, Pro, or Max plan credentials on behalf of
  their users."
- "Developers may not collect, store, or intermediate Claude.ai credentials or session
  tokens — sign-in to a Claude account must complete through Anthropic's own flow."
- The Agent SDK overview says the same, "unless previously approved".

**Shipping Claude Code inside a product** requires the Commercial Terms. The program must be
unmodified with its sign-in methods intact, and the product may not pay for, resell or sit
in the middle of its users' usage: each user signs in with their own key, subscription or
cloud-provider credential. **Whether a local app that runs the user's own installed `claude`
counts as "running Claude Code in your products" isn't stated.** Get written confirmation
before distributing anything that runs agents to clients.

**Other points:**

- Sharing an account is barred ("make your Account available to anyone else"). Rotating
  between several subscriptions to get past limits sits badly with that and with "ordinary,
  individual usage". Claudexor ships that feature.
- Product names can't include "Claude Code" or "Anthropic".
- Anthropic "reserves the right to take measures to enforce these restrictions and may do so
  without prior notice."
- **API keys remove the ambiguity** for automated use.

**How this shaped Armada:** it watches agents rather than running them, and holds no Claude
credentials.

Not checked: OpenAI's terms for Codex on a ChatGPT subscription.

### No official way for a third-party app to read subscription limits

- `claude setup-token` makes a one-year OAuth token for Claude Code itself to use (CI,
  scripts).
- `ant auth login` OAuth profiles and the Admin API cover Console API organizations. The
  Admin API has rate-limit reports for those, but not the Pro and Max 5-hour and 7-day
  windows.

## Multiple accounts on one Mac

**Claude Code:** `CLAUDE_CONFIG_DIR` (default `~/.claude`). The env-vars docs: "Useful for
running multiple accounts side by side: for example, `alias
claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'`." Settings, session history and
plugins move under it. It's ignored if set in project or local settings files.

- The VS Code extension reads `CLAUDE_CONFIG_DIR`, and moves its IDE lock files to
  `$CLAUDE_CONFIG_DIR/ide/`.
- The extension's `claudeCode.environmentVariables` setting should be able to set it per VS
  Code workspace. Unverified.
- **Settled 2026-09-11: the usage cache follows the config folder, asymmetrically.** The
  default folder keeps it *outside* — `~/.claude` pairs with `~/.claude.json` — while a
  custom one keeps it *inside*: `CLAUDE_CONFIG_DIR=~/.claude-skitrust` pairs with
  `~/.claude-skitrust/.claude.json`, and no `~/.claude-skitrust.json` exists. Measured
  against a real second account on this Mac, which also carries its own separate
  `cachedUsageUtilization` (4% / 8% against the default account's 17% / 69%). So a rule
  derived from the folder path alone gets one of the two cases wrong; Armada's
  `ClaudeConfigFolder` stores the two paths rather than computing the second.

**Codex:** `CODEX_HOME`. See [codex-sessions.md](codex-sessions.md#multiple-accounts).

**This Mac on 2026-09-10:** one Claude account (Max, `organizationType: claude_max`) and one
Codex account, with no second config folder.

**Corrected 2026-09-11:** there is a second config folder after all —
`CLAUDE_CONFIG_DIR=~/.claude-skitrust`, with 5 live sessions of its own against the default
folder's 19. It is easy to miss, because a tool inheriting that environment (`claude agents
--json`) and a GUI app reading `~/.claude` disagree completely while both are right: the two
folders hold **disjoint** session sets. Worth remembering when cross-checking anything that
counts sessions.

## Where plan-limit data is

### Claude Code

1. **Status-line JSON (documented).** The command configured as `statusLine` receives
   `rate_limits.five_hour.used_percentage` and `.resets_at`, the same for `seven_day`, and
   `spend_limit` behind a Claude apps gateway. Pro and Max only, only after the first API
   response in a session, and each window may be missing. **It very likely never runs in the
   VS Code extension:** the extension drives the CLI in stream-json mode with no terminal
   UI, and `statusLine` appears in its code only in the settings schema.
2. **`cachedUsageUtilization` in `~/.claude.json` (undocumented).** A cached copy with
   `fetchedAtMs`. Windows seen: `five_hour`, `seven_day`, `seven_day_opus`,
   `seven_day_sonnet`, `seven_day_oauth_apps`, `seven_day_cowork`, `extra_usage`, `spend`,
   `limits`, and several code names. Each has `utilization` (percent) and `resets_at`.
3. `~/.claude/stats-cache.json`: daily activity, token usage per model, session counts.

### Codex

Every `token_count` event in a session log carries `rate_limits.primary` (300 minutes) and
`secondary` (10,080 minutes), each with `used_percent` and `resets_at`. See
[codex-sessions.md](codex-sessions.md#limits).

## OpenTelemetry (for the research roadmap)

Claude Code exports OpenTelemetry when `CLAUDE_CODE_ENABLE_TELEMETRY=1` and the `OTEL_*`
exporter variables are set, including through a settings file's `env` block, which the
extension shares. Armada could run a local receiver.

- **Metrics:** `claude_code.session.count`, `token.usage`, `cost.usage`,
  `active_time.total`, `lines_of_code.count`, `commit.count`, `pull_request.count`,
  `code_edit_tool.decision`.
- **Events** include `user_prompt`, `api_request`, `api_error`, `api_refusal`,
  `tool_result`, `tool_decision`, `compaction`, `subagent_completed`,
  `hook_execution_start` and `hook_execution_complete`, `permission_mode_changed`.
- Also named in the docs, type not established: `claude_code.tool.blocked_on_user`,
  `claude_code.tool.execution`, `claude_code.interaction`, `claude_code.llm_request`.
- **Attributes on every record:** `session.id`, `prompt.id` (links a prompt to its API calls
  and tools), `terminal.type` (`vscode`), and `user.account_uuid` and `organization.id` when
  signed in with a Claude account. So each record says which account it came from.
- **No rate-limit data.**
