# Skill usage — design

Approved 2026-11-03. v1 of "count skill usage in Armada": count every Agent Skill and custom
command use per account, project and day, from the transcripts `UsageIndexer` already reads, and
store enough per use that the later steps (should-have-triggered, corrections, unused skills, an
improvement run) need no second full pass.

## What the transcripts show

Survey of every transcript on the Mac on 2026-11-03 (5,277 files, 9.5 GB, two accounts,
2026-09-02 → today, subagents included, deduped):

| Skill | Total | Auto | Slash |
|---|---:|---:|---:|
| project-mail-archive | 304 | 7 | 297 |
| superpowers:brainstorming | 237 | 236 | 1 |
| code-health | 122 | 17 | 105 |
| reply-as-olivier | 81 | 80 | 1 |
| push-testflight-build | 95 | 22 | 73 |

- **Auto:** an `assistant` entry whose `message.content[]` holds a `tool_use` with
  `name == "Skill"`. The skill is `input.skill` (may carry a plugin prefix), args `input.args`.
  Dedupe on the `tool_use` id.
- **Slash:** a `user` entry whose `message.content` is a string whose **first tag**, after any
  whitespace, is `<command-message>` or `<command-name>`. 1,619 lines open with
  `<command-message>`; 274 open with `<command-name>` (`/compact` 252, `/model` 10, and `/commit`
  9 and `/commit-task` 3 from an older Claude Code). 5 lines carry `<command-name>` mid-text —
  workflow-harness relays quoting a request — and are not uses. The name is
  `<command-name>/(…)</command-name>`, the args `<command-args>`. Dedupe on the entry `uuid`.
- The `type` filter drops `api-request-blob`, `api-request-shape`, `attachment` and `tools-used`,
  which repeat the same text.
- The two forms are disjoint: typing `/name` writes no `Skill` tool_use.

## Storage

Ledger schema 2, migrated in place from 1 (`ALTER TABLE files ADD COLUMN skill_offset INTEGER
NOT NULL DEFAULT 0`, `ADD COLUMN skill_state TEXT`). A build older than this one moves a v2
ledger aside, which is the existing rule.

```sql
CREATE TABLE skill_uses(
  use_id TEXT PRIMARY KEY,      -- "a:" + tool_use id, or "s:" + entry uuid
  slot INTEGER,                 -- the file holding it; NULL once that file is gone
  day INTEGER NOT NULL, cwd TEXT NOT NULL, account TEXT NOT NULL, vendor INTEGER NOT NULL,
  skill TEXT NOT NULL, kind INTEGER NOT NULL,   -- 0 auto, 1 slash
  session_id TEXT NOT NULL, at REAL NOT NULL, entry_uuid TEXT NOT NULL,
  args TEXT, reply TEXT) WITHOUT ROWID;
```

One row per use; counts are a `GROUP BY` of (day, folder, account, vendor, skill, kind). A gone
file sets `slot = NULL` and the row stays. A rewrite re-owns rows to the new slot.

**Decided 2026-11-03:** each use keeps `args` and `reply`, the next human message after it in the
same main transcript, each at most 500 characters. Subagent uses get no reply.

## Backfill

A second cursor per file (`skill_offset`). The read starts at `min(offset, skill_offset)`; lines
before `offset` go only to the skill parser, so tokens cannot count twice. Equal cursors cost one
read. A `skill_parser` version in `meta` resets `skill_offset` and deletes rows that still have a
slot, re-extracting from files on disk without touching tokens. `index.complete` for skills is
`first_pass_done && skills_pass_done`.

History only the `archive` table holds has no skills. **Decided 2026-11-03:** v1 also reads the
transcript archive folder (Settings › Archive) for skills only, when it is mounted, which recovers
2026-08-05 → 2026-09-01. Uses are keyed by their own ids, so a copy cannot count twice.

## Skill or built-in

At snapshot time, never stored: a name with `:` is a plugin; a name with any auto use is a skill;
otherwise `<config>/skills/<name>/SKILL.md`, `<config>/commands/<name>.md`, or
`.claude/skills/<name>/SKILL.md` / `.claude/commands/<name>.md` in the use's folder or a parent up
to `~`; otherwise a built-in. `source` is `skill`, `command`, `plugin` or `builtin`.

## `armada_get_skill_usage` (read-only)

Inputs: `project`, `account`, `window` (`7d`, `30d`, `all`; default `30d`), `includeBuiltins`
(default false). Output: per skill `name`, `source`, `total`, `auto`, `slash`, `lastUsed`; plus
`builtinsHidden`, `index` {complete, filesRead, filesTotal, since}, and a note that Codex is not
counted.

## UI

A **Skills** section in `ProjectUsageSection` after Folders: the top 10 in the shared window,
built-ins left out, each with its total and how many were typed. Hidden when empty.

## Codex

Left out: a rollout lists skills in `<skills_instructions>` / `host_skills`, and using one is the
model reading `SKILL.md` through a shell call, with no distinct record.

## Later steps (not v1)

Should-have-triggered reads the auto/slash split; unused reads `lastUsed` and the disk scan;
corrections read `reply`; the improvement run puts one skill's rows into a prompt through
`NewSessionLauncher`, started only by the person's button press.
