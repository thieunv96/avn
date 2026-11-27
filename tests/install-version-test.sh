#!/usr/bin/env bash
# Self-test for the installer/CLI: version stamp mechanism, install/uninstall
# behavior and the bin/avn CLI — baseline repo only, never installed. Fully
# offline: uses install.sh local mode and AVN_LOCAL_SRC for avn.
# Usage: bash tests/install-version-test.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
AVN="$ROOT/bin/avn"
VER="$(head -n1 "$ROOT/VERSION" | tr -d '[:space:]')"
[ -f "$INSTALL" ] || { echo "installer not found: $INSTALL" >&2; exit 1; }
[ -f "$AVN" ]     || { echo "avn CLI not found: $AVN" >&2; exit 1; }
[ -n "$VER" ]     || { echo "VERSION file is empty" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }

# assert_contains LABEL HAYSTACK NEEDLE
assert_contains() {
  case "$2" in *"$3"*) ok ;; *) fail "$1 — output missing: $3" ;; esac
}
# assert_not_contains LABEL HAYSTACK NEEDLE
assert_not_contains() {
  case "$2" in *"$3"*) fail "$1 — output unexpectedly has: $3" ;; *) ok ;; esac
}

# ---- hermetic git: no dependence on the developer's git config or locale ----
# (never assert on git's own messages — they are localized)
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=avn-test GIT_AUTHOR_EMAIL=avn-test@example.invalid
export GIT_COMMITTER_NAME=avn-test GIT_COMMITTER_EMAIL=avn-test@example.invalid
export GIT_CEILING_DIRECTORIES="$TMP"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
HAVE_GIT=0; command -v git >/dev/null 2>&1 && HAVE_GIT=1
# mkrepo DIR — a repo with one empty commit
mkrepo()  { mkdir -p "$1" && git -C "$1" init -q 2>/dev/null && git -C "$1" -c commit.gpgsign=false commit -q --allow-empty -m init; }
# track DIR MESSAGE PATH… — commit the paths (ignored ones included)
track()   { local d="$1" m="$2"; shift 2; git -C "$d" add -f -- "$@" && git -C "$d" -c commit.gpgsign=false commit -q -m "$m"; }
# tracked DIR PATHSPEC… — tracked files under the pathspecs, one per line
tracked() { local d="$1"; shift; git -C "$d" ls-files -- "$@"; }
# count_lines FILE LINE — exact-line occurrences
count_lines() { grep -cxF -e "$2" "$1" 2>/dev/null || true; }
# baseline_repo DIR — a repo that committed an old baseline copy plus its own files
baseline_repo() {
  mkrepo "$1" || return 1
  mkdir -p "$1/.claude/hooks" "$1/.claude/skills/team" "$1/pkg/.claude"
  printf 'old\n'        > "$1/CLAUDE.md"
  printf '{}\n'         > "$1/.claude/settings.json"
  printf '#!/bin/sh\n'  > "$1/.claude/hooks/bash-guard.sh"
  printf 'true\n'       > "$1/.claude/verify-commands"
  printf 'team\n'       > "$1/.claude/skills/team/SKILL.md"
  printf 'nested\n'     > "$1/pkg/CLAUDE.md"
  printf 'n\n'          > "$1/pkg/.claude/notes.md"
  track "$1" "commit the baseline like v2.10 did" .
}

STAMP_REL=".claude/avn-version"

# ---- 1. fresh install writes a stamp with the source VERSION ----
T1="$TMP/t1"; mkdir -p "$T1"
OUT="$(bash "$INSTALL" -y --no-color "$T1" 2>&1)" || fail "t1 install exited non-zero"
assert_contains "t1 branding" "$OUT" "ThieuNV Claude Code baseline"
assert_contains "t1 header" "$OUT" "$VER (new install)"
[ -f "$T1/$STAMP_REL" ] && ok || fail "t1 stamp not created"
grep -qx "version=$VER" "$T1/$STAMP_REL" && ok || fail "t1 stamp version != $VER"
grep -qx "source=local"  "$T1/$STAMP_REL" && ok || fail "t1 stamp source != local"
assert_contains "t1 summary" "$OUT" "baseline $VER"
assert_contains "t1 tells how to get the website-UI plugin" "$OUT" "claude plugin install taste-skill@taste-skill --scope user"
grep -qxF 'CLAUDE.md.bak'      "$T1/.gitignore" && ok || fail "t1 gitignore missing CLAUDE.md.bak"
grep -qxF '.claude/**/*.bak'   "$T1/.gitignore" && ok || fail "t1 gitignore missing .claude/**/*.bak"
grep -qxF 'CLAUDE.md'          "$T1/.gitignore" && ok || fail "t1 gitignore missing CLAUDE.md"
grep -qxF '.claude/'           "$T1/.gitignore" && ok || fail "t1 gitignore missing .claude/"
if grep -qxF '/CLAUDE.md' "$T1/.gitignore" || grep -qxF '/.claude/' "$T1/.gitignore"; then
  fail "t1 gitignore still gets the root-anchored v2.11.0 lines"
else
  ok
fi
# src/ → .claude/ mapping sanity: installed copies are byte-identical to the sources
cmp -s "$ROOT/src/hooks/bash-guard.sh" "$T1/.claude/hooks/bash-guard.sh" && ok || fail "t1 hook mapping mismatch (bash-guard)"
cmp -s "$ROOT/src/settings.json"       "$T1/.claude/settings.json"       && ok || fail "t1 settings mapping mismatch"
cmp -s "$ROOT/src/CLAUDE.md"           "$T1/CLAUDE.md"                   && ok || fail "t1 CLAUDE.md mapping mismatch"
cmp -s "$ROOT/src/skills/verify/SKILL.md" "$T1/.claude/skills/verify/SKILL.md" && ok || fail "t1 skills mapping mismatch"
cmp -s "$ROOT/src/hooks/agent-guard.sh" "$T1/.claude/hooks/agent-guard.sh" && ok || fail "t1 hook mapping mismatch (agent-guard)"
# v2.13.0: the always-loaded profile rule and the report skill ship like any other rule/skill
cmp -s "$ROOT/src/rules/profile.md" "$T1/.claude/rules/profile.md" && ok || fail "t1 rules mapping mismatch (profile)"
cmp -s "$ROOT/src/skills/report/SKILL.md" "$T1/.claude/skills/report/SKILL.md" && ok || fail "t1 skills mapping mismatch (report)"
cmp -s "$ROOT/src/hooks/scope-guard.sh" "$T1/.claude/hooks/scope-guard.sh" && ok || fail "t1 hook mapping mismatch (scope-guard)"
for h in bash-guard file-guard agent-guard verify-gate scope-guard; do
  [ -x "$T1/.claude/hooks/$h.sh" ] && ok || fail "t1 hook not executable: $h.sh"
done

# ---- 2. re-run: stamp unchanged, no .bak for the stamp ----
OUT="$(bash "$INSTALL" -y --no-color "$T1" 2>&1)" || fail "t1 re-install exited non-zero"
assert_contains "t1 rerun header" "$OUT" "$VER (unchanged)"
assert_contains "t1 rerun stamp" "$OUT" "unchanged .claude/avn-version"
[ ! -f "$T1/$STAMP_REL.bak" ] && ok || fail "t1 rerun created a stamp .bak"
[ "$(count_lines "$T1/.gitignore" 'CLAUDE.md')" -eq 1 ] && ok || fail "t1 rerun duplicated CLAUDE.md in .gitignore"
[ "$(count_lines "$T1/.gitignore" '.claude/')"  -eq 1 ] && ok || fail "t1 rerun duplicated .claude/ in .gitignore"
assert_not_contains "t1 rerun touches no gitignore line" "$OUT" "gitignore"

# ---- 3. older stamp: header and stamp line show old → new ----
printf 'version=0.0.1\nsource=local\n' > "$T1/$STAMP_REL"
OUT="$(bash "$INSTALL" -y --no-color "$T1" 2>&1)" || fail "t1 upgrade exited non-zero"
assert_contains "upgrade header" "$OUT" "0.0.1 → $VER"
grep -qx "version=$VER" "$T1/$STAMP_REL" && ok || fail "upgrade did not rewrite the stamp"
[ ! -f "$T1/$STAMP_REL.bak" ] && ok || fail "upgrade created a stamp .bak"

# ---- 4. dry-run on a clean dir creates nothing ----
T2="$TMP/t2"; mkdir -p "$T2"
OUT="$(bash "$INSTALL" --dry-run --no-color "$T2" 2>&1)" || fail "dry-run exited non-zero"
assert_contains "dry-run header" "$OUT" "$VER (new install)"
[ ! -e "$T2/$STAMP_REL" ] && ok || fail "dry-run created a stamp"
[ ! -e "$T2/CLAUDE.md" ]  && ok || fail "dry-run created CLAUDE.md"

# ---- 5. avn check: up to date (exit 0) vs outdated (exit 1) ----
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" check "$T1" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "avn check up-to-date: expected exit 0, got $RC"
assert_contains "check up-to-date" "$OUT" "up to date"
printf 'version=0.0.1\nsource=local\n' > "$T1/$STAMP_REL"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" check "$T1" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "avn check outdated: expected exit 1, got $RC"
assert_contains "check outdated" "$OUT" "outdated — installed 0.0.1 (strict) · latest $VER"

# ---- 6. avn update refuses a repo with no stamp; avn install works ----
T3="$TMP/t3"; mkdir -p "$T3"
if OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" update -y "$T3" 2>&1)"; then
  fail "avn update on a fresh dir should fail"
else
  ok
fi
assert_contains "update refusal" "$OUT" 'use "avn install" first'
[ ! -e "$T3/CLAUDE.md" ] && ok || fail "refused update still installed files"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" install -y --no-color "$T3" 2>&1)" || fail "avn install exited non-zero"
grep -qx "version=$VER" "$T3/$STAMP_REL" && ok || fail "avn install stamp version != $VER"
grep -qx "source=local" "$T3/$STAMP_REL" && ok || fail "avn install stamp source != local"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" update -y --no-color "$T3" 2>&1)" || fail "avn update exited non-zero"
assert_contains "avn update rerun" "$OUT" "$VER (unchanged)"

# ---- 7. avn version; CLI version constant is in sync with VERSION ----
OUT="$(cd "$T3" && bash "$AVN" version 2>&1)" || fail "avn version exited non-zero"
assert_contains "avn version stamp" "$OUT" "$VER"
CLI_VER="$(sed -n 's/^AVN_CLI_VERSION="\(.*\)"$/\1/p' "$AVN")"
[ "$CLI_VER" = "$VER" ] && ok || fail "AVN_CLI_VERSION ($CLI_VER) != VERSION ($VER) — bump both on release"

# ---- 8. unknown command exits 2 ----
bash "$AVN" bogus >/dev/null 2>&1
[ $? -eq 2 ] && ok || fail "unknown command should exit 2"

# ---- 9. avn check without a stamp exits 2, not 1 (CI contract: 1 means outdated) ----
T4="$TMP/t4"; mkdir -p "$T4"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" check "$T4" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok || fail "avn check without stamp: expected exit 2, got $RC"
assert_contains "check no-stamp message" "$OUT" "no version stamp"

# ---- 10. missing curl/wget still prints an error (regression: message was swallowed) ----
SHIM="$TMP/shim"; mkdir -p "$SHIM"
ln -s "$(command -v bash)" "$SHIM/bash"
ln -s "$(command -v tar)"  "$SHIM/tar"
# stdin invocation forces install.sh into remote (download) mode
OUT="$(PATH="$SHIM" bash -s -- --no-color "$T4" < "$INSTALL" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "install.sh without curl/wget: expected exit 1, got $RC"
assert_contains "install.sh downloader error" "$OUT" 'need "curl" or "wget"'
OUT="$(PATH="$SHIM" bash "$AVN" install "$T4" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "avn without curl/wget: expected exit 1, got $RC"
assert_contains "avn downloader error" "$OUT" 'need "curl" or "wget"'

# ---- 11. self-target (source repo as target): mutating install needs a TTY; dry-run doesn't ----
OUT="$(bash "$INSTALL" -y --no-color "$ROOT" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "self-target headless: expected exit 1, got $RC"
assert_contains "self-target refusal" "$OUT" "needs a human"
OUT="$(bash "$INSTALL" --force --no-color "$ROOT" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "self-target headless --force: expected exit 1, got $RC"
OUT="$(bash "$INSTALL" --dry-run --no-color "$ROOT" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "self-target dry-run: expected exit 0, got $RC"
assert_contains "self-target dry-run banner" "$OUT" "dry-run complete"
# the source repo keeps its own root-anchored lines: no gitignore drift
assert_not_contains "self-target dry-run gitignore" "$OUT" "gitignore"
# …and a baseline source repo that still tracks its root copy (a fork from before v2.8.0) is never untracked
if [ "$HAVE_GIT" -eq 1 ]; then
  TSELF="$TMP/tself"; mkrepo "$TSELF" || fail "tself fixture failed"
  mkdir -p "$TSELF/src"; : > "$TSELF/src/settings.json"; : > "$TSELF/install.sh"; printf 'copy\n' > "$TSELF/CLAUDE.md"
  track "$TSELF" "source repo with a tracked root copy" . || fail "tself fixture commit failed"
  OUT="$(bash "$INSTALL" --dry-run --no-color "$TSELF" 2>&1)" || fail "tself dry-run exited non-zero"
  assert_not_contains "a baseline source repo is never untracked" "$OUT" "untrack"
fi

# ---- 12. uninstall: removes shipped files, keeps user-edited and user-made ones ----
T5="$TMP/t5"; mkdir -p "$T5"
bash "$INSTALL" -y --no-color "$T5" >/dev/null 2>&1 || fail "t5 install exited non-zero"
printf 'true\n' >> "$T5/CLAUDE.md"                    # user-modified shipped file
printf '#opt-in\n' > "$T5/.claude/verify-commands"    # user-made file
OUT="$(bash "$INSTALL" --uninstall -y --no-color "$T5" 2>&1)" || fail "t5 uninstall exited non-zero"
assert_contains "t5 keep notice" "$OUT" "keep"
[ -f "$T5/CLAUDE.md" ] && ok || fail "t5 modified CLAUDE.md was removed"
[ -f "$T5/.claude/verify-commands" ] && ok || fail "t5 user verify-commands was removed"
[ ! -f "$T5/.claude/settings.json" ] && ok || fail "t5 settings.json not removed"
[ ! -f "$T5/.claude/hooks/bash-guard.sh" ] && ok || fail "t5 hook not removed"
[ ! -f "$T5/.claude/hooks/scope-guard.sh" ] && ok || fail "t5 scope-guard hook not removed"
[ ! -f "$T5/$STAMP_REL" ] && ok || fail "t5 stamp not removed"
[ ! -d "$T5/.claude/skills" ] && ok || fail "t5 skills dir not pruned"
[ -d "$T5/.claude" ] && ok || fail "t5 .claude dir should survive (verify-commands kept)"
if grep -qxF 'CLAUDE.local.md' "$T5/.gitignore"; then fail "t5 gitignore line not removed"; else ok; fi

# ---- 13. uninstall on a pristine install removes everything it added ----
T6="$TMP/t6"; mkdir -p "$T6"
bash "$INSTALL" -y --no-color "$T6" >/dev/null 2>&1 || fail "t6 install exited non-zero"
OUT="$(bash "$INSTALL" --uninstall -y --no-color "$T6" 2>&1)" || fail "t6 uninstall exited non-zero"
assert_contains "t6 summary" "$OUT" "uninstalled"
[ ! -e "$T6/CLAUDE.md" ] && ok || fail "t6 CLAUDE.md not removed"
[ ! -d "$T6/.claude" ] && ok || fail "t6 .claude dir not pruned"
if grep -qxF 'CLAUDE.md' "$T6/.gitignore" || grep -qxF '.claude/' "$T6/.gitignore" \
   || grep -qxF '/CLAUDE.md' "$T6/.gitignore" || grep -qxF '/.claude/' "$T6/.gitignore"; then
  fail "t6 gitignore still ignores the installed copy after uninstall"
else
  ok
fi

# ---- 14. uninstall guard rails: headless needs -y, dry-run changes nothing, avn wraps it ----
T7="$TMP/t7"; mkdir -p "$T7"
bash "$INSTALL" -y --no-color "$T7" >/dev/null 2>&1 || fail "t7 install exited non-zero"
OUT="$(bash "$INSTALL" --uninstall --no-color "$T7" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "t7 headless uninstall without -y: expected exit 1, got $RC"
assert_contains "t7 -y hint" "$OUT" "needs an explicit -y"
OUT="$(bash "$INSTALL" --uninstall --dry-run --no-color "$T7" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "t7 uninstall dry-run: expected exit 0, got $RC"
[ -f "$T7/.claude/settings.json" ] && ok || fail "t7 dry-run removed files"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" uninstall -y --no-color "$T7" 2>&1)" || fail "t7 avn uninstall exited non-zero"
[ ! -d "$T7/.claude" ] && ok || fail "t7 avn uninstall did not remove .claude"

# ---- 15. self-target uninstall is TTY-gated like the install ----
OUT="$(bash "$INSTALL" --uninstall -y --no-color "$ROOT" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "self-target uninstall headless: expected exit 1, got $RC"
assert_contains "self-target uninstall refusal" "$OUT" "needs a human"

# ---- 16. guard profiles: strict by default, invalid value, headless relax gate ----
T8="$TMP/t8"; mkdir -p "$T8"
bash "$INSTALL" -y --no-color "$T8" >/dev/null 2>&1 || fail "t8 install exited non-zero"
grep -qx "profile=strict" "$T8/$STAMP_REL" && ok || fail "t8 fresh stamp missing profile=strict"
cmp -s "$ROOT/src/settings.json" "$T8/.claude/settings.json" && ok || fail "t8 default settings != strict variant"
bash "$INSTALL" --profile bogus -y --no-color "$T8" >/dev/null 2>&1
[ $? -eq 2 ] && ok || fail "t8 --profile bogus: expected exit 2"
bash "$INSTALL" --uninstall --profile strict -y --no-color "$T8" >/dev/null 2>&1
[ $? -eq 2 ] && ok || fail "t8 --profile with --uninstall: expected exit 2"
OUT="$(bash "$INSTALL" --profile relaxed -y --no-color "$T8" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "t8 headless relax: expected exit 1, got $RC"
assert_contains "t8 relax refusal" "$OUT" "needs a human"
OUT="$(bash "$INSTALL" --profile relaxed --force --no-color "$T8" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "t8 headless relax --force: expected exit 1, got $RC"
grep -qx "profile=strict" "$T8/$STAMP_REL" && ok || fail "t8 refused relax still flipped the stamp"
cmp -s "$ROOT/src/settings.json" "$T8/.claude/settings.json" && ok || fail "t8 refused relax still swapped settings"
OUT="$(bash "$INSTALL" --profile relaxed --dry-run --no-color "$T8" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "t8 relax dry-run: expected exit 0, got $RC"
assert_contains "t8 dry-run profile row" "$OUT" "strict → relaxed"
grep -qx "profile=strict" "$T8/$STAMP_REL" && ok || fail "t8 dry-run changed the stamp"

# ---- 17. profile persistence: an already-relaxed repo stays relaxed headless ----
T9="$TMP/t9"; mkdir -p "$T9"
bash "$INSTALL" -y --no-color "$T9" >/dev/null 2>&1 || fail "t9 install exited non-zero"
printf 'version=0.0.1\nsource=local\nprofile=relaxed\n' > "$T9/$STAMP_REL"
OUT="$(bash "$INSTALL" -y --no-color "$T9" 2>&1)" || fail "t9 relaxed update exited non-zero"
assert_contains "t9 profile row" "$OUT" "profile relaxed"
grep -qx "profile=relaxed" "$T9/$STAMP_REL" && ok || fail "t9 update reset the profile"
grep -qx "version=$VER"    "$T9/$STAMP_REL" && ok || fail "t9 update did not bump the version"
cmp -s "$ROOT/src/settings.relaxed.json" "$T9/.claude/settings.json" && ok || fail "t9 relaxed settings not installed"

# ---- 18. --profile strict tightens headless; unknown stamp value reads as strict ----
OUT="$(bash "$INSTALL" --profile strict -y --no-color "$T9" 2>&1)" || fail "t9 tighten exited non-zero"
assert_contains "t9 tighten row" "$OUT" "relaxed → strict"
grep -qx "profile=strict" "$T9/$STAMP_REL" && ok || fail "t9 tighten did not rewrite the stamp"
cmp -s "$ROOT/src/settings.json" "$T9/.claude/settings.json" && ok || fail "t9 strict settings not restored"
printf 'version=0.0.1\nsource=local\nprofile=RELAXED\n' > "$T9/$STAMP_REL"
bash "$INSTALL" -y --no-color "$T9" >/dev/null 2>&1 || fail "t9 bogus-profile update exited non-zero"
grep -qx "profile=strict" "$T9/$STAMP_REL" && ok || fail "t9 unknown profile value did not normalize to strict"
cmp -s "$ROOT/src/settings.json" "$T9/.claude/settings.json" && ok || fail "t9 bogus value swapped in relaxed settings"

# ---- 19. uninstalling a relaxed repo compares settings against the relaxed variant ----
T10="$TMP/t10"; mkdir -p "$T10"
bash "$INSTALL" -y --no-color "$T10" >/dev/null 2>&1 || fail "t10 install exited non-zero"
printf '# ThieuNV Claude Code baseline — written by install.sh; do not edit by hand.\nversion=%s\nsource=local\nprofile=relaxed\n' "$VER" > "$T10/$STAMP_REL"
cp "$ROOT/src/settings.relaxed.json" "$T10/.claude/settings.json"
OUT="$(bash "$INSTALL" --uninstall -y --no-color "$T10" 2>&1)" || fail "t10 uninstall exited non-zero"
[ ! -f "$T10/.claude/settings.json" ] && ok || fail "t10 relaxed settings.json not removed"
[ ! -d "$T10/.claude" ] && ok || fail "t10 .claude not pruned"

# ---- 20. avn: --profile passthrough (value must not be swallowed as DIR), display ----
T11="$TMP/t11"; mkdir -p "$T11"
AVN_LOCAL_SRC="$ROOT" bash "$AVN" install --profile strict -y --no-color "$T11" >/dev/null 2>&1 \
  || fail "t11 avn install --profile strict exited non-zero"
[ -f "$T11/CLAUDE.md" ] && ok || fail "t11 --profile value was swallowed as the target DIR"
grep -qx "profile=strict" "$T11/$STAMP_REL" && ok || fail "t11 stamp missing profile=strict"
AVN_LOCAL_SRC="$ROOT" bash "$AVN" install --profile=strict -y --no-color "$T11" >/dev/null 2>&1 \
  || fail "t11 avn --profile=strict exited non-zero"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" install --profile relaxed -y --no-color "$T11" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "t11 avn relax headless: expected exit 1, got $RC"
assert_contains "t11 avn relax refusal" "$OUT" "needs a human"
OUT="$(AVN_LOCAL_SRC="$ROOT" bash "$AVN" check "$T11" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "t11 avn check: expected exit 0, got $RC"
assert_contains "t11 check shows profile" "$OUT" "installed $VER (strict)"
OUT="$(cd "$T11" && bash "$AVN" version 2>&1)" || fail "t11 avn version exited non-zero"
assert_contains "t11 version shows profile" "$OUT" "$VER (strict)"

# ---- 21. gitignore: a root-anchored v2.11.0 line is replaced; git sees no installed file ----
T12="$TMP/t12"; mkdir -p "$T12"
printf '/CLAUDE.md\n' > "$T12/.gitignore"
OUT="$(bash "$INSTALL" -y --no-color "$T12" 2>&1)" || fail "t12 install exited non-zero"
assert_contains     "t12 retires the anchored line" "$OUT" "-= /CLAUDE.md"
assert_contains     "t12 appends CLAUDE.md"         "$OUT" "+= CLAUDE.md"
assert_contains     "t12 appends .claude/"          "$OUT" "+= .claude/"
assert_not_contains "t12 no anchored append"        "$OUT" "+= /.claude/"
[ "$(count_lines "$T12/.gitignore" '/CLAUDE.md')" -eq 0 ] && ok || fail "t12 /CLAUDE.md still in .gitignore"
[ "$(count_lines "$T12/.gitignore" 'CLAUDE.md')"  -eq 1 ] && ok || fail "t12 CLAUDE.md not exactly once in .gitignore"
if [ "$HAVE_GIT" -eq 1 ]; then
  STATUS="$(cd "$T12" && git init -q 2>/dev/null && git status --porcelain --untracked-files=all 2>/dev/null)"
  if printf '%s\n' "$STATUS" | grep -qE '^\?\? (CLAUDE\.md|\.claude/)'; then
    fail "t12 installed copy shows up as untracked in git"
  else
    ok
  fi
fi

# ---- 22. gitignore: migrating a v2.11.0 install keeps the user's lines, replaces ours ----
T13="$TMP/t13"; mkdir -p "$T13"
printf 'node_modules/\n*.log\n/CLAUDE.md\n/.claude/\nCLAUDE.local.md\n.claude/settings.local.json\nCLAUDE.md.bak\n.claude/**/*.bak\n' > "$T13/.gitignore"
cp "$T13/.gitignore" "$TMP/t13.before"
OUT="$(bash "$INSTALL" --dry-run --no-color "$T13" 2>&1)" || fail "t13 dry-run exited non-zero"
assert_contains "t13 dry-run retire CLAUDE.md" "$OUT" "-= /CLAUDE.md"
assert_contains "t13 dry-run retire .claude/"  "$OUT" "-= /.claude/"
assert_contains "t13 dry-run add CLAUDE.md"    "$OUT" "+= CLAUDE.md"
assert_contains "t13 dry-run add .claude/"     "$OUT" "+= .claude/"
cmp -s "$T13/.gitignore" "$TMP/t13.before" && ok || fail "t13 dry-run changed .gitignore"
bash "$INSTALL" -y --no-color "$T13" >/dev/null 2>&1 || fail "t13 install exited non-zero"
[ "$(count_lines "$T13/.gitignore" '/CLAUDE.md')" -eq 0 ] && ok || fail "t13 /CLAUDE.md not retired"
[ "$(count_lines "$T13/.gitignore" '/.claude/')"  -eq 0 ] && ok || fail "t13 /.claude/ not retired"
[ "$(count_lines "$T13/.gitignore" 'CLAUDE.md')"  -eq 1 ] && ok || fail "t13 CLAUDE.md not exactly once"
[ "$(count_lines "$T13/.gitignore" '.claude/')"   -eq 1 ] && ok || fail "t13 .claude/ not exactly once"
[ "$(count_lines "$T13/.gitignore" 'node_modules/')" -eq 1 ] && ok || fail "t13 user line node_modules/ lost"
[ "$(count_lines "$T13/.gitignore" '*.log')"      -eq 1 ] && ok || fail "t13 user line *.log lost"
OUT="$(bash "$INSTALL" -y --no-color "$T13" 2>&1)" || fail "t13 re-install exited non-zero"
assert_not_contains "t13 rerun is a no-op for .gitignore" "$OUT" "gitignore"

# ---- 23. gitignore: an unterminated last line is never glued to an appended one ----
T14="$TMP/t14"; mkdir -p "$T14"
printf 'node_modules/\n.env' > "$T14/.gitignore"
bash "$INSTALL" -y --no-color "$T14" >/dev/null 2>&1 || fail "t14 install exited non-zero"
[ "$(count_lines "$T14/.gitignore" '.env')"      -eq 1 ] && ok || fail "t14 the user's last pattern (.env) was glued or lost"
[ "$(count_lines "$T14/.gitignore" 'CLAUDE.md')" -eq 1 ] && ok || fail "t14 CLAUDE.md is not a line of its own"
T15="$TMP/t15"; mkdir -p "$T15"; : > "$T15/.gitignore"
bash "$INSTALL" -y --no-color "$T15" >/dev/null 2>&1 || fail "t15 install exited non-zero"
[ "$(head -n1 "$T15/.gitignore")" = "CLAUDE.md" ] && ok || fail "t15 empty .gitignore: first line is not CLAUDE.md"

# ---- 24. gitignore: rewriting keeps the file's mode and a symlinked .gitignore ----
T16="$TMP/t16"; mkdir -p "$T16"
printf 'keep-me\n/CLAUDE.md\n/.claude/\n' > "$T16/.gitignore"; chmod 600 "$T16/.gitignore"
bash "$INSTALL" -y --no-color "$T16" >/dev/null 2>&1 || fail "t16 install exited non-zero"
[ "$(ls -l "$T16/.gitignore" | cut -c1-10)" = "-rw-------" ] && ok || fail "t16 install changed the mode of .gitignore"
bash "$INSTALL" --uninstall -y --no-color "$T16" >/dev/null 2>&1 || fail "t16 uninstall exited non-zero"
[ "$(ls -l "$T16/.gitignore" | cut -c1-10)" = "-rw-------" ] && ok || fail "t16 uninstall changed the mode of .gitignore"
T17="$TMP/t17"; mkdir -p "$T17"
printf 'keep-me\n/CLAUDE.md\n' > "$TMP/t17.real"; ln -s "$TMP/t17.real" "$T17/.gitignore"
bash "$INSTALL" -y --no-color "$T17" >/dev/null 2>&1 || fail "t17 install exited non-zero"
[ -L "$T17/.gitignore" ] && ok || fail "t17 install replaced the symlinked .gitignore"
[ "$(count_lines "$TMP/t17.real" 'CLAUDE.md')" -eq 1 ] && ok || fail "t17 link target did not get CLAUDE.md"
bash "$INSTALL" --uninstall -y --no-color "$T17" >/dev/null 2>&1 || fail "t17 uninstall exited non-zero"
[ -L "$T17/.gitignore" ] && ok || fail "t17 uninstall replaced the symlinked .gitignore"
[ "$(cat "$TMP/t17.real")" = "keep-me" ] && ok || fail "t17 uninstall did not leave exactly the user's line"

# ---- 25. uninstall takes back every line any release appended, nothing else ----
T18="$TMP/t18"; mkdir -p "$T18"
bash "$INSTALL" -y --no-color "$T18" >/dev/null 2>&1 || fail "t18 install exited non-zero"
printf 'node_modules/\n*.log\n/CLAUDE.md\n/.claude/\nCLAUDE.md\n.claude/\nCLAUDE.local.md\n.claude/settings.local.json\nCLAUDE.md.bak\n.claude/**/*.bak\n' > "$T18/.gitignore"
printf 'node_modules/\n*.log\n' > "$TMP/t18.want"
bash "$INSTALL" --uninstall -y --no-color "$T18" >/dev/null 2>&1 || fail "t18 uninstall exited non-zero"
cmp -s "$T18/.gitignore" "$TMP/t18.want" && ok || fail "t18 uninstall left installer lines or removed user lines"

# ---- 26. gitignore: lines an older installer glued together are reported, never repaired ----
T19="$TMP/t19"; mkdir -p "$T19"   # what two v2.11.0 runs left behind after ".env" without a newline
printf 'node_modules/\n.env/CLAUDE.md\n/.claude/\nCLAUDE.local.md\n.claude/settings.local.json\nCLAUDE.md.bak\n.claude/**/*.bak\n/CLAUDE.md\n' > "$T19/.gitignore"
OUT="$(bash "$INSTALL" --dry-run --no-color "$T19" 2>&1)" || fail "t19 dry-run exited non-zero"
assert_contains "t19 dry-run reports the glued line" "$OUT" "glued together"
OUT="$(bash "$INSTALL" -y --no-color "$T19" 2>&1)" || fail "t19 install exited non-zero"
assert_contains "t19 reports the glued line" "$OUT" "glued together"
assert_contains "t19 names the glued line"   "$OUT" '.env/CLAUDE.md'
assert_contains "t19 gives its line number"  "$OUT" "line 2 "
[ "$(count_lines "$T19/.gitignore" '.env/CLAUDE.md')" -eq 1 ] && ok || fail "t19 the glued line was modified"
T20="$TMP/t20"; mkdir -p "$T20"   # the same bug before v2.11.0
printf 'node_modules/\n.envCLAUDE.local.md\n.claude/settings.local.json\nCLAUDE.md.bak\n.claude/**/*.bak\n' > "$T20/.gitignore"
OUT="$(bash "$INSTALL" -y --no-color "$T20" 2>&1)" || fail "t20 install exited non-zero"
assert_contains "t20 reports the pre-2.11 glued line" "$OUT" '.envCLAUDE.local.md'
T35="$TMP/t35"; mkdir -p "$T35"   # …and at the release that first appended the .bak patterns
printf 'node_modules/\nCLAUDE.local.md\n.claude/settings.local.json\ndistCLAUDE.md.bak\n.claude/**/*.bak\n' > "$T35/.gitignore"
OUT="$(bash "$INSTALL" -y --no-color "$T35" 2>&1)" || fail "t35 install exited non-zero"
assert_contains "t35 reports the glued .bak line" "$OUT" 'distCLAUDE.md.bak'
T21="$TMP/t21"; mkdir -p "$T21"   # a clean v2.11.0 file must not warn
printf 'node_modules/\n/CLAUDE.md\n/.claude/\nCLAUDE.local.md\n.claude/settings.local.json\nCLAUDE.md.bak\n.claude/**/*.bak\n' > "$T21/.gitignore"
OUT="$(bash "$INSTALL" -y --no-color "$T21" 2>&1)" || fail "t21 install exited non-zero"
assert_not_contains "t21 clean file is not reported" "$OUT" "glued together"

# ---- 26b. a .gitignore that cannot be written is reported; the install still completes ----
if [ "$(id -u)" -ne 0 ]; then   # root ignores the read-only bit
  T33="$TMP/t33"; mkdir -p "$T33"
  printf 'keep-me\n/CLAUDE.md\n/.claude/\n' > "$T33/.gitignore"; chmod 444 "$T33/.gitignore"
  OUT="$(bash "$INSTALL" -y --no-color "$T33" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok || fail "t33 read-only .gitignore: expected exit 0, got $RC"
  assert_contains "t33 says .gitignore could not be written" "$OUT" "could not write .gitignore"
  assert_contains "t33 still reaches the summary" "$OUT" "baseline $VER"
  [ "$(cat "$T33/.gitignore")" = "$(printf 'keep-me\n/CLAUDE.md\n/.claude/')" ] && ok || fail "t33 a read-only .gitignore was changed"
  chmod 644 "$T33/.gitignore"
fi

# ---- 27–34. untrack: stop tracking a copy an earlier release had the repo commit ----
if [ "$HAVE_GIT" -eq 1 ]; then
  # 27. headless without a flag: the index is left alone and the exact command is printed
  T22="$TMP/t22"; baseline_repo "$T22" || fail "t22 fixture failed"
  OUT="$(bash "$INSTALL" --no-color "$T22" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok || fail "t22 headless install: expected exit 0, got $RC"
  assert_contains "t22 says the copy is still tracked" "$OUT" "still tracked"
  assert_contains "t22 prints the manual command" "$OUT" "rm -r --cached -- CLAUDE.md .claude"
  [ "$(tracked "$T22" CLAUDE.md .claude | wc -l)" -eq 5 ] && ok || fail "t22 headless run changed the index"

  # 28. -y untracks the root copy, keeps every file on disk and everything nested
  T23="$TMP/t23"; baseline_repo "$T23" || fail "t23 fixture failed"
  OUT="$(bash "$INSTALL" -y --no-color "$T23" 2>&1)" || fail "t23 install exited non-zero"
  [ -z "$(tracked "$T23" CLAUDE.md .claude)" ] && ok || fail "t23 root copy is still tracked"
  if [ -f "$T23/CLAUDE.md" ] && [ -f "$T23/.claude/verify-commands" ] && [ -f "$T23/.claude/skills/team/SKILL.md" ]; then
    ok
  else
    fail "t23 untracking removed files from disk"
  fi
  [ "$(tracked "$T23" pkg | wc -l)" -eq 2 ] && ok || fail "t23 nested pkg/ files were untracked too"
  assert_contains "t23 summary counts the untracked files" "$OUT" "untracked 5"
  assert_contains "t23 calls out the team's own skill" "$OUT" ".claude/skills/team/SKILL.md"
  printf '%s\n' "$OUT" | grep -qE '^ +\.claude/verify-commands$' && ok || fail "t23 does not call out the team's own verify-commands"
  STATUS="$(git -C "$T23" status --porcelain 2>/dev/null)"
  case "$STATUS" in *"D  CLAUDE.md"*) ok ;; *) fail "t23 the removal of CLAUDE.md is not staged" ;; esac
  if printf '%s\n' "$STATUS" | grep -qE '^\?\? (CLAUDE\.md|\.claude/)'; then
    fail "t23 the untracked copy is not ignored"
  else
    ok
  fi
  OUT="$(bash "$INSTALL" -y --no-color "$T23" 2>&1)" || fail "t23 re-install exited non-zero"
  assert_not_contains "t23 rerun has nothing left to untrack" "$OUT" "untrack"

  # 28b. --force untracks as well
  T24="$TMP/t24"; baseline_repo "$T24" || fail "t24 fixture failed"
  bash "$INSTALL" --force --no-color "$T24" >/dev/null 2>&1 || fail "t24 install exited non-zero"
  [ -z "$(tracked "$T24" CLAUDE.md .claude)" ] && ok || fail "t24 --force left the root copy tracked"

  # 29. --dry-run reports and changes nothing
  T25="$TMP/t25"; baseline_repo "$T25" || fail "t25 fixture failed"
  OUT="$(bash "$INSTALL" --dry-run --no-color "$T25" 2>&1)" || fail "t25 dry-run exited non-zero"
  assert_contains "t25 dry-run reports the untrack" "$OUT" "would untrack 5"
  [ "$(tracked "$T25" CLAUDE.md .claude | wc -l)" -eq 5 ] && ok || fail "t25 dry-run changed the index"

  # 30. a target that is a subdirectory of the repo: only its own copy is untracked
  T26="$TMP/t26"; mkrepo "$T26" || fail "t26 fixture failed"
  mkdir -p "$T26/app"; printf 'root\n' > "$T26/CLAUDE.md"; printf 'app\n' > "$T26/app/CLAUDE.md"
  track "$T26" "two copies" . || fail "t26 fixture commit failed"
  bash "$INSTALL" -y --no-color "$T26/app" >/dev/null 2>&1 || fail "t26 install exited non-zero"
  [ -z "$(tracked "$T26" app/CLAUDE.md)" ] && ok || fail "t26 the target's own CLAUDE.md is still tracked"
  [ -n "$(tracked "$T26" CLAUDE.md)" ] && ok || fail "t26 the parent repo's root CLAUDE.md was untracked"

  # 31. a target outside any repo: no untrack row at all
  T27="$TMP/t27"; mkdir -p "$T27"
  OUT="$(bash "$INSTALL" -y --no-color "$T27" 2>&1)" || fail "t27 install exited non-zero"
  assert_not_contains "t27 non-repo target" "$OUT" "untrack"

  # 32. git not on PATH: the install still succeeds and leaves the index alone
  T28="$TMP/t28"; baseline_repo "$T28" || fail "t28 fixture failed"
  NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
  for tool in bash dirname basename mkdir cmp mv cp cat grep head tail tr sed find sort chmod rm rmdir mktemp cut seq ls wc sha256sum shasum; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -s "$p" "$NOGIT/$tool"
  done
  OUT="$(PATH="$NOGIT" bash "$INSTALL" -y --no-color "$T28" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok || fail "t28 install without git: expected exit 0, got $RC"
  assert_not_contains "t28 no untrack without git" "$OUT" "untrack"
  [ "$(tracked "$T28" CLAUDE.md .claude | wc -l)" -eq 5 ] && ok || fail "t28 index changed although git was not on PATH"

  # 33. git refuses (staged content differs from both HEAD and the file): reported, never forced
  T29="$TMP/t29"; mkrepo "$T29" || fail "t29 fixture failed"
  mkdir -p "$T29/.claude"; printf 'v1\n' > "$T29/.claude/settings.json"
  track "$T29" "v1" .claude/settings.json || fail "t29 fixture commit failed"
  printf 'v2\n' > "$T29/.claude/settings.json"; git -C "$T29" add -f -- .claude/settings.json
  printf 'v3\n' > "$T29/.claude/settings.json"
  OUT="$(bash "$INSTALL" -y --no-color "$T29" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok || fail "t29 install after a refused untrack: expected exit 0, got $RC"
  assert_contains "t29 reports the refusal" "$OUT" "git refused"
  assert_contains "t29 prints the force command for the human" "$OUT" "rm -r --cached -f -- .claude"
  [ -n "$(tracked "$T29" .claude)" ] && ok || fail "t29 a refused untrack still changed the index"
  assert_not_contains "t29 summary counts nothing" "$OUT" "untracked 1"

  # 34. merge in progress: skipped even with -y, so staged removals never join the merge commit
  T30="$TMP/t30"; mkrepo "$T30" || fail "t30 fixture failed"
  printf 'old\n' > "$T30/CLAUDE.md"; printf 'x\n' > "$T30/f.txt"; track "$T30" "base" CLAUDE.md f.txt
  git -C "$T30" checkout -q -b side 2>/dev/null; printf 'side\n' > "$T30/g.txt"; track "$T30" "side" g.txt
  git -C "$T30" checkout -q - 2>/dev/null;       printf 'main\n' > "$T30/h.txt"; track "$T30" "main" h.txt
  git -C "$T30" -c commit.gpgsign=false merge -q --no-ff --no-commit side >/dev/null 2>&1
  [ -e "$T30/.git/MERGE_HEAD" ] && ok || fail "t30 fixture: no merge in progress"
  OUT="$(bash "$INSTALL" -y --no-color "$T30" 2>&1)" || fail "t30 install exited non-zero"
  assert_contains "t30 names the operation in progress" "$OUT" "merge in progress"
  [ -n "$(tracked "$T30" CLAUDE.md)" ] && ok || fail "t30 untracked during a merge"
fi

# ---- 35. rules/ui.md left the baseline in v2.12.0: a shipped copy goes, an edited one stays ----
UI_FIXTURE="$ROOT/tests/fixtures/legacy/rules-ui-v2.11.0.md"   # byte-identical to what v2.11.0 installed
[ ! -e "$T1/.claude/rules/ui.md" ] && ok || fail "a fresh install still ships rules/ui.md"
T31="$TMP/t31"; mkdir -p "$T31"
bash "$INSTALL" -y --no-color "$T31" >/dev/null 2>&1 || fail "t31 install exited non-zero"
cp "$UI_FIXTURE" "$T31/.claude/rules/ui.md"
OUT="$(bash "$INSTALL" --dry-run --no-color "$T31" 2>&1)" || fail "t31 dry-run exited non-zero"
assert_contains "t31 dry-run reports the removal" "$OUT" "remove    .claude/rules/ui.md"
[ -f "$T31/.claude/rules/ui.md" ] && ok || fail "t31 dry-run removed ui.md"
bash "$INSTALL" -y --no-color "$T31" >/dev/null 2>&1 || fail "t31 update exited non-zero"
[ ! -e "$T31/.claude/rules/ui.md" ] && ok || fail "t31 a shipped ui.md survived the update"
cp "$UI_FIXTURE" "$T31/.claude/rules/ui.md"; printf 'my own rule\n' >> "$T31/.claude/rules/ui.md"
OUT="$(bash "$INSTALL" -y --no-color "$T31" 2>&1)" || fail "t31 second update exited non-zero"
assert_contains "t31 says it kept the edited file" "$OUT" "keep      .claude/rules/ui.md"
grep -qxF 'my own rule' "$T31/.claude/rules/ui.md" && ok || fail "t31 a user-edited ui.md was removed or overwritten"
T32="$TMP/t32"; mkdir -p "$T32"
bash "$INSTALL" -y --no-color "$T32" >/dev/null 2>&1 || fail "t32 install exited non-zero"
cp "$UI_FIXTURE" "$T32/.claude/rules/ui.md"
bash "$INSTALL" --uninstall -y --no-color "$T32" >/dev/null 2>&1 || fail "t32 uninstall exited non-zero"
[ ! -d "$T32/.claude" ] && ok || fail "t32 uninstall left a shipped legacy ui.md behind"

# every version of rules/ui.md the baseline ever shipped must be in install.sh's legacy list
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
UI_KNOWN=" $(grep -F '".claude/rules/ui.md")' "$INSTALL" | grep -oE '[0-9a-f]{64}' | tr '\n' ' ')"
case "$UI_KNOWN" in *" $(sha256_of < "$UI_FIXTURE") "*) ok ;; *) fail "the v2.11.0 ui.md is not in legacy_sha" ;; esac
if [ "$HAVE_GIT" -eq 1 ] && [ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ]; then
  MISSING=""
  for c in $(git -C "$ROOT" rev-list HEAD -- src/rules/ui.md .claude/rules/ui.md 2>/dev/null); do
    for p in src/rules/ui.md .claude/rules/ui.md; do
      b="$(git -C "$ROOT" rev-parse -q --verify "$c:$p" 2>/dev/null)" || continue
      h="$(git -C "$ROOT" cat-file blob "$b" | sha256_of)"
      case "$UI_KNOWN" in *" $h "*) ;; *) MISSING="$MISSING $h" ;; esac
    done
  done
  [ -z "$MISSING" ] && ok || fail "legacy_sha misses shipped ui.md version(s):$MISSING"
fi

printf 'install-version-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
