#!/usr/bin/env bash
# Self-test for .claude/hooks/agent-guard.sh — baseline repo only, never installed.
# Feeds PreToolUse-style JSON for the Agent tool into the hook and asserts the
# exit code (0 = allow, 2 = block). Usage: bash tests/agent-guard-test.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/src/hooks/agent-guard.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }

PASS=0 FAIL=0

# Fixtures: the hook resolves custom agents from $CLAUDE_PROJECT_DIR/.claude/agents
# (project wins) and then $HOME/.claude/agents — both point at scratch dirs so the
# results never depend on the host machine. Identity is the frontmatter `name:`.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"; USERHOME="$TMP/home"
mkdir -p "$PROJ/.claude/agents/nested" "$USERHOME/.claude/agents"

# agent FILE NAME [MODEL-LINE]
agent() {
  { printf -- '---\nname: %s\ndescription: fixture\n' "$2"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf -- '---\n\nBody text. A "model: haiku" here must never count.\n'; } > "$1"
}
agent "$PROJ/.claude/agents/sonnet-agent.md"   sonnet-agent  'model: sonnet'
agent "$PROJ/.claude/agents/opus-full.md"      opus-full     'model: claude-opus-5'
agent "$PROJ/.claude/agents/quoted.md"         quoted        'model: "Sonnet"   # pinned'
agent "$PROJ/.claude/agents/inherit.md"        inherit-agent 'model: inherit'
agent "$PROJ/.claude/agents/nomodel.md"        nomodel
agent "$PROJ/.claude/agents/haiku.md"          haiku-agent   'model: haiku'
agent "$PROJ/.claude/agents/nested/deep.md"    deep-agent    'model: opus'
agent "$PROJ/.claude/agents/user-agent.md"     user-agent    'model: haiku'   # shadows the user-level copy
agent "$USERHOME/.claude/agents/user-agent.md" user-agent    'model: sonnet'
agent "$USERHOME/.claude/agents/home-only.md"  home-only     'model: sonnet'
printf -- '---\nname: body-trap\ndescription: fixture\n---\n\nmodel: sonnet\n' > "$PROJ/.claude/agents/body-trap.md"
printf -- '---\nmodel: sonnet\n---\n' > "$PROJ/.claude/agents/stem-only.md"   # no name: → file stem
printf 'model: sonnet\n' > "$PROJ/.claude/agents/no-frontmatter.md"           # not a definition

export CLAUDE_PROJECT_DIR="$PROJ" HOME="$USERHOME"
unset CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE
HOOK_ENV=""   # extra VAR=VALUE assignments for the hook process (env cases below)

# run_hook RAW_JSON — the hook's exit code
run_hook() {
  # shellcheck disable=SC2086
  printf '%s' "$1" | env $HOOK_ENV bash "$HOOK" >/dev/null 2>&1
}
# verdict EXPECTED GOT LABEL
verdict() {
  if [ "$2" -eq "$1" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: expected %s got %s — %s\n' "$1" "$2" "$3" >&2
  fi
}
# json TOOL TYPE [MODEL] — Agent-tool PreToolUse payload; TYPE "" omits subagent_type
json() {
  python3 -c '
import json, sys
ti = {"prompt": "do the thing", "description": "fixture"}
if sys.argv[2] != "": ti["subagent_type"] = sys.argv[2]
if len(sys.argv) > 3: ti["model"] = sys.argv[3]
print(json.dumps({"tool_name": sys.argv[1], "permission_mode": "default", "tool_input": ti}))' "$@"
}
# check EXPECTED TYPE             — Agent call without a model parameter
# check_model EXPECTED TYPE MODEL — Agent call with model=MODEL
# check_raw EXPECTED RAW_JSON     — arbitrary stdin
check()       { local j; j=$(json Agent "$2");      run_hook "$j"; verdict "$1" $? "type=$2 (no model) env=[$HOOK_ENV]"; }
check_model() { local j; j=$(json Agent "$2" "$3"); run_hook "$j"; verdict "$1" $? "type=$2 model=$3 env=[$HOOK_ENV]"; }
check_raw()   { run_hook "$2"; verdict "$1" $? "raw $2"; }

# ---- the exemption and the hard block ----
check 0 Plan
check 0 plan
check_model 0 Plan haiku          # Plan is outside the check whatever it is given
check 2 fork
check_model 2 fork sonnet         # a fork ignores model overrides → always blocked

# ---- built-in Explore: must be given a model explicitly ----
check 2 Explore
check_model 0 Explore sonnet
check_model 0 Explore SONNET
check_model 0 Explore 'sonnet[1m]'
check_model 0 Explore claude-sonnet-5
check_model 0 Explore opus
check_model 0 Explore claude-opus-4-8
check_model 0 Explore us.anthropic.claude-opus-4-8
check_model 0 Explore opusplan
check_model 2 Explore haiku
check_model 2 Explore claude-haiku-4-5
check_model 2 Explore fable
check_model 2 Explore best
check_model 2 Explore default
check_model 2 Explore inherit
check_model 2 Explore 123
check_model 2 Explore ''          # empty model = absent
HOOK_ENV="CLAUDE_CODE_SUBAGENT_MODEL=sonnet"
check 2 Explore                   # Explore ignores the env default
HOOK_ENV=""

# ---- general-purpose / missing type: the env default applies ----
check 2 general-purpose
check 2 ''
check_model 0 general-purpose opus
HOOK_ENV="CLAUDE_CODE_SUBAGENT_MODEL=sonnet"
check 0 general-purpose
check 0 ''
HOOK_ENV="CLAUDE_CODE_SUBAGENT_MODEL=haiku"
check 2 general-purpose
check_model 0 general-purpose sonnet   # the parameter beats the env default
HOOK_ENV=""

# ---- other built-ins the hook cannot see ----
check 2 claude-code-guide
check_model 0 claude-code-guide opus

# ---- custom agent definitions ----
check 0 sonnet-agent
check 0 Sonnet-Agent              # identity match is case-insensitive
check 0 opus-full
check 0 quoted                    # quoted value with a trailing comment
check 0 deep-agent                # nested dir, name ≠ file stem
check 2 deep                      # the file stem is not an identity once name: exists
check 0 stem-only                 # no name: → file stem
check 2 no-frontmatter
check 2 inherit-agent
check 2 nomodel
check 2 body-trap                 # a model in the body must not count
check 2 haiku-agent
check_model 0 haiku-agent opus    # the call parameter beats the definition
check 2 user-agent                # project (haiku) shadows user-level (sonnet)
check 0 home-only                 # user-level definition
check 2 'plug:x'                  # unknown/plugin type needs an explicit model
check_model 0 'plug:x' opus
HOOK_ENV="CLAUDE_CODE_SUBAGENT_MODEL=sonnet"
check 2 inherit-agent             # model: inherit is terminal — the env default does not apply
check 0 nomodel                   # no model: → env default
check 0 body-trap                 # same: the env default applies, the body is still ignored
check 0 'plug:x'
HOOK_ENV=""

# ---- FORCE overrides definitions and parameters ----
HOOK_ENV="CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=sonnet"
check 0 Explore
check_model 0 Explore haiku       # the parameter is ignored under FORCE
check 0 haiku-agent
HOOK_ENV="CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1"
check 2 sonnet-agent              # FORCE without a model → inherit
check 0 Plan
HOOK_ENV=""

# ---- tool names and malformed input ----
check_raw 2 "$(json Task Explore)"
check_raw 0 "$(json Task Explore sonnet)"
check_raw 0 "$(json Bash Explore)"                              # not the Agent tool → pass through
check_raw 0 'not-json'
check_raw 0 '[]'
check_raw 0 ''
check_raw 2 '{"tool_input":{"subagent_type":"Explore"}}'       # no tool_name → still judged
check_raw 0 '{"tool_input":{"subagent_type":"Explore","model":"sonnet"}}'
check_raw 2 '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","model":42}}'   # non-string model = absent
check_raw 2 '{"tool_name":"Agent","tool_input":"oops"}'        # tool_input not an object → general-purpose, inherit
check_raw 2 '{"tool_name":"Agent","permission_mode":"plan","tool_input":{"subagent_type":"Explore"}}'   # plan mode is no exemption

# ---- fail closed without python3 ----
SHIM="$TMP/shim"; mkdir -p "$SHIM"
ln -s "$(command -v bash)" "$SHIM/bash"
J="$(json Agent Explore sonnet)"
printf '%s' "$J" | PATH="$SHIM" bash "$HOOK" >/dev/null 2>&1
verdict 2 $? "python3 missing must fail closed"

printf '\nagent-guard-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
