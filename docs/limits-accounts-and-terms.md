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

**Still not checked, and now load-bearing: OpenAI's terms for Codex on a ChatGPT
subscription.** It was a footnote while Codex was unbuilt. As of 2026-09-11 the app reads
`~/.codex` and displays a ChatGPT plan's usage, so this is the same question the whole
Anthropic section above answers for Claude, asked of the other vendor and unanswered.

Two things that should make it easier than the Claude case, both measured: Armada reads
only session logs and an empty lock file, and it **never opens `auth.json`** — the plan name
arrives inside the rate limits as `plan_type`, so no credential file is touched at all. The
same "watches agents rather than running them, holds no credentials" argument applies.

### How to read subscription limits without holding a credential

- `claude setup-token` makes a one-year OAuth token for Claude Code itself to use (CI,
  scripts).
- `ant auth login` OAuth profiles and the Admin API cover Console API organizations. The
  Admin API has rate-limit reports for those, but not the Pro and Max 5-hour and 7-day
  windows.

**Settled 2026-09-12. Ask the user's own `claude`, over the SDK control protocol.**
This is what the VS Code extension does, and it is why the extension is accurate while a
file reader is not — see source 1 below. It needs no credential, costs no tokens, and is
the path the legal page treats as normal: the unmodified program, the user's own sign-in,
run headless. Armada spawns it, asks one question, and reads the answer.

Three alternatives were weighed first and all three declined. Recorded so they are not
re-argued:

- **Read the OAuth token from the Keychain** (`Claude Code-credentials` is there) and call
  the usage endpoint directly. Exact and current, and the one thing the Consumer Terms name
  outright — developers may not "collect, store, or intermediate Claude.ai credentials or
  session tokens". It also contradicts the sentence this document ends on.
- **Force a cache refresh by running `claude -p`.** Spends the user's quota to measure the
  user's quota, and is exactly the "automated or non-human means" the terms carve out. The
  control request below is not this: it runs no prompt and bills nothing.
- **Install a `statusLine` shim** that dumps the documented `rate_limits` block to a file.
  The data is real, but it runs only under the terminal UI (see source 2) and would mean
  Armada writing to the user's `settings.json`, which `docs/design.md` puts out of scope.

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

**Codex, measured 2026-09-11:** one home at `~/.codex`, `plan_type: "plus"`, 418 rollouts
over six months. No second home, and no way to look for one — see the asymmetry note in
[design.md](design.md#3-dashboard-data-to-write). Unlike Claude, there is no per-organization
split to worry about: one home, one plan, one pair of windows.

**Corrected 2026-09-11:** there is a second config folder after all —
`CLAUDE_CONFIG_DIR=~/.claude-skitrust`, with 5 live sessions of its own against the default
folder's 19. It is easy to miss, because a tool inheriting that environment (`claude agents
--json`) and a GUI app reading `~/.claude` disagree completely while both are right: the two
folders hold **disjoint** session sets. Worth remembering when cross-checking anything that
counts sessions.

### A config folder is an organization, not an account

The two folders on this Mac are the **same Anthropic account** — identical `accountUuid`
(`fc70ad20-…`), identical `emailAddress`, identical `fullName`. What differs is the
organization, and with it everything that matters:

| `oauthAccount` field | `~/.claude` | `~/.claude-skitrust` |
| --- | --- | --- |
| `organizationName` | `<email>'s Organization` | `Skitrust` |
| `organizationType` | `claude_max` | `claude_team` |
| `organizationRateLimitTier` | `default_claude_max_20x` | `default_raven` |
| `organizationUuid` | `086bea66-…` | `952d0683-…` |
| `seatTier` | absent | `team_tier_1` |
| live sessions | 19 | 5 |
| 5-hour / 7-day | 17% / 69% | 26% / 11% |

Consequences for anything displaying this:

- **Label by organization.** The email is identical on both, so a per-account UI keyed on it
  shows the same string twice and reads as a duplicate row.
- **Never total two folders' usage.** They are separate rate limits against separate orgs;
  a sum is the wrong number twice.
- **`<email>'s Organization` is generated**, not chosen. Armada rewrites exactly that shape
  to "Personal" and leaves any other name alone.
- **The plan lives in the tier, not the type.** Both orgs are "Max"-ish by
  `organizationType`; only `organizationRateLimitTier` separates Max 20x from the Team seat.
- `oauthAccount` sits at the **top level** of `.claude.json`, beside
  `cachedUsageUtilization` — one parse gets both.

Unverified: whether an org switch inside a running Claude Code rewrites `oauthAccount` in
place. Armada re-reads it on every usage refresh rather than caching it at launch, on the
assumption that it can.

## Where plan-limit data is

### Claude Code

Four sources, in the order Armada now prefers them.

1. **The `get_usage` control request (undocumented, and the live one).** Read out of the
   VS Code extension's `extension.js` 2.1.268 on 2026-09-12; `get_usage`,
   `rate_limit_event` and `unifiedWindows` are all in the CLI binary too.

   **The extension never reads `cachedUsageUtilization`.** It drives `claude` in
   stream-json mode and takes usage off that channel two ways:

   - **Pushed.** The CLI emits `{"type":"rate_limit_event","rate_limit_info":{...}}` with
     `unifiedWindows` whenever an API response carries new limits; the extension relays it
     to its webview as `panel_usage_update`. Live by construction — the response that
     spends the quota reports the new figure. Only its parent process can take this.
   - **Pulled.** A `get_usage` control request, which the webview triggers with
     `request_usage_update`. The SDK wrapper is named, in full,
     `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` — take the hint.

   The pull works standalone, which is what Armada uses:

   ```console
   $ echo '{"type":"control_request","request_id":"r1","request":{"subtype":"get_usage"}}' \
       | claude --input-format stream-json --output-format stream-json --verbose
   ```

   Measured against both folders on 2026-09-12:

   - **Free.** `total_cost_usd: 0`, `total_api_duration_ms: 0`. A control request is not a
     prompt. No session registry file and no transcript are written, so the spawned process
     does not show up in Armada's own session list.
   - **~1.2s warm**, and one process per config folder. Too expensive for the 30s file
     poll; fine on a 3-minute timer and when the popover opens.
   - **Same shape as the cache.** The `rate_limits` object it answers with has the same
     `five_hour` / `seven_day` / `limits[]` as `cachedUsageUtilization.utilization`, so one
     decoder serves both — see `UsageSnapshot.decode(windows:fetchedAt:source:)`.
   - **`CLAUDE_CONFIG_DIR` selects the account, and must be *unset* for `~/.claude`.**
     Setting it to the default folder's own path makes Claude Code look for
     `~/.claude/.claude.json`, which does not exist, and the probe comes back
     `subscription_type: null, rate_limits_available: false` as if signed out. The same
     asymmetry as the usage file itself. It fails safely — Armada falls back to the cache —
     but it fails silently, so `ClaudeConfigFolder.isDefault` exists to get it right.
   - It also returns a `behaviors` block — request and session counts, and which skills,
     agents and MCP servers the person uses. Armada reads none of it.

2. **Status-line JSON (documented).** The command configured as `statusLine` receives
   `rate_limits.five_hour.used_percentage` and `.resets_at`, the same for `seven_day`, and
   `spend_limit` behind a Claude apps gateway. Pro and Max only, only after the first API
   response in a session, and each window may be missing. **It very likely never runs in the
   VS Code extension:** the extension drives the CLI in stream-json mode with no terminal
   UI, and `statusLine` appears in its code only in the settings schema.
3. **`cachedUsageUtilization` in `~/.claude.json` (undocumented).** Armada's fallback,
   for a Mac where `claude` cannot be found and for the identity, which source 1 does not
   carry. A cached copy with
   `fetchedAtMs`. Windows seen: `five_hour`, `seven_day`, `seven_day_opus`,
   `seven_day_sonnet`, `seven_day_oauth_apps`, `seven_day_cowork`, `extra_usage`, `spend`,
   `limits`, and several code names. Each has `utilization` (percent) and `resets_at`.

   Three things measured while building against it, each silent when got wrong:

   - **`resets_at` needs `.withFractionalSeconds`.** The real value is
     `"2026-09-10T23:00:00.431496+00:00"` — six fractional digits and a numeric offset — and
     a bare `ISO8601DateFormatter()` returns **nil** on it. Compiled and run against the live
     string to confirm; `JSONDecoder`'s `.iso8601` strategy does parse it. The failure mode
     is not an error: the percentage still renders and the reset time just never appears.
   - **It is a cache, and it goes stale on a *busy* account, not only an idle one.**
     Measured on 2026-09-11 at 14:10, with sessions running in both config folders:

     | | `~/.claude` | `~/.claude-skitrust` |
     | --- | --- | --- |
     | file mtime | 14:04 | 14:10 |
     | `cachedUsageUtilization.fetchedAtMs` | 10:34 (97 min old) | 10:36 (95 min old) |
     | `five_hour` | 0%, no `resets_at` | 99%, `resets_at` 13:00 — 69 min in the past |

     So the file is rewritten every few minutes for other reasons while the usage block
     inside it sits untouched for an hour and a half. **Whatever refreshes it is not "an
     API response happening to update it"** — both folders were talking to the API
     throughout. Extension and SDK sessions appear not to write it at all; the two
     timestamps landing two minutes apart suggests something periodic or startup-driven.

     Two consequences for anything reading it. Re-reading the file more often buys
     nothing — Armada polls every 30s *and* watches with FSEvents, and neither can make
     the writer write. And a window whose `resets_at` has passed is not "99% used, reset
     an hour ago": it is a figure for a window that no longer exists, and the only honest
     rendering is to void it and say so. Show the age beside every figure, or it reads as
     the current one.
   - **Decode narrowly.** The object also carries `limit_dollars`, `used_dollars`,
     `remaining_dollars`, `locked_reason`, a `limits` array, `extra_usage`, `spend` and a
     dozen code-named windows. Reading only the two windows you want means an unrelated key
     changing shape cannot break you.
4. **`quotaLimits` in a session transcript (undocumented).** The one rate-limit fact on
   this Mac that is not a cache: written by the process it happened to, at the moment a
   request was actually refused. As seen on 2026-09-11 in
   `~/.claude-skitrust/projects/…/c8c404ba-….jsonl`:

   ```json
   {"type":"assistant","timestamp":"2026-09-11T10:44:34.121Z", …,
    "message":{…,"content":[{"type":"text",
      "text":"You've hit your session limit · resets 1pm (Europe/Paris)"}]},
    "quotaLimits":{"status":"rejected","resetsAt":1789124400,
      "unifiedRateLimitFallbackAvailable":false,"rateLimitType":"five_hour",
      "overageStatus":"rejected","overageDisabledReason":"org_level_disabled",
      "isUsingOverage":false},
    "error":"rate_limit","isApiErrorMessage":true}
   ```

   - **Rejection-only.** One occurrence in a 657-message transcript, and none at all in a
     session that never hit a wall. It cannot say you are at 60%; it can say you are at the
     end, which is the reading the cache is least able to give.
   - **`resetsAt` is epoch *seconds*** — against milliseconds in `fetchedAtMs` two files
     over. Reading one as the other puts the reset in 1970 or in the year 58000, silently.
   - **`rateLimitType`** uses the cache's own vocabulary: `five_hour`, `seven_day`.
   - Worth reading only while the named window is still open. Here the refusal was at 10:44
     for a window that ended at 13:00, and by 14:10 it said nothing about the allowance in
     hand. It also sits megabytes from the end of a session that carried on afterwards, so a
     64KB tail read finds it only while it is fresh — which is the only time it is useful.
5. `~/.claude/stats-cache.json`: daily activity, token usage per model, session counts.

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
