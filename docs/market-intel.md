# Market intelligence ledger

Append-only. Standing decisions never expire; see "Reopening a decision" at the bottom.
Product decisions proper live in the table at the end of [design.md](design.md), which is
binding here too: a row's "Rejected:" clause is a standing rejection and is not repeated below.

## Standing decisions

### Accepted — Resume a closed session from the app
- **Decided:** 2026-09-21  ·  **Shipped:** unreleased, built the same day
- Recorded in design.md's 2026-09-21 "recently ended" row.

### Rejected — Send a message to a session from Armada's windows
- **Decided:** 2026-09-21
- **Gate failed:** differentiation
- **Why:** Focus already puts the person in the session's own terminal, where typing is the
  native path and needs no hook. `armada_send_message` exists for a caller with no keyboard in
  that terminal, and depends on the Deliver messages Stop hook, so it reaches a session only at
  the end of a turn.
- **Reopens if:** delivery stops depending on the hook, or a person asks for it.

### Rejected — Close all idle sessions
- **Decided:** 2026-09-21
- **Gate failed:** none run; not asked for
- **Why:** recorded in design.md's 2026-09-21 Close Session row. A person's close is
  unthrottled, so clearing rows is one click each.
- **Reopens if:** asked for.

## Run log

### 2026-09-21
- **Changed since last run:** first run; no history, so judgement here is unanchored.
  Scope was the code only, asked as "anything else useful?" after Close Session: no market
  scan was made, and Armada has no store listing, so there are no store numbers to read.
- **Verified:** `audit_release_state.py` found nothing out of sync (project 1.4.0, site 1.4.0).
  One found by reading: Close Session's caption says the conversation "can be resumed", and
  no window in Armada resumes one. Resume is reachable only through `armada_start_session`.
- **Proposed:** Resume a closed session from the app; a notification when a session starts
  waiting; show a session's quota hit in its details, beside Continue on another account.
- **Rejected:** Send a message from the UI — failed differentiation.

## Reopening a decision

Name the entry and the new verifiable fact that overrides it. "The market moved" is not one.
