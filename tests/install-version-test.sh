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
grep -qxF 'CLAUDE.md.bak'      "$T1/.gitignore" && ok || fail "t1 gitignore missing CLAUDE.md.bak"
grep -qxF '.claude/**/*.bak'   "$T1/.gitignore" && ok || fail "t1 gitignore missing .claude/**/*.bak"
# src/ → .claude/ mapping sanity: installed copies are byte-identical to the sources
cmp -s "$ROOT/src/hooks/bash-guard.sh" "$T1/.claude/hooks/bash-guard.sh" && ok || fail "t1 hook mapping mismatch (bash-guard)"
cmp -s "$ROOT/src/settings.json"       "$T1/.claude/settings.json"       && ok || fail "t1 settings mapping mismatch"
cmp -s "$ROOT/src/CLAUDE.md"           "$T1/CLAUDE.md"                   && ok || fail "t1 CLAUDE.md mapping mismatch"
cmp -s "$ROOT/src/skills/verify/SKILL.md" "$T1/.claude/skills/verify/SKILL.md" && ok || fail "t1 skills mapping mismatch"

# ---- 2. re-run: stamp unchanged, no .bak for the stamp ----
OUT="$(bash "$INSTALL" -y --no-color "$T1" 2>&1)" || fail "t1 re-install exited non-zero"
assert_contains "t1 rerun header" "$OUT" "$VER (unchanged)"
assert_contains "t1 rerun stamp" "$OUT" "unchanged .claude/avn-version"
[ ! -f "$T1/$STAMP_REL.bak" ] && ok || fail "t1 rerun created a stamp .bak"

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
assert_contains "check outdated" "$OUT" "outdated — installed 0.0.1 · latest $VER"

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

printf 'install-version-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
