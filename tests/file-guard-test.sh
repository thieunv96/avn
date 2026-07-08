#!/usr/bin/env bash
# Self-test for .claude/hooks/file-guard.sh — baseline repo only, never installed.
# Feeds PreToolUse-style JSON into the hook and asserts the exit code.
# Usage: bash tests/file-guard-test.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/src/hooks/file-guard.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }

PASS=0 FAIL=0

# check EXPECTED_EXIT TOOL_NAME INPUT_KEY PATH
check() {
  local expected="$1" tool="$2" key="$3" path="$4" got json
  json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {sys.argv[2]: sys.argv[3]}}))' "$tool" "$key" "$path")
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$expected" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL: expected %s got %s — %s %s=%s\n' "$expected" "$got" "$tool" "$key" "$path" >&2
  fi
}

# check_raw EXPECTED_EXIT RAW_JSON
check_raw() {
  local expected="$1" json="$2" got
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$expected" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL: expected %s got %s — raw %s\n' "$expected" "$got" "$json" >&2
  fi
}

# ---- dotenv files are blocked ----
check 2 Read file_path '.env'
check 2 Read file_path '/repo/.env'
check 2 Read file_path '.env.local'
check 2 Read file_path '.env.production'
check 2 Read file_path 'config/.env.staging'
check 2 Read file_path '.env.test'
check 2 Read file_path '.env.example.bak'
check 2 Write file_path '.env'
check 2 Write file_path '/app/.env.local'
check 2 Edit file_path '.env.local'
check 2 MultiEdit file_path '.env.production'
check 2 Grep path '.env.production'
check 2 NotebookEdit notebook_path '/x/.env'

# ---- placeholder templates are allowed ----
check 0 Read file_path '.env.example'
check 0 Read file_path 'deep/path/.env.example'
check 0 Read file_path '.env.sample'
check 0 Read file_path '.env.template'
check 0 Read file_path '.env.dist'
check 0 Edit file_path '.env.example'
check 0 Write file_path '.env.example'
check 0 Write file_path 'config/.env.sample'

# ---- Grep glob parameter cannot target dotenv files ----
check 2 Grep glob '**/.env*'
check 2 Grep glob '.env*'
check 2 Grep glob '.env.production'
check 2 Grep glob '{.env,*.md}'
check 0 Grep glob '*.ts'
check 0 Grep glob '**/*.md'
check 0 Grep glob '.env.example'
check_raw 2 '{"tool_name":"Grep","tool_input":{"path":"src","glob":"**/.env*"}}'
check_raw 0 '{"tool_name":"Grep","tool_input":{"path":"src","glob":"**/*.py"}}'

# ---- non-dotenv paths pass ----
check 0 Read file_path '.envrc'
check 0 Read file_path 'env.example'
check 0 Read file_path '.environment'
check 0 Read file_path 'README.md'
check 0 Grep path 'src'

# ---- baseline guard files: write tools blocked, reading passes ----
check 2 Write file_path '.claude/hooks/bash-guard.sh'
check 2 Edit file_path '.claude/hooks/file-guard.sh'
check 2 Edit file_path '/repo/.claude/hooks/verify-gate.sh'
check 2 MultiEdit file_path '.claude/hooks/bash-guard.sh'
check 2 NotebookEdit notebook_path '.claude/hooks/x.ipynb'
check 2 Write file_path '.claude/verify-commands'
check 2 Edit file_path '.claude/avn-version'
check 0 Read file_path '.claude/hooks/bash-guard.sh'
check 0 Grep path '.claude/hooks'
check 0 Write file_path '.claude/verify-commands.example'
check 0 Edit file_path '.claude/skills/verify/SKILL.md'
check 0 Write file_path '.claude/rules/ui.md'
check 0 Edit file_path 'src/claude/hooks/app.ts'
check 0 Write file_path '.claude/settings.json'   # Edit protection = deny rule (see hook header), not this hook

# ---- malformed / empty input is non-blocking (same as bash-guard) ----
check_raw 0 '{}'
check_raw 0 'not-json'

echo ""
echo "file-guard-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
