#!/usr/bin/env bash
# .claude/hooks/file-guard.sh
# PreToolUse hook for file tools (Read/Edit/MultiEdit/Write/NotebookEdit/Grep).
# Owns the dotenv policy as a whitelist-of-safe: every dotenv file is blocked
# EXCEPT the placeholder templates .env.example / .env.sample / .env.template /
# .env.dist (which must contain placeholder values only — see CLAUDE.md §7).
# Permission deny globs cannot express "block .env.* except .env.example"
# (no negation), so the exception lives here instead of settings.json.
#
# Also blocks the write tools (Edit/MultiEdit/Write/NotebookEdit) on the
# baseline guard files (.claude/hooks/*, verify-commands, avn-version) so the
# agent cannot neutralize its own guard layer; reading them stays allowed.
# settings.json is intentionally NOT listed here: its Edit protection is the
# deny rule in settings.json itself (listing it here would make settings.json
# permanently uneditable from a governed session, deny rules included), and
# bash-guard rule 14 closes the shell vector.
#
# Contract: hook receives JSON on stdin; exit 0 = allow, exit 2 = block
# (stderr is shown to Claude as the reason).

set -u

block() { echo "BLOCKED by baseline policy: $1" >&2; exit 2; }

# Fail closed: without python3 the JSON parse below yields no paths and the
# guard is silently disabled.
command -v python3 >/dev/null 2>&1 || \
  block "file-guard needs python3 to inspect file paths; install python3 or open the file yourself."

LINES=$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    t = d.get("tool_name")
    if isinstance(t, str) and t:
        print("TOOL\t" + t)
    ti = d.get("tool_input", {})
    for k in ("file_path", "path", "notebook_path"):
        v = ti.get(k)
        if isinstance(v, str) and v:
            print("PATH\t" + v)
    g = ti.get("glob")
    if isinstance(g, str) and g:
        print("GLOB\t" + g)
except Exception:
    pass
')

TOOL=""
while IFS=$'\t' read -r kind val; do
  [ -n "$val" ] || continue
  case "$kind" in
    TOOL) TOOL="$val" ;;
    PATH)
      base=$(basename "$val")
      case "$base" in
        .env.example|.env.sample|.env.template|.env.dist) : ;;
        *)
          if printf '%s\n' "$base" | grep -Eq '^\.env(\..+)?$'; then
            block "dotenv files may contain secrets ($base). Only the placeholder templates .env.example / .env.sample / .env.template / .env.dist are readable/editable."
          fi
          ;;
      esac
      case "$TOOL" in
        Edit|MultiEdit|Write|NotebookEdit)
          if printf '%s\n' "$val" | grep -Eq '(^|/)\.claude/(hooks/[^/]+|verify-commands|avn-version)$'; then
            block "baseline guard files (.claude/hooks/*, verify-commands, avn-version) must not be edited by the agent. Run avn update / re-run install.sh, or edit them yourself."
          fi
          ;;
      esac
      ;;
    GLOB)
      # Grep can dump file content via its glob param. Same scrub as
      # bash-guard: remove the template names, then any remaining ".env"
      # means the glob can reach a real dotenv file — block, conservatively.
      scrubbed=$(printf '%s\n' "$val" | sed -E 's/\.env\.(example|sample|template|dist)([^A-Za-z0-9_.]|$)/\2/g')
      if printf '%s\n' "$scrubbed" | grep -Fq '.env'; then
        block "glob '$val' can match dotenv files, which may contain secrets. Only the placeholder templates .env.example / .env.sample / .env.template / .env.dist are readable."
      fi
      ;;
  esac
done <<EOF
$LINES
EOF

exit 0
