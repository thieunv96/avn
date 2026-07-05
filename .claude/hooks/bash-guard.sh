#!/usr/bin/env bash
# .claude/hooks/bash-guard.sh
# PreToolUse hook for the Bash tool. Deterministic guard layer — unlike
# permission prefix-rules, this sees the full command string and cannot be
# bypassed by reordering flags or chaining commands. A block here fires
# BEFORE permission rules are evaluated and wins over any allow rule; it
# cannot be approved through — a blocked command must be run by the user.
#
# Contract: hook receives JSON on stdin; exit 0 = allow, exit 2 = block
# (stderr is shown to Claude as the reason). Keep patterns conservative:
# false positives just make Claude ask the user, which is acceptable.

set -u

block() { echo "BLOCKED by company policy: $1" >&2; exit 2; }

# Fail closed: without python3 the JSON parse below yields an empty command
# and every guard is silently disabled.
command -v python3 >/dev/null 2>&1 || \
  block "bash-guard needs python3 to inspect commands; install python3 or run this command yourself."

CMD=$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    print("")
')

# 1) Pushing to main/master (any remote, any flag order). The ref must stand
#    alone (space/colon-delimited) so branches like feat/main-page pass.
#    Real protection is server-side branch protection; this is the local seatbelt.
if echo "$CMD" | grep -Eq '\bgit\b.*\bpush\b.*(\s|:)(main|master)(\s|$)'; then
  block "git push to main/master. Create a branch and open a PR."
fi

# 2) Recursive force delete in any flag order (-rf, -fr, -r -f, --recursive --force)
if echo "$CMD" | grep -Eq '\brm\b(\s+-[^ ]*)*\s+(-[a-zA-Z]*r|--recursive)' && \
   echo "$CMD" | grep -Eq '\brm\b(\s+-[^ ]*)*\s+(-[a-zA-Z]*f|--force)'; then
  block "rm with recursive+force. Delete manually or ask the user."
fi

# 3) Reading secret material via shell (cat/less/head/tail/grep/base64/cp on
#    sensitive paths) — Read() deny rules do not cover Bash. Placeholder
#    templates (.env.example/sample/template/dist) are scrubbed out first; the
#    boundary class excludes "." and word chars so .env.example.bak stays
#    blocked, and \2 re-inserts the boundary so adjacent tokens survive
#    (`cat .env .env.example` still matches on the remaining `.env`).
SCRUBBED=$(printf '%s\n' "$CMD" | sed -E 's/\.env\.(example|sample|template|dist)([^A-Za-z0-9_.]|$)/\2/g')
if echo "$SCRUBBED" | grep -Eq '(\.env([^a-zA-Z0-9_]|$)|\.env\.|\.pem\b|\.key\b|\.p12\b|\.pfx\b|credentials\.json|kubeconfig|\.kube/|\.ssh/|\.aws/|secrets/)'; then
  block "command touches secret/credential paths."
fi

# 4) Printing environment secrets — covers $VAR and ${var} in any case
if echo "$CMD" | grep -Eiq '\bprintenv\b|\benv\b\s*$|echo\s+.*\$\{?[a-zA-Z_]*(secret|token|key|password|passwd)'; then
  block "printing environment variables that may contain secrets."
fi

# 5) Pipe-from-internet execution
if echo "$CMD" | grep -Eq '(curl|wget)\b.*\|\s*(ba)?sh\b'; then
  block "piping downloaded content into a shell."
fi

# 6) Destructive SQL anywhere in a command line. TABLE keyword is optional in
#    real SQL (TRUNCATE users); the name must start with a letter so coreutils
#    `truncate -s 0 file` passes.
if echo "$CMD" | grep -Eiq '\b(drop\s+(table|database|schema)|truncate\s+(table\s+)?[a-zA-Z_"`])'; then
  block "destructive SQL (DROP/TRUNCATE). Use a reviewed migration."
fi

# 7) SQL DELETE/UPDATE without a WHERE clause — mass data change. Line-level
#    check: a WHERE anywhere in the command clears it, so a bare DELETE inside
#    a multi-statement string can slip through — this is a seatbelt, not a parser.
if echo "$CMD" | grep -Eiq '\bdelete\s+from\s' && ! echo "$CMD" | grep -Eiq '\bwhere\b'; then
  block "SQL DELETE without WHERE. Add a WHERE clause, or ask the user to run it."
fi
if echo "$CMD" | grep -Eiq '\bupdate\s+\S+\s+set\s' && ! echo "$CMD" | grep -Eiq '\bwhere\b'; then
  block "SQL UPDATE without WHERE. Add a WHERE clause, or ask the user to run it."
fi

# 8) Redis keyspace wipe (also catches piped forms like `echo flushall | redis-cli`)
if echo "$CMD" | grep -Eiq '\bflush(all|db)\b'; then
  block "redis FLUSHALL/FLUSHDB wipes the keyspace."
fi

# 9) Mongo drops — requires the mongo-shell shape, so pandas df.drop(...) passes
if echo "$CMD" | grep -Eq '\bdropDatabase\b|\bdb\.[a-zA-Z_][a-zA-Z0-9_]*\.drop\s*\('; then
  block "mongo dropDatabase()/collection.drop() destroys data."
fi

# 10) Docker volume destruction — (\s+\S+)* tolerates flags between the binary
#     and the subcommand (e.g. docker --context prod volume rm)
if echo "$CMD" | grep -Eq '\bdocker(\s+\S+)*\s+volume\s+(rm|prune)\b'; then
  block "docker volume rm/prune destroys data volumes."
fi
if echo "$CMD" | grep -Eq '\bdocker(\s+\S+)*\s+system\s+prune\b.*--volumes'; then
  block "docker system prune --volumes destroys data volumes."
fi

# 11) kubectl broad-scope deletes (targeted deletes still go through the ask rule)
if echo "$CMD" | grep -Eq '\bkubectl(\s+\S+)*\s+delete\s+(namespace|ns)\b'; then
  block "kubectl delete namespace."
fi
if echo "$CMD" | grep -Eq '\bkubectl(\s+\S+)*\s+delete\b' && \
   echo "$CMD" | grep -Eq -- '--all(-namespaces)?\b|(^|\s)-A\b'; then
  block "kubectl delete with broad scope (--all / -A)."
fi

# 12) git clean with force deletes untracked files (the user's work).
#     Preview with `git clean -n` stays allowed.
if echo "$CMD" | grep -Eq '\bgit(\s+-[^ ]+|\s+-C\s+\S+)*\s+clean\b' && \
   echo "$CMD" | grep -Eq '(^|\s)-[a-zA-Z]*f[a-zA-Z]*\b|--force\b'; then
  block "git clean -f deletes untracked files. Preview with git clean -n and ask the user."
fi

# 13) Discarding the whole working tree — checkout/restore of "." wipes
#     uncommitted changes (also `checkout <ref> -- .`, `restore -W .`,
#     `restore --source=<ref> .`). Targeted branch/file checkout still passes,
#     and `git restore --staged .` (unstage only, non-destructive) passes.
if echo "$CMD" | grep -Eq '\bgit\s+checkout\s+((\S+\s+)?--\s+)?\.([/[:space:]]|$)' || \
   echo "$CMD" | grep -Eq '\bgit\s+restore\s+(\.([/[:space:]]|$)|--worktree\b|-W\b)' || \
   echo "$CMD" | grep -Eq '\bgit\s+restore\s+--source=\S+\s+\.([/[:space:]]|$)'; then
  block "git checkout/restore of the whole tree discards uncommitted changes. Ask the user."
fi

exit 0
