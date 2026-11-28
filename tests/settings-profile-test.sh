#!/usr/bin/env bash
# Self-test for the settings profile pair — baseline repo only, never installed.
# src/settings.relaxed.json must differ from src/settings.json in EXACTLY the
# documented ways (this file is the machine-checked delta spec); everything
# outside permissions.deny/ask/allow must be identical (except $comment*).
# The invariants shared by both profiles (permissions.defaultMode acceptEdits,
# the bare Bash allow rule, the Agent(fork) deny, the hook wiring, the subagent
# model env default, and since v2.13.0 the worktree ban, the outside-directory
# block and the scope-guard wiring) are asserted explicitly below — the
# identical-keys check skips the whole permissions object, and Claude Code reads
# defaultMode ONLY from there.
# v2.13.0 also pins the ask list: it is generated here from the action families
# (ask when a command changes data or state, not by tool name), and a table of
# example commands checks what must and must not prompt in each profile.
# Usage: bash tests/settings-profile-test.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRICT="$ROOT/src/settings.json"
RELAXED="$ROOT/src/settings.relaxed.json"
[ -f "$STRICT" ]  || { echo "missing: $STRICT" >&2; exit 1; }
[ -f "$RELAXED" ] || { echo "missing: $RELAXED" >&2; exit 1; }

python3 - "$STRICT" "$RELAXED" <<'PY'
import json, re, sys

strict_path, relaxed_path = sys.argv[1], sys.argv[2]
strict = json.load(open(strict_path))
relaxed = json.load(open(relaxed_path))

failures = []


def fail(msg):
    failures.append(msg)


def bash(*patterns):
    return [f"Bash({p})" for p in patterns]


def both_cases(words):
    return [w for x in words for w in (x.upper(), x.lower())]


# ---- ask rules by action (v2.13.0) — the settings files must list exactly these ----
GIT_GH = bash("git push:*", "git reset --hard:*", "gh pr merge:*", "gh release:*", "gh repo delete:*")
PACKAGES = bash("npx playwright install:*", "npm install:*", "yarn add:*", "pnpm add:*",
                "pip install:*", "uv add:*")
REMOTE = bash("terraform:*", "ansible:*", "ansible-playbook:*", "ssh:*", "scp:*", "rsync:*")
DOCKER = bash("docker rm:*", "docker rmi:*", "docker * rm *", "docker * prune*",
              "docker*compose* down", "docker*compose* down *",
              "docker*compose* rm", "docker*compose* rm *")
SQL = bash(*[f"*{tool}*{kw}" for tool in ("psql", "mysql")
             for kw in ("INSERT INTO *", "insert into *", "UPDATE *SET *", "update *set *",
                        "DELETE FROM *", "delete from *", "ALTER *", "alter *")])
REDIS = bash(*[f"*redis-cli* {v} *"
               for v in both_cases(("del", "unlink", "set", "hset", "hdel", "expire"))])
KUBECTL = bash(*[f"kubectl* {v} *" for v in ("apply", "delete", "create", "replace", "patch",
                                              "edit", "scale", "set", "exec", "drain")],
               "kubectl* rollout restart*", "kubectl* rollout undo*",
               "kubectl* config use-context*", "kubectl* config set*")
HELM = bash(*[f"helm* {v} *" for v in ("install", "upgrade", "uninstall", "delete", "rollback")])
AWS = bash(*[f"aws* s3 {v} *" for v in ("rm", "rb", "mv", "sync")],
           *[f"aws * {v}-*" for v in ("delete", "put", "create", "update", "modify",
                                      "terminate", "stop", "start", "run", "reboot")])
GCLOUD = bash(*[f"gcloud * {v} *" for v in ("delete", "create", "update", "set", "rm", "ssh",
                                            "stop", "start", "reset", "add-iam-policy-binding",
                                            "remove-iam-policy-binding")],
              "gcloud * deploy*")
AZ = bash(*[f"az * {v} *" for v in ("delete", "create", "update", "set", "start", "stop",
                                    "restart", "deallocate", "purge")],
          "az * upload*")
SYSTEMCTL = bash(*[f"systemctl* {v} *" for v in ("start", "stop", "restart", "enable", "disable",
                                                 "mask", "kill")],
                 *[f"systemctl* {v}*" for v in ("reload", "daemon-re", "reboot", "poweroff")])
CLOUD = KUBECTL + HELM + AWS + GCLOUD + AZ + SYSTEMCTL
LOCAL_DATA = DOCKER + SQL + REDIS          # strict only: relaxed is for isolated systems
STRICT_ASK = GIT_GH + PACKAGES + LOCAL_DATA + CLOUD + REMOTE
RELAXED_ASK = GIT_GH + bash("curl:*", "wget:*") + CLOUD + REMOTE

for label, d, expected in (("strict", strict, STRICT_ASK), ("relaxed", relaxed, RELAXED_ASK)):
    got = set(d["permissions"]["ask"])
    if got != set(expected):
        fail(f"ask ({label}): list differs from the action families\n"
             f"  unexpected: {sorted(got - set(expected))}\n"
             f"  missing:    {sorted(set(expected) - got)}")

# ---- the documented delta (relaxed vs strict) ----
DENY_REMOVED = {
    "Bash(curl:*)", "Bash(wget:*)",
    "Read(./.env)", "Read(**/.env)", "Read(**/*.key)", "Read(**/*.pem)",
    "Read(**/*.p12)", "Read(**/*.pfx)", "Read(**/credentials.json)",
    "Read(**/secrets/**)",
    "Edit(**/.env)", "Edit(**/secrets/**)",
}
DENY_ADDED = set()
ASK_REMOVED = set(PACKAGES + LOCAL_DATA)
ASK_ADDED = {"Bash(curl:*)", "Bash(wget:*)"}
ALLOW_REMOVED = set()
ALLOW_ADDED = {
    "Bash(docker:*)", "Bash(docker compose:*)", "Bash(docker-compose:*)",
    "Bash(npm install:*)", "Bash(yarn add:*)", "Bash(pnpm add:*)",
    "Bash(pip install:*)", "Bash(uv add:*)", "Bash(npx playwright install:*)",
    "Bash(psql:*)", "Bash(mysql:*)", "Bash(redis-cli:*)",
}

# ---- permission lists: no duplicates, exact expected delta ----
for name, removed_exp, added_exp in (
    ("deny", DENY_REMOVED, DENY_ADDED),
    ("ask", ASK_REMOVED, ASK_ADDED),
    ("allow", ALLOW_REMOVED, ALLOW_ADDED),
):
    s = strict["permissions"][name]
    r = relaxed["permissions"][name]
    for label, lst in (("strict", s), ("relaxed", r)):
        dupes = {x for x in lst if lst.count(x) > 1}
        if dupes:
            fail(f"{name} ({label}): duplicate entries {sorted(dupes)}")
    removed = set(s) - set(r)
    added = set(r) - set(s)
    if removed != removed_exp:
        fail(f"{name}: removed-in-relaxed mismatch\n"
             f"  unexpected removals: {sorted(removed - removed_exp)}\n"
             f"  missing removals:    {sorted(removed_exp - removed)}")
    if added != added_exp:
        fail(f"{name}: added-in-relaxed mismatch\n"
             f"  unexpected additions: {sorted(added - added_exp)}\n"
             f"  missing additions:    {sorted(added_exp - added)}")

# ---- everything outside the permission lists must be identical ----
def strip(d):
    return {k: v for k, v in d.items()
            if k != "permissions" and not k.startswith("$comment")}

if strip(strict) != strip(relaxed):
    diff_keys = [k for k in set(strip(strict)) | set(strip(relaxed))
                 if strip(strict).get(k) != strip(relaxed).get(k)]
    fail(f"non-permission keys differ between profiles: {sorted(diff_keys)}")

# ---- invariants — identical in both profiles ----
HOOK_DIR = "${CLAUDE_PROJECT_DIR}/.claude/hooks/"
AGENT_HOOK = HOOK_DIR + "agent-guard.sh"
BASH_HOOK = HOOK_DIR + "bash-guard.sh"
SCOPE_HOOK = HOOK_DIR + "scope-guard.sh"
NEW_ASK = ("Bash(git reset --hard:*)", "Bash(gh pr merge:*)",
           "Bash(gh release:*)", "Bash(gh repo delete:*)")
V213_DENY = ("Bash(git worktree add:*)", "EnterWorktree", "ExitWorktree",
             "Agent(isolation:worktree)", "Edit(~/.claude/avn-scope/**)")
for label, d in (("strict", strict), ("relaxed", relaxed)):
    p = d["permissions"]
    if "defaultMode" in d:
        fail(f'{label}: top-level "defaultMode" is ignored by Claude Code — use permissions.defaultMode')
    if p.get("defaultMode") != "acceptEdits":
        fail(f'{label}: permissions.defaultMode must be "acceptEdits", got {p.get("defaultMode")!r}')
    if "Bash" not in p["allow"]:
        fail(f'{label}: permissions.allow must contain the bare "Bash" rule (auto-accept)')
    for rule in NEW_ASK:
        if rule not in p["ask"]:
            fail(f"{label}: permissions.ask missing {rule}")
    if "Agent(fork)" not in p["deny"]:
        fail(f"{label}: permissions.deny missing Agent(fork)")
    if d.get("worktree") != {"bgIsolation": "none"}:
        fail(f'{label}: worktree.bgIsolation must be "none", got {d.get("worktree")!r}')
    if d.get("env", {}).get("CLAUDE_CODE_SUBAGENT_MODEL") != "sonnet":
        fail(f'{label}: env.CLAUDE_CODE_SUBAGENT_MODEL must be "sonnet"')
    hooks = d.get("hooks", {})
    entries = [e for e in hooks.get("PreToolUse", []) if e.get("matcher") == "Agent|Task"]
    cmds = [h.get("command") for e in entries for h in e.get("hooks", [])]
    if len(entries) != 1 or cmds != [AGENT_HOOK]:
        fail(f"{label}: expected exactly one PreToolUse entry (matcher Agent|Task) running agent-guard.sh, got {cmds}")
    # ---- v2.12.0 invariants ----
    attr = d.get("attribution")
    if not isinstance(attr, dict) or attr != {"commit": "", "pr": ""}:
        fail(f'{label}: attribution must be the object {{"commit": "", "pr": ""}} — never false, '
             f'which makes older Claude Code versions skip the whole file; got {attr!r}')
    market = d.get("extraKnownMarketplaces", {}).get("taste-skill")
    if market != {"source": {"source": "github", "repo": "Leonxlnx/taste-skill"}, "autoUpdate": True}:
        fail(f'{label}: extraKnownMarketplaces["taste-skill"] must be the github source '
             f'Leonxlnx/taste-skill with autoUpdate, got {market!r}')
    if d.get("enabledPlugins", {}).get("taste-skill@taste-skill") is not True:
        fail(f'{label}: enabledPlugins must enable "taste-skill@taste-skill"')
    # ---- v2.13.0 invariants: worktree ban, outside-directory block, scope-guard wiring ----
    for rule in V213_DENY:
        if rule not in p["deny"]:
            fail(f"{label}: permissions.deny missing {rule}")
    if p.get("blockWritesOutsideWorkingDirectories") is not True:
        fail(f"{label}: permissions.blockWritesOutsideWorkingDirectories must be true, "
             f"got {p.get('blockWritesOutsideWorkingDirectories')!r}")
    # v2.13.1: the read block makes Claude Code prompt for every Bash command it cannot
    # trace (cd sub && ls, a loop, $(...)), also inside the project; scope-guard.sh
    # holds the read boundary of the file tools instead.
    if "blockReadsOutsideWorkingDirectories" in p:
        fail(f"{label}: permissions.blockReadsOutsideWorkingDirectories must not be set — it prompts "
             f"for untraceable Bash commands inside the project; scope-guard.sh covers Read/Grep/Glob")
    entries = [e for e in hooks.get("PreToolUse", []) if e.get("matcher") == "Bash"]
    cmds = [h.get("command") for e in entries for h in e.get("hooks", [])]
    if len(entries) != 1 or cmds != [BASH_HOOK, SCOPE_HOOK]:
        fail(f"{label}: the PreToolUse Bash entry must run bash-guard.sh then scope-guard.sh, got {cmds}")
    entries = [e for e in hooks.get("PreToolUse", []) if e.get("matcher") == "Read|Grep|Glob"]
    cmds = [h.get("command") for e in entries for h in e.get("hooks", [])]
    if len(entries) != 1 or cmds != [SCOPE_HOOK]:
        fail(f"{label}: expected exactly one PreToolUse entry (matcher Read|Grep|Glob) running "
             f"scope-guard.sh, got {cmds}")
    added = hooks.get("DirectoryAdded", [])
    cmds = [h.get("command") for e in added for h in e.get("hooks", [])]
    if cmds != [SCOPE_HOOK] or any("matcher" in e for e in added):
        fail(f"{label}: hooks.DirectoryAdded must be one matcher-less entry running scope-guard.sh, got {cmds}")
    created = hooks.get("WorktreeCreate", [])
    cmds = [str(h.get("command")) for e in created for h in e.get("hooks", [])]
    if (len(cmds) != 1 or "exit 2" not in cmds[0] or "worktree" not in cmds[0].lower()
            or any("matcher" in e for e in created)):
        fail(f"{label}: hooks.WorktreeCreate must be one matcher-less command that fails (exit 2), got {cmds}")

# ---- what prompts and what does not (an approximation of Claude Code's matcher:
# rules apply per subcommand, documented wrappers are stripped, "x:*" is a prefix
# match and "*" matches any text) ----
WRAPPERS = ("timeout", "time", "nice", "nohup", "stdbuf", "command", "builtin", "noglob", "xargs")


def subcommands(cmd):
    out = []
    for part in re.split(r"&&|\|\||;|\||\n", cmd):
        toks = part.split()
        while toks and toks[0] in WRAPPERS:
            toks = toks[1:]
            while toks and (toks[0].startswith("-") or re.fullmatch(r"[0-9.]+[smhd]?", toks[0])):
                toks = toks[1:]
        if toks:
            out.append(" ".join(toks))
    return out


def rule_matches(rule, sub):
    pat = rule[len("Bash("):-1]
    if pat.endswith(":*"):
        prefix = pat[:-2]
        return sub == prefix or sub.startswith(prefix + " ")
    rx = "".join(".*" if ch == "*" else re.escape(ch) for ch in pat)
    return re.fullmatch(rx, sub, re.S) is not None


def prompts(d, cmd):
    return any(rule_matches(r, s) for r in d["permissions"]["ask"] if r.startswith("Bash(")
               for s in subcommands(cmd))


MUST_BOTH = [
    "git push origin feat/x", "ssh host ls",
    "aws s3 rm s3://b/k", "aws s3 sync . s3://b/x", "aws --profile p s3 mv s3://b/a s3://b/c",
    "aws s3api delete-object --bucket b --key k", "aws ec2 terminate-instances --instance-ids i-1",
    "kubectl -n prod delete deploy api", "kubectl delete pod x", "kubectl apply -f k8s/",
    "kubectl rollout restart deploy/api", "helm upgrade --install api ./chart",
    "gcloud app deploy", "gcloud compute instances delete vm1", "az group delete -n rg",
    "systemctl --user restart app", "systemctl daemon-reload", "systemctl stop nginx",
]
MUST_STRICT_ONLY = [
    "docker rm web", "docker rmi img:1", "docker compose -f p.yml down -v", "docker compose down",
    "docker compose rm", "docker-compose rm -f w", "docker image rm i", "docker system prune -f",
    "docker ps -q | xargs docker rm", "redis-cli -n 1 del k", "docker exec cache redis-cli DEL k",
    'psql -c "UPDATE t SET a=1 WHERE id=1"', 'docker exec db psql -c "delete from t where id=1"',
    'mysql -e "INSERT INTO t VALUES (1)"', 'psql -c "ALTER TABLE t ADD c int"',
    "pip install x", "npm install left-pad",
]
MUST_NOT = [
    "git status", "docker ps", "docker logs web", "docker inspect web",
    "docker run -d --restart unless-stopped img", "docker build -t i .", "docker compose up -d",
    "docker compose run --rm web pytest", "docker compose logs downloader", "docker stop web",
    "docker cp web:/a ./a", 'docker exec db psql -c "select 1"',
    "aws s3 ls", "aws s3 cp ./m.pt s3://b/m.pt",
    "aws ec2 describe-instances --filters Name=tag:Name,Values=delete-me",
    "kubectl get pods", "kubectl describe pod patch-xyz", "kubectl rollout status deploy/api",
    "helm list", "gcloud compute instances list", "az vm list",
    "systemctl is-active nginx", "systemctl status nginx", "redis-cli get settings:app",
    'psql -c "select last_update from t"', 'grep -rn "INSERT INTO" src/',
    'git commit -m "update config and set defaults"',
]
for label, d, must, must_not in (
    ("strict", strict, MUST_BOTH + MUST_STRICT_ONLY, MUST_NOT),
    ("relaxed", relaxed, MUST_BOTH, MUST_NOT + MUST_STRICT_ONLY),
):
    for cmd in must:
        if not prompts(d, cmd):
            fail(f"{label}: no ask rule matches a data-changing command: {cmd}")
    for cmd in must_not:
        if prompts(d, cmd):
            fail(f"{label}: an ask rule matches a command that must not prompt: {cmd}")

if failures:
    for f in failures:
        print("FAIL:", f, file=sys.stderr)
    print(f"\nsettings-profile-test: {len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("settings-profile-test: all checks passed")
PY
