# Skills pane

Approved in conversation on 2026-11-03, after skill usage counting shipped
(`2026-11-03-skill-usage-design.md`).

## Why

The ledger already counts every skill use, and `armada_get_skill_usage` answers across every
project. In the app, the only place to see it is each project's top ten, so "which skills do I
use most" means visiting every project and adding the numbers up. The later steps (unused
skills, should-have-triggered, corrections, the improvement-run button) are all about one
skill, so they need a page of their own. The Usage pane is about account limits, not the
ledger, so they don't belong there.

## What

**Sidebar.** A **Skills** row in Overview, after Projects, with no badge. It's listed only
while the ledger holds a skill use, the way Schedules is listed only when there is something
to schedule.

**Pane.** The same list-and-detail split as Projects.

- **Left:** every skill, custom command and plugin skill used in the chosen window, most used
  first. Built-ins (`SkillSource.builtin`) are left out, as in the project pane. Each row shows
  the name, an icon for skill, command or plugin, the total, and "(n typed)".
- **Window picker:** the same `StatsWindow` stored under `StatsWindow.defaultsKey` that
  Projects uses, so both panes show the same window.
- **Footer:** the project pane's skills footer, including its "Still reading older
  transcripts…" line while the skills pass isn't done.
- **Right, for the selected skill:**
  - **Totals:** total, auto, typed, last used.
  - **By project:** each saved project's count, and one row for "Outside saved projects".
    Clicking a project opens it in the Projects pane.
  - **By account:** shown only when more than one account used the skill.
  - **Recent uses:** the last 20 in the window, newest first. Each shows when, which project
    (or the folder, outside every project), auto or typed, the args, and the start of the next
    thing the person typed.

**Project pane.** It keeps its top ten. Clicking a skill there opens it in the Skills pane.

## How

- The totals and splits come from `UsageIndex.projectSkills(store:)`'s `[SkillTally]`, rolled
  up by pure functions in `SkillStats.swift`.
- Recent uses are a read-only query against the ledger file, on a connection of its own. WAL
  means it never waits for a pass, even the first, which runs for minutes on the indexer actor.
  A ledger that doesn't exist yet gives no rows, and the query never creates the file.
- The MCP tool doesn't change.

## Not in this step

- Listing installed skills that were never used.
- The improvement-run button.
- Should-have-triggered and corrections.
