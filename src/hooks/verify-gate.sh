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
#
# Reuse (v2.12.0): a green run is remembered by the content it ran on (as git
# would commit it), so a Stop on the same content — after a commit, a staging
# change, a Q&A turn — does not run the commands again. Ignored files are not
# part of that content; delete <git dir>/avn-verify-gate.pass to force a run.

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

# ---- Content fingerprint ----
# fingerprint sets FP to "<tree id> <verify-commands blob id>": the tree git
# would write for the working tree (tracked + untracked, minus ignored), so it
# is the same before and after staging or committing that content and changes
# with any edit. It works on a copy of the index and a throw-away object
# directory — the real index and .git/objects are never written. FP stays
# empty, which means "no reuse, behave as before", whenever the answer could be
# wrong or cannot be had: a submodule/gitlink (edits inside it are invisible),
# a sparse checkout, too much to hash (size cap, 10 s limit), or any failing
# step. Clean filters still run, so Git LFS may store objects for changed files.
FP=""; FP_TMP=""
trap 'if [ -n "$FP_TMP" ]; then rm -rf "$FP_TMP"; fi' EXIT

fingerprint() {
  FP=""
  local top idx obj tree cfg max
  if [ -n "$FP_TMP" ]; then rm -rf "$FP_TMP"; FP_TMP=""; fi
  top="$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  [ "$(git -C "$top" config --bool core.sparseCheckout 2>/dev/null)" = "true" ] && return 0
  idx="$(git -C "$top" rev-parse --git-path index 2>/dev/null)" || return 0
  obj="$(git -C "$top" rev-parse --git-path objects 2>/dev/null)" || return 0
  case "$idx" in /*) ;; *) idx="$top/$idx" ;; esac      # --git-path answers relative to the cwd
  case "$obj" in /*) ;; *) obj="$top/$obj" ;; esac
  # Hashing is what a fingerprint costs: every untracked or modified file is
  # read in full at each Stop. Past the cap (32 MiB, AVN_VERIFY_FP_MAX_BYTES)
  # there is no reuse — the gate then costs what it always did, never more.
  max="${AVN_VERIFY_FP_MAX_BYTES:-33554432}"
  case "$max" in ''|*[!0-9]*) max=33554432 ;; esac
  git -C "$top" ls-files -z -o -m --exclude-standard 2>/dev/null | python3 -c '
import os, sys
top, cap, total = os.fsencode(sys.argv[1]), int(sys.argv[2]), 0
for p in sys.stdin.buffer.read().split(b"\0"):
    if p:
        try: total += os.lstat(os.path.join(top, p)).st_size
        except OSError: pass
        if total > cap: sys.exit(1)
' "$top" "$max" || return 0
  FP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-verify-fp.XXXXXX" 2>/dev/null)" || { FP_TMP=""; return 0; }
  case "$FP_TMP" in /*) ;; *) return 0 ;; esac          # GIT_INDEX_FILE must be absolute
  mkdir "$FP_TMP/objects" 2>/dev/null || return 0
  # cp -p keeps the index's mtime, which git's racy-file detection relies on
  if [ -f "$idx" ]; then cp -p "$idx" "$FP_TMP/index" 2>/dev/null || return 0; fi
  tree="$(
    export GIT_INDEX_FILE="$FP_TMP/index" GIT_OBJECT_DIRECTORY="$FP_TMP/objects" GIT_NO_LAZY_FETCH=1
    export GIT_ALTERNATE_OBJECT_DIRECTORIES="$obj${GIT_ALTERNATE_OBJECT_DIRECTORIES:+:$GIT_ALTERNATE_OBJECT_DIRECTORIES}"
    python3 -c 'import subprocess,sys
try: sys.exit(subprocess.call(sys.argv[2:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=float(sys.argv[1])))
except Exception: sys.exit(124)' 10 git -C "$top" -c core.splitIndex=false -c core.fsync=none -c core.compression=0 add -A || exit 1
    [ -z "$(git -C "$top" ls-files -s 2>/dev/null | grep "^160000 " | head -n 1)" ] || exit 1
    git -C "$top" write-tree --missing-ok 2>/dev/null
  )" || tree=""
  rm -rf "$FP_TMP"; FP_TMP=""
  case "$tree" in ''|*[!0-9a-f]*) return 0 ;; esac
  cfg="$(git -C "$top" hash-object --no-filters -- "$CFG" 2>/dev/null)" || return 0
  FP="$tree $cfg"
}

# ---- Skip when this exact content already passed ----
# The pass lives in the git dir (per repo/worktree, not per session, not in a
# shared /tmp) and holds exactly one content key.
PASS_FILE=""; KEY=""
GITDIR="$(git -C "$PROJ" rev-parse --absolute-git-dir 2>/dev/null)" || GITDIR=""
[ -n "$GITDIR" ] && PASS_FILE="$GITDIR/avn-verify-gate.pass"
if [ -n "$PASS_FILE" ]; then
  fingerprint
  if [ -n "$FP" ]; then
    KEY="v1 $FP $PROJ"
    if [ "$(cat "$PASS_FILE" 2>/dev/null)" = "$KEY" ]; then
      rm -f "$STATE"
      echo "verify-gate: working tree unchanged since the last green run — verification skipped." >&2
      exit 0
    fi
  fi
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
  # </dev/null: a command that reads stdin must not eat the rest of this file
  if ! OUT=$(cd "$PROJ" && bash -c "$line" </dev/null 2>&1); then
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

# Green. Remember it only when the commands left the content they ran on
# untouched — otherwise this run says nothing about the tree as it is now.
if [ -n "$KEY" ]; then
  FP_PRE="$FP"; fingerprint
  if [ -n "$FP" ] && [ "$FP" = "$FP_PRE" ]; then
    P_TMP="$(mktemp "$PASS_FILE.XXXXXX" 2>/dev/null)" || P_TMP=""
    if [ -n "$P_TMP" ]; then
      if printf '%s\n' "$KEY" > "$P_TMP" 2>/dev/null; then
        mv -f "$P_TMP" "$PASS_FILE" 2>/dev/null || rm -f "$P_TMP"
      else
        rm -f "$P_TMP"
      fi
    fi
  fi
fi

rm -f "$STATE"
exit 0
