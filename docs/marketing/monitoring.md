# Competitive monitoring

How the `competitive-brief-*.md` files stay current. Written 2026-10-27.

## Cadence

| When | What | Output |
| --- | --- | --- |
| **Every two weeks** (next: 2026-11-10) | The scan below: tracked repos, five vendor pages, Claude Code CHANGELOG, a Show HN and Reddit sweep | A short "since last check" section in the newest brief, or a new dated brief if a trigger fired |
| **Quarterly** (next: 2027-01) | Full brief from scratch: new profiles, positioning map, content gaps | `competitive-brief-<date>.md` |
| **At once** | Any trigger below | Update the battlecard and, if a site claim is affected, the site |

## Triggers (any one means act that day, not at the next check)

- A rival moves or continues a **conversation** across accounts, not just a login. Watch Pitboard,
  CodexBar, Codenotch, TokenEater and Claudexor. This is the one claim the hero now leans on.
- Claude Code's agent view or Claude Desktop lists **interactive CLI or VS Code sessions**, or
  spans config folders. That hits "nothing shows you all of them".
- A compare or alternatives page names Armada (Vibe Island runs three).
- A rival in this niche drops below $14.99 for a paid tier, or SessionWatcher's 2026-11-01 rise
  doesn't happen. The objection table quotes both.
- Codex or Claude Code moves where sessions live on disk.

## The scan

Tracked open-source rivals: stars, how many releases since the last check, and the newest of them.

```sh
since=2026-10-27   # date of the last check
for r in steipete/CodexBar vinzdg/codenotch datlechin/pitboard Louis-CFM/coucou \
         AThevon/TokenEater minchenlee/c9watch razzant/claudexor jazzyalex/agent-sessions \
         cordwainersmith/Claudoscope steventsvik/Tellurion josefchen/muster \
         hamed-elfayome/Claude-Usage-Tracker herdrdev/herdr mgcrea/armada; do
  printf '%s\t' "$r"
  gh api "repos/$r" --jq '.stargazers_count' | tr '\n' '\t'
  gh api "repos/$r/releases?per_page=30" \
    --jq "[.[] | select(.published_at >= \"$since\")] | \"\(length) new; \(.[0].tag_name // \"-\")\""
done
```

Then read the release notes of anything with new releases, grepping for the trigger words:

```sh
gh api "repos/<owner>/<repo>/releases?per_page=30" \
  --jq ".[] | select(.published_at >= \"$since\") | .body" \
  | grep -iE 'account|continue|fork|move|resume|transfer|waiting|permission|config_dir'
```

Pages without a repo, read by hand or WebFetch:

- https://vibeisland.app/changelog and https://vibeisland.app/alternatives/
- https://sessionwatcher.com (prices)
- https://agentcat.app
- https://crestnotch.app
- https://www.conductor.build/changelog
- https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md: search for `agent view`,
  `claude agents`, `account`, `CLAUDE_CONFIG_DIR`, `rate_limits`
- Claude Desktop release notes: whether the sessions hub lists CLI and VS Code sessions

New entrants: HN Algolia Show HN since the last check, queries `claude code`, `codex`, `agents`,
`menu bar`, `notch`, `usage limits`
(`https://hn.algolia.com/api/v1/search_by_date?tags=show_hn&query=<q>&numericFilters=created_at_i><epoch>`),
plus the top month in r/ClaudeCode and r/ClaudeAI. Use the epoch for the right year: 2026-09-01
is 1788220800, not 1756684800.

Armada's own reach, for the same entry: GitHub stars, Show HN points, and the X posts in
`docs/posts/`.

## Rules

- Record the evidence grade (P/S) and date for every fact, as the briefs do.
- A rival's claim goes in as "they say"; nothing is tested hands-on unless the entry says so.
- Don't re-propose a feature already decided in `docs/market-intel.md`; cite the entry and the new
  fact that reopens it.
