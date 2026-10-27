# Plan

Work that is queued but not started. Each item says where it came from, when it bites, and
where in the code it lands. Remove an item when it ships; the CHANGELOG records it from there.

## Read Codex's compressed session logs (`.jsonl.zst`)

**Bites now.** Codex compresses a rollout in place once it has been cold for 7 days
(openai/codex PR #28338). It skips a file that still has a writer (#44138), and it unpacks one
back to `.jsonl` before appending to it. 0.164.0 (2026-10-23, #54008) fixed resume after
startup compression. It is on by default. Measured 2026-10-24 on codex-cli 0.163.0: 148 of 150
rollouts under `~/.codex/sessions` were `.jsonl.zst`, and so were all 14 in
`archived_sessions`.
Found by the feature scout (`.idea/feature-scout/2026-10-24.md`).

Armada only accepts `.jsonl`:
- `apps/apple/Armada/UsageIndexer.swift:654` (`sessions/`) and `:665` (`archived_sessions/`)
- `apps/apple/Armada/TranscriptArchive.swift:236` (`isRollout`)
- `apps/apple/Armada/CodexRollout.swift:189` (`sessionId(fromFilename:)`, the key both of the
  above use)

What goes wrong:
- A new install, or a Codex home added later, counts about the last 7 days of Codex spend only.
  The 30-day and all-time figures come out low and nothing says so.
- An existing install keeps its totals, because the gone `.jsonl` is folded into `archive`
  (`UsageIndexer.swift:433`).
- The transcript archive copies only the uncompressed rollouts. An archive that was off or
  unreachable for over a week misses everything compressed in the meantime.
- Live sessions are unaffected.

Shape of the work:
- **Archive (S):** copy `.jsonl.zst` byte for byte, and teach `isRollout` and `codexDay` the
  suffix.
- **Ledger (M):** the 27.0 SDK's Compression framework has no zstd, so link a decoder
  (libzstd as a C target).
  - Keep `make audit` green: libzstd has no network symbols, but check the allowance list.
  - Indexing a `.zst` from byte 0 must agree with the dedupe keys of the `.jsonl` it was.
- **Docs:** answer "Does anything prune `sessions/`?" in `docs/codex-sessions.md`. Codex
  compresses old logs rather than pruning them.
