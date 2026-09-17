#!/usr/bin/env bash
# .claude/hooks/agent-guard.sh
# PreToolUse hook for the Agent tool (legacy name: Task) — the subagent model
# policy. Every subagent except the built-in Plan agent must run on Sonnet or
# Opus, in EVERY permission mode (plan mode included): research, exploration,
# search, docs, review and general-purpose work is delegated work and never
# needs the main model. Only Plan — the one subagent that does planning — may
# inherit the main model (it is exempt whatever model it is given). Forks
# (subagent_type "fork") always run on the parent model and ignore model
# overrides, so they are blocked outright; settings.json also denies
# Agent(fork) — defense in depth for the case where this hook cannot run.
#
# The hook mirrors Claude Code's model resolution so it judges the model the
# call would actually get:
#   1. CLAUDE_CODE_SUBAGENT_MODEL_FORCE set → CLAUDE_CODE_SUBAGENT_MODEL for
#      every subagent (or inherit when that is empty);
#   2. the call's `model` parameter;
#   3. the agent definition's `model:` frontmatter — .claude/agents/**/*.md of
#      the project first, then ~/.claude/agents/**/*.md; identity is the
#      `name:` field (file stem as fallback); `inherit` is terminal;
#   4. CLAUDE_CODE_SUBAGENT_MODEL (settings.json ships sonnet) — honoured by
#      general-purpose and by definitions without a model, ignored by the
#      built-in Explore;
#   5. otherwise the main model (inherit) → blocked.
# Definitions the hook cannot see (plugin agents, built-ins other than
# Plan/Explore) fall back to steps 4–5, so they need an explicit `model`
# unless the env default applies. Accepted: any alias or model id naming
# sonnet or opus (sonnet, opus, opusplan, claude-sonnet-5, claude-opus-4-8,
# sonnet[1m], …). Rejected: haiku, fable, best, default, inherit, anything else.
#
# Seatbelt caveats: the hook judges the REQUESTED model, not the served one
# (an availableModels allowlist may substitute); a forked skill
# (context: fork) does not pass through the Agent tool, so its own `model:`
# frontmatter is the control there (skills/code-review pins opus); a custom
# agent named Plan is exempt by name like the built-in.
#
# Contract: hook receives JSON on stdin; exit 0 = allow, exit 2 = block
# (stderr is shown to Claude as the reason, including how to re-issue the
# call). Fails closed without python3, like bash-guard and file-guard.

set -u

block() { echo "BLOCKED by baseline policy: $1" >&2; exit 2; }

# Fail closed: without python3 the JSON cannot be inspected and the policy
# would be silently disabled.
command -v python3 >/dev/null 2>&1 || \
  block "agent-guard needs python3 to inspect subagent calls; install python3, or run the delegated work yourself."

AGENT_GUARD_PY=$(cat <<'PY'
import json, os, re, sys

proj, home = sys.argv[1], sys.argv[2]


def out(verdict):
    print(verdict)
    sys.exit(0)


try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError("not an object")
except Exception:
    out("OK")  # nothing parseable to judge — same fail-open as bash-guard's empty command

tool = d.get("tool_name")
if isinstance(tool, str) and tool and tool not in ("Agent", "Task"):
    out("OK")  # a mis-wired matcher must never brick another tool

ti = d.get("tool_input")
if not isinstance(ti, dict):
    ti = {}
raw = ti.get("subagent_type")
typ = raw.strip() if isinstance(raw, str) else ""
tl = typ.lower()

if tl == "plan":
    out("OK")  # the planning subagent — the one that may inherit the main model
if tl == "fork":
    out("BLOCK subagent 'fork' forks the main conversation and always runs on the main model "
        "(model overrides are ignored). Spawn a fresh subagent with a self-contained prompt and "
        'model: "sonnet" (research/explore/search/docs) or "opus" (review/complex reasoning).')

FIELD = re.compile(r"^\s*(name|model)\s*:\s*(.+?)\s*$")


def frontmatter(path):
    """name/model from the YAML frontmatter; None when the file has no (closed) frontmatter."""
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    fields = {}
    for line in lines[1:]:
        if re.match(r"^---\s*$", line):
            return fields
        m = FIELD.match(line)
        if m:
            val = re.sub(r"\s+#.*$", "", m.group(2)).strip().strip("\"'")
            if val:
                fields[m.group(1)] = val
    return None  # never closed — not a frontmatter


def find_definition(name):
    """First matching agent definition: project dir first, then the user dir."""
    if not name:
        return None
    want = name.lower()
    roots = [os.path.join(proj, ".claude", "agents")]
    if home:
        roots.append(os.path.join(home, ".claude", "agents"))
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for fn in sorted(filenames):
                if not fn.endswith(".md"):
                    continue
                fields = frontmatter(os.path.join(dirpath, fn))
                if fields is None:
                    continue
                fm_name = fields.get("name", "").lower()
                if fm_name == want or (not fm_name and fn[:-3].lower() == want):
                    return fields
    return None


env_model = (os.environ.get("CLAUDE_CODE_SUBAGENT_MODEL") or "").strip()
force = (os.environ.get("CLAUDE_CODE_SUBAGENT_MODEL_FORCE") or "").strip()
param = ti.get("model")
param = param.strip() if isinstance(param, str) else ""
definition = find_definition(typ)

if force:
    eff, via = (env_model or "inherit"), "CLAUDE_CODE_SUBAGENT_MODEL_FORCE"
elif param:
    eff, via = param, "the model parameter"
elif definition is not None and definition.get("model"):
    eff, via = definition["model"], "its agent definition"
elif tl == "explore" and definition is None:
    eff, via = "inherit", "the built-in Explore agent (it ignores CLAUDE_CODE_SUBAGENT_MODEL)"
elif env_model:
    eff, via = env_model, "CLAUDE_CODE_SUBAGENT_MODEL"
else:
    eff, via = "inherit", "inheritance (no model given anywhere)"

el = eff.lower()
if el == "opusplan" or re.search(r"(^|[^a-z])(sonnet|opus)([^a-z]|$)", el):
    out("OK")

shown = "the main model (inherit)" if el == "inherit" else "'" + eff + "'"
out("BLOCK subagent '" + (typ or "general-purpose") + "' would run on " + shown + " via " + via +
    ". Every subagent except Plan runs on Sonnet or Opus — re-issue the call with "
    'model: "sonnet" (research/explore/search/docs) or "opus" (review/complex reasoning).')
PY
)

VERDICT=$(python3 -c "$AGENT_GUARD_PY" "${CLAUDE_PROJECT_DIR:-$PWD}" "${HOME:-}")

case "$VERDICT" in
  BLOCK\ *) block "${VERDICT#BLOCK }" ;;
  *)        exit 0 ;;
esac
