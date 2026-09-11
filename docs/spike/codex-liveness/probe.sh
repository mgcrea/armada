#!/usr/bin/env bash
# How to tell which Codex sessions are live.
#
# Codex has no session registry — no `sessions/<pid>.json`, and its processes are
# `app-server` hosts that can hold several threads, so "is a codex process alive"
# answers nothing about any one session. What it does write is
# $CODEX_HOME/thread-writer-locks/<sessionId>.lock.
#
# This runs one real Codex turn and samples the lock directory and the newest
# rollout's last event while it goes, which is how the lock's behaviour was
# established. Findings: ../../codex-sessions.md#which-sessions-are-live
#
# It spends a turn of your ChatGPT subscription. The prompt is trivial and the
# sandbox is read-only.
#
# Usage: ./probe.sh [seconds]        (default 40)

set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_BIN="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"
LOCKS="$CODEX_HOME/thread-writer-locks"
DURATION="${1:-40}"

[ -x "$CODEX_BIN" ] || {
  echo "No codex binary at $CODEX_BIN. Set CODEX_BIN." >&2
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# `ls -t` rather than `stat` or `find -printf`. Both of those differ between BSD
# and GNU, and on a Mac with Homebrew's coreutils ahead of /usr/bin you cannot tell
# which you have: `stat -f` means "format" to BSD and "file system status" to GNU,
# and the GNU one succeeds, so the fallback never runs and you get pages of block
# counts. The rollout tree is a fixed depth, so a glob does the job.
newest_rollout() {
  ls -t "$CODEX_HOME"/sessions/*/*/*/*.jsonl 2>/dev/null | head -1
}

# Locks, minus Codex's own coordination file, which is not a session.
live_locks() {
  ls -A "$LOCKS" 2>/dev/null | grep -v '^\.coordination\.lock$' | tr '\n' ' '
}

echo "codex home: $CODEX_HOME"
echo "before:     locks=[$(live_locks)]"
echo

# `< /dev/null` matters: codex exec waits on stdin without it.
(cd "$workdir" && "$CODEX_BIN" exec --skip-git-repo-check --sandbox read-only \
  "Reply with exactly: armada probe" </dev/null >"$workdir/out.log" 2>&1) &
probe=$!

start=$(date +%s)
while [ $(($(date +%s) - start)) -lt "$DURATION" ]; do
  sleep 2
  rollout="$(newest_rollout)"
  last=""
  [ -n "$rollout" ] && last="$(tail -1 "$rollout" | sed -n 's/.*"type":"\([a-z_]*\)".*/\1/p' | tail -1)"
  printf 't=%3ss  procs=[%s]  locks=[%s]  last=%s\n' \
    "$(($(date +%s) - start))" "$(pgrep -f 'codex exec' | tr '\n' ' ')" "$(live_locks)" "$last"
done

wait "$probe" 2>/dev/null || true
echo
echo "after:      locks=[$(live_locks)]"
echo
cat <<'NOTES'
What to look for
  - a <sessionId>.lock appearing with task_started and gone ~2s after task_complete
  - the lock is zero bytes: `lsof <lock>` shows the codex process holding it, and there
    is no pid inside to read

What this CANNOT tell you
  `codex exec` exits when its turn ends, so the turn's end and the process's end always
  coincide here. That leaves "does the lock span a whole session, or only a turn?"
  unanswerable from this script alone.

  Settled another way on 2026-09-11, and the method is worth repeating because it costs
  nothing: just LOOK at the directory while the ChatGPT VS Code panel has a thread open.
  Two locks were being held by one interactive codex process; the rollout for one of them
  had ended its turn with task_complete SEVEN HOURS AND TWENTY MINUTES earlier and the
  lock was still held. The lock spans the session.

    ls -A "$CODEX_HOME/thread-writer-locks"          # ids of open sessions
    lsof "$CODEX_HOME/thread-writer-locks/<id>.lock" # the process holding it
    tail -1 <that session's rollout> | jq .timestamp # how long ago its turn ended

  The second lock in that sample had NO ROLLOUT FILE AT ALL — an open session that has
  never been prompted. Anything discovering sessions by walking `sessions/` misses it
  entirely; the locks directory is the only place it exists.
NOTES
