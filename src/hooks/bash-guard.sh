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
#
# Guard profiles: the installer stamps profile=strict|relaxed into
# .claude/avn-version (tamper-protected by rule 14, file-guard and the Edit
# deny rules). The relaxed profile — for isolated systems with no real
# secrets — lifts only the project-local secret rules (3b, 4); everything
# else applies in every profile. Anything but the exact value "relaxed"
# (missing file/line, unknown value) means strict — fail-safe default.

set -u

block() { echo "BLOCKED by baseline policy: $1" >&2; exit 2; }

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

# Guard profile: read from the tamper-protected version stamp; anything other
# than an exact "profile=relaxed" line means strict — fail-safe default.
PROFILE="strict"
_stamp="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/avn-version"
if [ -f "$_stamp" ] && [ "$(sed -n 's/^profile=//p' "$_stamp" 2>/dev/null | head -n1)" = "relaxed" ]; then
  PROFILE="relaxed"
fi

# 1) Pushing to main/master (any remote, any flag order). The ref must stand
#    alone (space/colon-delimited) so branches like feat/main-page pass.
#    Real protection is server-side branch protection; this is the local seatbelt.
if echo "$CMD" | grep -Eq '\bgit\b.*\bpush\b.*(\s|:)(main|master)(\s|$)'; then
  block "git push to main/master. Create a branch and open a PR."
fi

# 1b) Bare push while the checkout sits on main/master — `git push`, `git push
#     origin`, `git push -u origin HEAD` push the current branch without naming
#     it, so the ref-name match above never fires. An explicit non-HEAD refspec
#     (git push origin feat/x) still passes even from master; HEAD:dest is
#     judged by rule 1 on the destination name. Detached HEAD or a non-git dir
#     passes — this is a seatbelt, not a parser.
if echo "$CMD" | grep -Eq '\bgit\b.*\bpush\b'; then
  CUR_BRANCH="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ "$CUR_BRANCH" = "main" ] || [ "$CUR_BRANCH" = "master" ]; then
    PUSH_TARGET=$(python3 -c '
import shlex, sys
try:
    toks = shlex.split(sys.argv[1])
except ValueError:
    toks = sys.argv[1].split()
SEP = {"&&", "||", ";", "|", "&"}
current = False
for i, t in enumerate(toks):
    if t != "push":
        continue
    seg = []
    for u in toks[i + 1:]:
        if u in SEP:
            break
        seg.append(u)
    pos = [u for u in seg if not u.startswith("-")]
    refspecs = pos[1:]
    if not refspecs or "HEAD" in refspecs:
        current = True
print("CURRENT" if current else "EXPLICIT")
' "$CMD")
    if [ "$PUSH_TARGET" = "CURRENT" ]; then
      block "bare git push while the checkout is on $CUR_BRANCH pushes to $CUR_BRANCH. Create a branch and open a PR."
    fi
  fi
fi

# 2) rm safety, token-based (shlex) so flag order, case (-Rf) and position
#    (rm build -rf) cannot dodge it. Any token whose basename is rm starts an
#    invocation that runs to the next separator, so find -exec / xargs / sudo
#    forms stay caught while quoted strings ("rm -rf /") no longer match.
#    2a) recursive+force in any combination — always blocked.
#    2b) recursive rm (force or not) whose operand is an absolute or ~ path
#        resolving outside the project dir and outside /tmp — the agent must
#        not delete trees it does not own. Relative operands and unexpanded
#        $vars are skipped: seatbelt, not a parser.
if echo "$CMD" | grep -Eq '\brm\b'; then
  RM_VERDICT=$(python3 -c '
import os, shlex, sys
proj = sys.argv[2]
def split(s):
    try:
        return shlex.split(s)
    except ValueError:
        return s.split()
toks = split(sys.argv[1])
SEP = {"&&", "||", ";", "|", "&"}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
# Also scan the argument of a shell `-c` (sh -c "…", bash -c "…") so a
# destructive command hidden in a shell string is still seen; a `-c` that
# belongs to another tool (grep -c, wc -c) is left alone, and plain data such
# as `echo "rm -rf /"` has no -c and stays allowed.
streams = [toks]
seg_cmd = None
for i, t in enumerate(toks):
    if t in SEP:
        seg_cmd = None
        continue
    if seg_cmd is None and not t.startswith("-"):
        seg_cmd = os.path.basename(t)
    if t == "-c" and i + 1 < len(toks) and seg_cmd in SHELLS:
        streams.append(split(toks[i + 1]))
roots = {os.path.realpath(p) for p in (proj, "/tmp", os.environ.get("TMPDIR") or "/tmp")}
def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")
for stream in streams:
    for i, t in enumerate(stream):
        if os.path.basename(t) != "rm":
            continue
        seg = []
        for u in stream[i + 1:]:
            if u in SEP:
                break
            seg.append(u)
        rec = force = False
        operands = []
        for u in seg:
            if u == "--recursive":
                rec = True
            elif u == "--force":
                force = True
            elif len(u) > 1 and u.startswith("-") and not u.startswith("--"):
                rec = rec or "r" in u[1:] or "R" in u[1:]
                force = force or "f" in u[1:]
            elif not u.startswith("-"):
                operands.append(u)
        if rec and force:
            print("RECURSIVE_FORCE")
            sys.exit()
        if rec:
            for op in operands:
                if "$" in op:
                    continue
                if op.startswith("~") or os.path.isabs(op):
                    real = os.path.realpath(os.path.expanduser(op))
                    if not any(under(real, r) for r in roots):
                        print("OUTSIDE " + op)
                        sys.exit()
print("")
' "$CMD" "${CLAUDE_PROJECT_DIR:-$PWD}")
  case "$RM_VERDICT" in
    RECURSIVE_FORCE)
      block "rm with recursive+force. Delete manually or ask the user." ;;
    OUTSIDE\ *)
      block "recursive rm targets a path outside this project (${RM_VERDICT#OUTSIDE }). Work inside the project, or ask the user to run it." ;;
  esac
fi

# 3a) Reading the machine's own credentials via shell — home-directory key
#     material and cluster configs. These belong to the developer's machine,
#     not the project, so they stay blocked in EVERY profile.
if echo "$CMD" | grep -Eq '(kubeconfig|\.kube/|\.ssh/|\.aws/|\.docker/config\.json)'; then
  block "command touches home-directory/machine credentials (~/.ssh, ~/.aws, ~/.kube, kubeconfig) — blocked in every profile."
fi

# 3b) Reading project-local secret material via shell (cat/less/head/tail/
#     grep/base64/cp on sensitive paths) — Read() deny rules do not cover
#     Bash. Placeholder templates (.env.example/sample/template/dist) are
#     scrubbed out first; the boundary class excludes "." and word chars so
#     .env.example.bak stays blocked, and \2 re-inserts the boundary so
#     adjacent tokens survive (`cat .env .env.example` still matches on the
#     remaining `.env`). Lifted in the relaxed profile.
if [ "$PROFILE" = "strict" ]; then
  SCRUBBED=$(printf '%s\n' "$CMD" | sed -E 's/\.env\.(example|sample|template|dist)([^A-Za-z0-9_.]|$)/\2/g')
  if echo "$SCRUBBED" | grep -Eq '(\.env([^a-zA-Z0-9_]|$)|\.env\.|\.pem\b|\.key\b|\.p12\b|\.pfx\b|credentials\.json|secrets/)'; then
    block "command touches secret/credential paths."
  fi
fi

# 4) Printing environment secrets — covers $VAR and ${var} in any case.
#    Lifted in the relaxed profile (isolated system, no real secrets).
if [ "$PROFILE" = "strict" ] && \
   echo "$CMD" | grep -Eiq '\bprintenv\b|\benv\b\s*$|echo\s+.*\$\{?[a-zA-Z_]*(secret|token|key|password|passwd)'; then
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

# 13) Discarding uncommitted changes — `git checkout .`, any checkout with a
#     `--` pathspec (`checkout -- f`, `checkout HEAD -- src/`), and any
#     `git restore` that is not purely --staged all rewrite working-tree files.
#     Branch switching (`checkout feat/x`, `-b`, `--track origin/x`) and
#     unstaging (`restore --staged .`) still pass. The worktree match covers
#     short combos like -W and -SW.
if echo "$CMD" | grep -Eq '\bgit\s+checkout\s+((\S+\s+)?--\s+)?\.([/[:space:]]|$)' || \
   echo "$CMD" | grep -Eq '\bgit\s+checkout\b[^|;&]*\s--(\s|$)'; then
  block "git checkout of a pathspec discards uncommitted changes to those files. Ask the user."
fi
if echo "$CMD" | grep -Eq '\bgit\s+restore\b'; then
  if ! echo "$CMD" | grep -Eq -- '--staged\b' || \
     echo "$CMD" | grep -Eq -- '--worktree\b|(^|\s)-[a-zA-Z]*W\b'; then
    block "git restore rewrites working-tree files and discards uncommitted changes; only --staged (unstage) passes. Ask the user."
  fi
fi

# 13b) git stash drop/clear permanently deletes stashed work.
if echo "$CMD" | grep -Eq '\bgit\b.*\bstash\s+(drop|clear)\b'; then
  block "git stash drop/clear permanently deletes stashed work. Ask the user."
fi

# 14) Mutating the baseline guard layer via shell — .claude/hooks/*,
#     settings(.local).json, verify-commands, avn-version. The Edit-tool
#     vector is closed by the deny rules + file-guard; this closes the shell
#     vector (redirects, sed -i, cp/mv, script interpreters). Reading stays
#     allowed — cat/grep pass; any `>` in the line trips the mutator match
#     (acceptable false positive: use the Read tool). Legitimate updates are
#     unaffected: install.sh / avn update rewrite these files inside a script,
#     which this hook never sees on the command line. `git checkout` counts as
#     a mutator here: checking out a guard file reverts it (e.g. restoring an
#     old avn-version stamp would flip the guard profile).
if echo "$CMD" | grep -Eq '\.claude/(hooks/|settings(\.local)?\.json|verify-commands|avn-version)' && \
   echo "$CMD" | grep -Eq '>|\bgit\s+checkout\b|\b(mv|cp|rm|chmod|chown|tee|sed|awk|truncate|ln|patch|dd|install|python[0-9.]*|perl|ruby|node|npx)\b'; then
  block "modifying baseline guard files (.claude/hooks/, settings.json, verify-commands, avn-version). Run avn update / re-run install.sh, or edit them yourself."
fi

# 14b) Operand-based backstop for the guard layer — the prefix match above
#      keys on a literal ".claude/…" substring, which `cd .claude && sed -i …
#      avn-version` (bare operand) or a `git checkout` of the .claude dir /
#      whole tree can dodge. This matches a mutation by the operand's BASENAME
#      (the distinctive guard-file names, which never appear legitimately
#      elsewhere) and catches directory-level checkouts that revert guard files
#      — restoring an old avn-version stamp would flip the guard profile. Still
#      a seatbelt: a deliberately obfuscated command (subshells, eval) can slip.
GUARD_MUT=$(python3 -c '
import os, shlex, sys
def split(s):
    try:
        return shlex.split(s)
    except ValueError:
        return s.split()
toks = split(sys.argv[1])
SEP = {"&&", "||", ";", "|", "&"}
MUT = {"mv","cp","rm","chmod","chown","tee","sed","awk","truncate","ln","patch","dd","install","perl","ruby","node","npx"}
GUARD = {"avn-version","bash-guard.sh","file-guard.sh","verify-gate.sh","verify-commands","settings.local.json"}
def is_mut(t):
    b = os.path.basename(t)
    return b in MUT or b.startswith("python")
segs, seg = [], []
for t in toks:
    if t in SEP:
        segs.append(seg); seg = []
    else:
        seg.append(t)
segs.append(seg)
verdict = "OK"
for body in segs:
    if not body:
        continue
    redirect = False
    operands = []
    for t in body:
        if t.startswith(">"):
            redirect = True
            rest = t.lstrip(">")
            if rest:
                operands.append(rest)
        elif not t.startswith("-"):
            operands.append(t)
    # strip shell grouping punctuation so a subshell like `(cd .claude && …
    # avn-version)` cannot hide the operand behind a trailing paren
    operands = [o.strip("()") for o in operands]
    if redirect or any(is_mut(t) for t in body):
        if any(os.path.basename(o) in GUARD for o in operands):
            verdict = "BLOCK"; break
    if "git" in body and "checkout" in body:
        for o in operands:
            b = os.path.basename(o.rstrip("/"))
            if b in GUARD or b == ".claude" or o in (".", "./") or "/.claude" in o or o.startswith(".claude"):
                verdict = "BLOCK"; break
        if verdict == "BLOCK":
            break
print(verdict)
' "$CMD")
[ "$GUARD_MUT" = "BLOCK" ] && \
  block "modifying or reverting baseline guard files (.claude/hooks/, verify-commands, avn-version, settings.local.json). Run avn update / re-run install.sh, or edit them yourself."

exit 0
