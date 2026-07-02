#!/usr/bin/env bash
# .claude/hooks/verify-gate.sh
# Stop hook: blocks Claude from ending its turn while the project's verify
# commands fail. Dormant by default — it exits 0 immediately unless the repo
# opts in by creating .claude/verify-commands (one command per line, # = comment;
# start from .claude/verify-commands.example).
#
# Contract: hook receives the Stop-event JSON on stdin; exit 0 = allow stop,
# exit 2 = block (stderr goes back to Claude). Safety: gives up after 3
# consecutive blocks in a session (below the platform's own 8-block failsafe)
# and never blocks read-only turns (clean working tree) or non-git dirs.

set -u

PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJ/.claude/verify-commands"
[ -f "$CFG" ] || exit 0

# Without python3 we cannot read the event JSON — allow the stop. Unlike
# bash-guard, a Stop gate must fail open: it may never brick the session.
command -v python3 >/dev/null 2>&1 || exit 0

# Sanitize the session id before using it in a path: keep [A-Za-z0-9._-] only.
SESSION_ID=$(python3 -c '
import json,re,sys
try:
    d = json.load(sys.stdin)
    print(re.sub(r"[^A-Za-z0-9._-]", "_", str(d.get("session_id", "unknown")))[:64])
except Exception:
    print("unknown")
')
STATE="${TMPDIR:-/tmp}/claude-verify-gate-${SESSION_ID}"

# Only gate turns that changed something in a git repo.
if ! git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi
if [ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]; then
  rm -f "$STATE"; exit 0
fi

COUNT=$(cat "$STATE" 2>/dev/null || echo 0)
case "$COUNT" in ''|*[!0-9]*) COUNT=0;; esac
if [ "$COUNT" -ge 3 ]; then
  rm -f "$STATE"
  echo "verify-gate: giving up after 3 blocks — report the remaining failures honestly (CLAUDE.md §10)." >&2
  exit 0
fi

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  if ! OUT=$(cd "$PROJ" && bash -c "$line" 2>&1); then
    # If the escape-hatch counter cannot be persisted, allow the stop — an
    # unwritable state path must never turn into an unbounded block.
    echo $((COUNT + 1)) > "$STATE" 2>/dev/null || exit 0
    {
      echo "verify-gate: verification command failed: $line"
      echo "$OUT" | tail -n 30
      echo "Fix the failure (never delete/skip/weaken tests — CLAUDE.md §2), then finish."
    } >&2
    exit 2
  fi
done < "$CFG"

rm -f "$STATE"
exit 0
