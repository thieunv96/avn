#!/usr/bin/env bash
# Self-test for .claude/hooks/verify-gate.sh — baseline repo only, never installed.
# Feeds Stop-event JSON into the hook inside throw-away git repos and asserts the
# exit code (0 = allow the stop, 2 = block) and how often the verify commands
# really ran. Offline. Usage: bash tests/verify-gate-test.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/src/hooks/verify-gate.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v git >/dev/null 2>&1     || { echo "verify-gate-test: git not found — skipped"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "verify-gate-test: python3 not found — skipped"; exit 0; }

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# hermetic git: no dependence on the developer's git config or locale
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=avn-test GIT_AUTHOR_EMAIL=avn-test@example.invalid
export GIT_COMMITTER_NAME=avn-test GIT_COMMITTER_EMAIL=avn-test@example.invalid
export GIT_CEILING_DIRECTORIES="$TMP"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export TMPDIR="$TMP/tmp"; mkdir -p "$TMPDIR"     # the hook's session counter and scratch dirs land here

RUNS="$TMP/runs.log"                              # the verify command appends here, outside every repo
runs()  { if [ -f "$RUNS" ]; then wc -l < "$RUNS" | tr -d ' '; else echo 0; fi; }
reset() { rm -f "$RUNS"; }
commit() { git -C "$1" -c commit.gpgsign=false commit -q "${@:2}"; }

# newrepo DIR — one commit; .claude/ and ignored.log are ignored; the verify command counts its runs
newrepo() {
  mkdir -p "$1/.claude" && git -C "$1" init -q 2>/dev/null || return 1
  printf '.claude/\nignored.log\n' > "$1/.gitignore"
  printf 'a\n' > "$1/a.txt"
  git -C "$1" add -- .gitignore a.txt && commit "$1" -m init || return 1
  printf 'echo run >> "%s"\n' "$RUNS" > "$1/.claude/verify-commands"
}
# stop DIR [SESSION] — fire the Stop hook for the project; sets RC and ERR (stderr)
stop() {
  ERR="$(printf '{"session_id":"%s","hook_event_name":"Stop"}' "${2:-s1}" | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>&1 >/dev/null)"
  RC=$?
}
# expect LABEL WANT_RC WANT_RUNS — exit code of the last stop and total runs so far
expect() {
  if [ "$RC" -eq "$2" ] && [ "$(runs)" -eq "$3" ]; then ok
  else fail "$1 — want rc=$2 runs=$3, got rc=$RC runs=$(runs)${ERR:+ ($ERR)}"; fi
}

# ================= behaviour the gate already had =================

# dormant: no verify-commands file
R="$TMP/dormant"; newrepo "$R" || fail "fixture dormant"; rm -f "$R/.claude/verify-commands"
printf 'b\n' >> "$R/a.txt"; reset; stop "$R"; expect "dormant without verify-commands" 0 0

# not a git repository
R="$TMP/nongit"; mkdir -p "$R/.claude"; printf 'echo run >> "%s"\n' "$RUNS" > "$R/.claude/verify-commands"
reset; stop "$R"; expect "non-git directory" 0 0

# clean tree: a read-only turn is never gated
R="$TMP/clean"; newrepo "$R" || fail "fixture clean"
reset; stop "$R"; expect "clean tree" 0 0

# a dirty tree runs the commands
printf 'b\n' >> "$R/a.txt"; stop "$R"; expect "dirty tree runs the commands" 0 1

# a failing command blocks, three times, then the gate gives up
R="$TMP/red"; newrepo "$R" || fail "fixture red"
printf 'false\n' > "$R/.claude/verify-commands"; printf 'b\n' >> "$R/a.txt"; reset
stop "$R" red; expect "failing command blocks" 2 0
case "$ERR" in *"verification command failed"*) ok ;; *) fail "blocked stop does not name the failed command: $ERR" ;; esac
stop "$R" red; stop "$R" red; expect "third block" 2 0
stop "$R" red; expect "fourth stop gives up" 0 0
case "$ERR" in *"giving up"*) ok ;; *) fail "give-up message missing: $ERR" ;; esac

# python3 missing: fail open
R="$TMP/nopy"; newrepo "$R" || fail "fixture nopy"; printf 'b\n' >> "$R/a.txt"
SHIM="$TMP/shim-nopy"; mkdir -p "$SHIM"; ln -s "$(command -v bash)" "$SHIM/bash"
reset
ERR="$(printf '{"session_id":"s1"}' | PATH="$SHIM" CLAUDE_PROJECT_DIR="$R" bash "$HOOK" 2>&1 >/dev/null)"; RC=$?
expect "python3 missing fails open" 0 0

# ================= v2.12.0: skip when this exact content already passed =================

R="$TMP/skip"; newrepo "$R" || fail "fixture skip"
printf 'b\n' >> "$R/a.txt"; reset
stop "$R";    expect "first stop on new content runs" 0 1
stop "$R";    expect "unchanged content is not verified again" 0 1
case "$ERR" in *skipped*) ok ;; *) fail "a skipped stop does not say so: $ERR" ;; esac
stop "$R" s2; expect "another session reuses the pass" 0 1
printf 'c\n' >> "$R/a.txt"
stop "$R";    expect "an edit re-runs" 0 2
printf 'new\n' > "$R/b.txt"
stop "$R";    expect "a new untracked file re-runs" 0 3
printf '# a comment\n' >> "$R/.claude/verify-commands"
stop "$R";    expect "a changed verify-commands re-runs" 0 4
printf 'noise\n' > "$R/ignored.log"
stop "$R";    expect "an ignored file does not re-run" 0 4
git -C "$R" add -A
stop "$R";    expect "staging does not re-run" 0 4
commit "$R" -m "only a.txt" -- a.txt
[ -n "$(git -C "$R" status --porcelain)" ] && ok || fail "fixture: tree should still be dirty after the partial commit"
stop "$R";    expect "a partial commit of the same content does not re-run" 0 4

# red, then back to content that already passed: skipped, and the block counter is cleared
R="$TMP/revert"; newrepo "$R" || fail "fixture revert"
printf 'echo run >> "%s"\n! grep -q BAD a.txt\n' "$RUNS" > "$R/.claude/verify-commands"
printf 'good\n' > "$R/a.txt"; reset
stop "$R" rv; expect "green content passes" 0 1
printf 'BAD\n' > "$R/a.txt"
stop "$R" rv; expect "bad content blocks" 2 2
[ -e "$TMPDIR/claude-verify-gate-rv" ] && ok || fail "fixture: no block counter after a blocked stop"
printf 'good\n' > "$R/a.txt"
stop "$R" rv; expect "content that passed before is skipped" 0 2
[ ! -e "$TMPDIR/claude-verify-gate-rv" ] && ok || fail "a skipped stop left the block counter behind"

# a command that rewrites files: its result is only trusted once the tree is stable
R="$TMP/rewrite"; newrepo "$R" || fail "fixture rewrite"
printf 'echo run >> "%s"\nprintf "formatted\\n" > fmt.txt\n' "$RUNS" > "$R/.claude/verify-commands"
printf 'b\n' >> "$R/a.txt"; reset
stop "$R"; expect "rewriting command, stop 1 runs" 0 1
stop "$R"; expect "rewriting command, stop 2 runs on the rewritten tree" 0 2
stop "$R"; expect "rewriting command, stop 3 is skipped" 0 2

# a repository that has no index yet
R="$TMP/noindex"; mkdir -p "$R/.claude"; git -C "$R" init -q 2>/dev/null
printf 'a\n' > "$R/a.txt"; printf 'echo run >> "%s"\n' "$RUNS" > "$R/.claude/verify-commands"
[ ! -e "$R/.git/index" ] && ok || fail "fixture: the repo already has an index"
reset
stop "$R"; expect "no index yet: runs" 0 1
stop "$R"; expect "no index yet: then skips" 0 1
[ ! -e "$R/.git/index" ] && ok || fail "the hook created the real index"

# a submodule/gitlink hides edits inside it, so such a tree is never skipped
R="$TMP/gitlink"; newrepo "$R" || fail "fixture gitlink"
mkdir -p "$R/inner"; git -C "$R/inner" init -q 2>/dev/null; printf 'i\n' > "$R/inner/i.txt"
git -C "$R/inner" add -- i.txt && commit "$R/inner" -m inner
git -C "$R" add -- inner >/dev/null 2>&1
git -C "$R" ls-files -s | grep -q '^160000 ' && ok || fail "fixture: inner repo was not added as a gitlink"
reset
stop "$R"; stop "$R"; expect "a tree with a gitlink is verified every time" 0 2

# sparse checkout: the index does not describe the tree, never skip
R="$TMP/sparse"; newrepo "$R" || fail "fixture sparse"
git -C "$R" config core.sparseCheckout true; printf 'b\n' >> "$R/a.txt"; reset
stop "$R"; stop "$R"; expect "a sparse checkout is verified every time" 0 2

# the project is a subdirectory: an edit elsewhere in the repo still re-runs
R="$TMP/subdir"; newrepo "$R" || fail "fixture subdir"
mkdir -p "$R/app/.claude"; printf 'echo run >> "%s"\n' "$RUNS" > "$R/app/.claude/verify-commands"
printf 'x\n' > "$R/app/x.txt"; reset
stop "$R/app"; expect "subdir project runs" 0 1
stop "$R/app"; expect "subdir project skips" 0 1
printf 'y\n' > "$R/other.txt"
stop "$R/app"; expect "an edit outside the project dir re-runs" 0 2

# fingerprinting leaves the repository as it found it
R="$TMP/sidefx"; newrepo "$R" || fail "fixture sidefx"
printf 'b\n' >> "$R/a.txt"; printf 'u\n' > "$R/u.txt"; git -C "$R" add -- u.txt
OBJ_BEFORE="$(find "$R/.git/objects" -type f | wc -l | tr -d ' ')"
IDX_BEFORE="$(git -C "$R" diff --cached --name-only)"; ST_BEFORE="$(git -C "$R" status --porcelain)"
reset; stop "$R"; expect "side-effect fixture runs" 0 1
[ "$(find "$R/.git/objects" -type f | wc -l | tr -d ' ')" = "$OBJ_BEFORE" ] && ok || fail "the hook wrote objects into .git/objects"
[ "$(git -C "$R" diff --cached --name-only)" = "$IDX_BEFORE" ] && ok || fail "the hook changed the real index"
[ "$(git -C "$R" status --porcelain)" = "$ST_BEFORE" ] && ok || fail "the hook changed git status"
[ ! -e "$R/.git/index.lock" ] && ok || fail "the hook left an index.lock"
[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'claude-verify-fp*' 2>/dev/null)" ] && ok || fail "the hook left a scratch dir in TMPDIR"

# no usable scratch dir: behave exactly as before (run every time, never block on it)
R="$TMP/failopen"; newrepo "$R" || fail "fixture failopen"; printf 'b\n' >> "$R/a.txt"; reset
TMPDIR="$TMP/does-not-exist" stop "$R"; TMPDIR="$TMP/does-not-exist" stop "$R"
expect "no scratch dir: runs every time, exit 0" 0 2

# a pass file with junk in it is ignored and replaced
R="$TMP/junk"; newrepo "$R" || fail "fixture junk"; printf 'b\n' >> "$R/a.txt"
printf 'not a key\n' > "$R/.git/avn-verify-gate.pass"; reset
stop "$R"; expect "junk pass file: runs" 0 1
stop "$R"; expect "junk pass file: replaced, then skips" 0 1

# too much to hash (large untracked/modified files): no reuse, instead of a slow hook at every Stop
R="$TMP/big"; newrepo "$R" || fail "fixture big"
printf 'b\n' >> "$R/a.txt"; head -c 4096 /dev/zero > "$R/payload.bin"; reset
AVN_VERIFY_FP_MAX_BYTES=1024 stop "$R"; AVN_VERIFY_FP_MAX_BYTES=1024 stop "$R"
expect "over the size cap: verified every time" 0 2
[ ! -e "$R/.git/avn-verify-gate.pass" ] && ok || fail "over the size cap a pass was still recorded"
stop "$R"; stop "$R"; expect "under the default cap the same tree is reused" 0 3

# a command that reads stdin must not swallow the commands after it
R="$TMP/stdin"; newrepo "$R" || fail "fixture stdin"
printf 'cat > /dev/null\necho run >> "%s"\n' "$RUNS" > "$R/.claude/verify-commands"
printf 'b\n' >> "$R/a.txt"; reset
stop "$R"; expect "the command after a stdin reader still runs" 0 1

printf '\nverify-gate-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
