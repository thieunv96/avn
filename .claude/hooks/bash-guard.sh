#!/usr/bin/env bash
# ~/.claude/hooks/bash-guard.sh
# PreToolUse hook for the Bash tool. Deterministic guard layer — unlike
# permission prefix-rules, this sees the full command string and cannot be
# bypassed by reordering flags or chaining commands.
#
# Contract: hook receives JSON on stdin; exit 0 = allow, exit 2 = block
# (stderr is shown to Claude as the reason). Keep patterns conservative:
# false positives just make Claude ask the user, which is acceptable.

set -u

CMD=$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    print("")
')

block() { echo "BLOCKED by company policy: $1" >&2; exit 2; }

# 1) Pushing to main/master (any remote, any flag order). Real protection is
#    server-side branch protection; this is the local seatbelt.
if echo "$CMD" | grep -Eq '\bgit\b.*\bpush\b.*\b(main|master)\b'; then
  block "git push to main/master. Create a branch and open a PR."
fi

# 2) Recursive force delete in any flag order (-rf, -fr, -r -f, --recursive --force)
if echo "$CMD" | grep -Eq '\brm\b(\s+-[^ ]*)*\s+(-[a-zA-Z]*r|--recursive)' && \
   echo "$CMD" | grep -Eq '\brm\b(\s+-[^ ]*)*\s+(-[a-zA-Z]*f|--force)'; then
  block "rm with recursive+force. Delete manually or ask the user."
fi

# 3) Reading secret material via shell (cat/less/head/tail/grep/base64/cp on
#    sensitive paths) — Read() deny rules do not cover Bash.
if echo "$CMD" | grep -Eq '(\.env([^a-zA-Z0-9_]|$)|\.env\.|\.pem\b|\.key\b|\.p12\b|\.pfx\b|credentials\.json|kubeconfig|\.kube/|\.ssh/|\.aws/|secrets/)'; then
  block "command touches secret/credential paths."
fi

# 4) Printing environment secrets
if echo "$CMD" | grep -Eq '\bprintenv\b|\benv\b\s*$|echo\s+.*\$[A-Z_]*(SECRET|TOKEN|KEY|PASSWORD|PASSWD)'; then
  block "printing environment variables that may contain secrets."
fi

# 5) Pipe-from-internet execution
if echo "$CMD" | grep -Eq '(curl|wget)\b.*\|\s*(ba)?sh\b'; then
  block "piping downloaded content into a shell."
fi

# 6) Destructive SQL anywhere in a command line
if echo "$CMD" | grep -Eiq '\b(drop\s+(table|database)|truncate\s+table?)\b'; then
  block "destructive SQL (DROP/TRUNCATE). Use a reviewed migration."
fi

exit 0
