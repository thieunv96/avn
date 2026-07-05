#!/usr/bin/env bash
# install.sh — install the Claude Code baseline into a target repo.
#
# Copies CLAUDE.md + .claude/{rules,hooks,skills,agents,settings.json} and
# .claude/verify-commands.example into TARGET_DIR. settings.json ships as-is:
# its hook commands already use ${CLAUDE_PROJECT_DIR}, so the baseline is fully
# self-contained per repo (no rewrite step). A real .claude/verify-commands is
# never installed — enabling the verify gate is a per-repo opt-in.
#
# Versioning: the baseline's version lives in the VERSION file next to this
# script. Each install writes a stamp to TARGET_DIR/.claude/avn-version
# (version + source; meant to be committed) and the header/summary show the
# old → new version. AVN_REF accepts a branch or a tag (e.g. v2.1.0).
#
# Two ways to run:
#   • From a clone:   ./install.sh [TARGET_DIR]
#   • Without a clone (downloads itself from GitHub):
#         curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash -s -- [TARGET_DIR]
#
# Env overrides for the download source: AVN_REPO (default thieunv96/avn), AVN_REF (default master).

set -euo pipefail

DRY_RUN=0
FORCE=0
ASSUME_YES=0
BACKUP_OPT=""          # "", "yes", or "no"
NO_COLOR_FLAG=0
TARGET=""
AVN_REPO="${AVN_REPO:-thieunv96/avn}"
AVN_REF="${AVN_REF:-master}"
DL_DIR=""

N_CREATE=0; N_UPDATE=0; N_UNCHANGED=0; N_BACKUP=0; N_REMOVE=0

usage() {
  cat <<'EOF'
Install the Claude Code baseline into a target repo.

Usage:
  install.sh [options] [TARGET_DIR]
  curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash -s -- [options] [TARGET_DIR]

  TARGET_DIR     Target repository directory (default: current directory).

Options:
  --dry-run      Show what would happen; change nothing.
  --backup       Back up overwritten files to <file>.bak (no prompt).
  --no-backup    Overwrite without backups (no prompt).
  -y, --yes      Don't prompt; use defaults (backup = yes).
  --force        Overwrite without backups and without any prompt.
  --no-color     Disable colored output.
  -h, --help     Show this help.

When a file would be overwritten and no backup choice was given, you get an
interactive menu (default: back up). Non-interactive runs back up by default.

Env:
  AVN_REPO       GitHub owner/repo to fetch when run without a clone (default: thieunv96/avn).
  AVN_REF        Branch or tag to fetch, e.g. master or v2.1.0 (default: master).

Installs CLAUDE.md, .claude/rules/*.md, .claude/skills/** (brainstorm,
code-review, verify), .claude/agents/*.md (if any), the hooks bash-guard.sh,
file-guard.sh and verify-gate.sh (executable), .claude/verify-commands.example, and
.claude/settings.json (shipped as-is; hook paths use ${CLAUDE_PROJECT_DIR}).
Also writes the baseline version to .claude/avn-version (commit this stamp so
the whole team can see which baseline the repo runs).
EOF
}

# ---- Parse args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --backup)    BACKUP_OPT="yes" ;;
    --no-backup) BACKUP_OPT="no" ;;
    -y|--yes)    ASSUME_YES=1 ;;
    --force)     FORCE=1 ;;
    --rollback)  ;;          # deprecated no-op: reconcile/cleanup now runs on every install
    --no-color)  NO_COLOR_FLAG=1 ;;
    -h|--help)   usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$TARGET" ]; then echo "Error: multiple target dirs given." >&2; exit 2; fi
      TARGET="$1" ;;
  esac
  shift
done
if [ $# -gt 0 ] && [ -z "$TARGET" ]; then TARGET="$1"; fi

# ---- Colors / TTY ----
USE_COLOR=1
{ [ "$NO_COLOR_FLAG" -eq 1 ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; } && USE_COLOR=0
if [ "$USE_COLOR" -eq 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; BLU=$'\033[34m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=; DIM=; RED=; GRN=; YLW=; BLU=; CYN=; RST=
fi
HAVE_TTY=0
{ [ -r /dev/tty ] && [ -t 1 ]; } && HAVE_TTY=1

note() { printf '%s\n' "$*"; }
abspath() { (cd "$1" 2>/dev/null && pwd); }
rel()  { printf '%s' "${1#"$TARGET_ABS"/}"; }

# line COLOR SYMBOL VERB DETAIL  — aligned, colored status row
line() {
  local v; printf -v v '%-9s' "$3"
  printf '  %b%s %s%b %s\n' "$1" "$2" "$v" "$RST" "$4"
}

cleanup() {
  [ -n "$DL_DIR" ] && [ -d "$DL_DIR" ] && rm -rf "$DL_DIR"
  return 0
}
trap cleanup EXIT

# ---- Arrow-key selection menu (Gemini-CLI style), drawn on /dev/tty ----
# menu_select "question" "option0" "option1" ...   -> sets MENU_CHOICE (0-based)
MENU_CHOICE=0
menu_select() {
  local q="$1"; shift
  local opts=("$@") n=$# sel=0 i key rest saved
  if [ "$HAVE_TTY" -ne 1 ]; then MENU_CHOICE=0; return 0; fi

  printf '\n  %b?%b %b%s%b\n' "$CYN$BOLD" "$RST" "$BOLD" "$q" "$RST" > /dev/tty
  saved="$(stty -g < /dev/tty 2>/dev/null || true)"
  stty -echo -icanon time 0 min 1 < /dev/tty 2>/dev/null || true
  printf '\033[?25l' > /dev/tty   # hide cursor

  _draw() {
    for i in $(seq 0 $((n-1))); do
      if [ "$i" -eq "$sel" ]; then
        printf '\r\033[K  %b❯ %s%b\n' "$GRN$BOLD" "${opts[$i]}" "$RST" > /dev/tty
      else
        printf '\r\033[K    %b%s%b\n' "$DIM" "${opts[$i]}" "$RST" > /dev/tty
      fi
    done
  }
  _draw
  while true; do
    IFS= read -rsn1 key < /dev/tty || key=""
    case "$key" in
      $'\033') read -rsn2 -t 1 rest < /dev/tty || rest=""
               case "$rest" in '[A') sel=$(((sel-1+n)%n));; '[B') sel=$(((sel+1)%n));; esac ;;
      k|K)     sel=$(((sel-1+n)%n)) ;;
      j|J)     sel=$(((sel+1)%n)) ;;
      '')      break ;;   # Enter
    esac
    printf '\033[%dA' "$n" > /dev/tty
    _draw
  done

  printf '\033[%dA\r\033[J' "$n" > /dev/tty       # collapse the menu
  printf '  %b✓%b %s\n' "$GRN" "$RST" "${opts[$sel]}" > /dev/tty
  printf '\033[?25h' > /dev/tty                    # show cursor
  [ -n "$saved" ] && stty "$saved" < /dev/tty 2>/dev/null || true
  MENU_CHOICE=$sel
}

# install_file SRC_FILE DEST_FILE  (uses DO_BACKUP, DRY_RUN)
install_file() {
  local s="$1" d="$2" r; r="$(rel "$d")"
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$(dirname "$d")"
  if [ -f "$d" ]; then
    if cmp -s "$s" "$d"; then
      line "$DIM" "=" "unchanged" "$r"; N_UNCHANGED=$((N_UNCHANGED+1)); return 0
    fi
    if [ "$DO_BACKUP" -eq 1 ]; then
      line "$BLU" "⤴" "backup" "$r $DIM→$RST $r.bak"
      [ "$DRY_RUN" -eq 1 ] || mv -f "$d" "$d.bak"
      N_BACKUP=$((N_BACKUP+1))
    fi
    line "$YLW" "~" "update" "$r"; N_UPDATE=$((N_UPDATE+1))
  else
    line "$GRN" "+" "create" "$r"; N_CREATE=$((N_CREATE+1))
  fi
  [ "$DRY_RUN" -eq 1 ] || cp "$s" "$d"
}

# ---- Resolve target ----
TARGET="${TARGET:-$PWD}"
if [ ! -d "$TARGET" ]; then
  printf '%b✗%b target directory does not exist: %s\n' "$RED" "$RST" "$TARGET" >&2; exit 1
fi
TARGET_ABS="$(abspath "$TARGET")"

# ---- Resolve baseline source: local script dir if it has the files, else download ----
SELF_DIR=""
case "${BASH_SOURCE[0]:-}" in
  ""|bash|sh|/dev/*|/proc/*) SELF_DIR="" ;;
  *) SELF_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)" ;;
esac

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/CLAUDE.md" ] && [ -f "$SELF_DIR/.claude/settings.json" ]; then
  SRC="$SELF_DIR"; SRC_DESC="local: $SRC"
else
  command -v tar >/dev/null 2>&1 || { printf '%b✗%b need "tar" to download the baseline\n' "$RED" "$RST" >&2; exit 1; }
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || { printf '%b✗%b need "curl" or "wget" to download the baseline\n' "$RED" "$RST" >&2; exit 1; }
  DL_DIR="$(mktemp -d)"
  fetch() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    else wget -qO "$2" "$1"
    fi
  }
  printf '  %b⇣%b downloading %s@%s ...\n' "$CYN" "$RST" "$AVN_REPO" "$AVN_REF"
  # AVN_REF may be a branch or a tag — codeload uses a different path for each.
  if ! fetch "https://codeload.github.com/${AVN_REPO}/tar.gz/refs/heads/${AVN_REF}" "$DL_DIR/baseline.tgz" 2>/dev/null; then
    fetch "https://codeload.github.com/${AVN_REPO}/tar.gz/refs/tags/${AVN_REF}" "$DL_DIR/baseline.tgz" \
      || { printf '%b✗%b download failed: network error, or no branch/tag "%s" in %s\n' "$RED" "$RST" "$AVN_REF" "$AVN_REPO" >&2; exit 1; }
  fi
  tar -xzf "$DL_DIR/baseline.tgz" -C "$DL_DIR" || { printf '%b✗%b failed to extract baseline archive\n' "$RED" "$RST" >&2; exit 1; }
  SRC=""
  for d in "$DL_DIR"/*/; do SRC="${d%/}"; break; done
  SRC_DESC="remote: ${AVN_REPO}@${AVN_REF}"
fi

if [ "$TARGET_ABS" = "$SRC" ]; then
  printf '%b✗%b target is the baseline source itself (%s). Choose another repo.\n' "$RED" "$RST" "$SRC" >&2; exit 1
fi
for f in "CLAUDE.md" ".claude/settings.json" ".claude/hooks/bash-guard.sh" ".claude/hooks/file-guard.sh" ".claude/hooks/verify-gate.sh"; do
  if [ -z "${SRC:-}" ] || [ ! -f "$SRC/$f" ]; then
    printf '%b✗%b baseline source is missing %s\n' "$RED" "$RST" "$f" >&2; exit 1
  fi
done

# ---- Version bookkeeping ----
STAMP="$TARGET_ABS/.claude/avn-version"
NEW_VER="unknown"
[ -f "$SRC/VERSION" ] && NEW_VER="$(head -n1 "$SRC/VERSION" | tr -d '[:space:]')"
OLD_VER=""
[ -f "$STAMP" ] && OLD_VER="$(sed -n 's/^version=//p' "$STAMP" | head -n1)"

# ---- Build the file plan ----
# settings.json ships as-is: hook commands already use ${CLAUDE_PROJECT_DIR}.
# The deny rules Read/Edit(~/.claude/**) intentionally point at the user's HOME
# and must never be rewritten — they protect the user's global config.
SRCS=(); DESTS=()
add_pair() { SRCS+=("$1"); DESTS+=("$2"); }
add_pair "$SRC/CLAUDE.md" "$TARGET_ABS/CLAUDE.md"
for r in "$SRC"/.claude/rules/*.md; do
  [ -e "$r" ] || continue
  add_pair "$r" "$TARGET_ABS/.claude/rules/$(basename "$r")"
done
for a in "$SRC"/.claude/agents/*.md; do
  [ -e "$a" ] || continue
  add_pair "$a" "$TARGET_ABS/.claude/agents/$(basename "$a")"
done
if [ -d "$SRC/.claude/skills" ]; then
  while IFS= read -r sk; do
    add_pair "$sk" "$TARGET_ABS/${sk#"$SRC"/}"
  done < <(find "$SRC/.claude/skills" -type f | sort)
fi
add_pair "$SRC/.claude/hooks/bash-guard.sh" "$TARGET_ABS/.claude/hooks/bash-guard.sh"
add_pair "$SRC/.claude/hooks/file-guard.sh" "$TARGET_ABS/.claude/hooks/file-guard.sh"
add_pair "$SRC/.claude/hooks/verify-gate.sh" "$TARGET_ABS/.claude/hooks/verify-gate.sh"
add_pair "$SRC/.claude/verify-commands.example" "$TARGET_ABS/.claude/verify-commands.example"
add_pair "$SRC/.claude/settings.json" "$TARGET_ABS/.claude/settings.json"

# ---- Header ----
printf '\n%b▸ Claude Code baseline%b\n' "$BOLD" "$RST"
printf '  %ssource%s  %s\n' "$DIM" "$RST" "$SRC_DESC"
printf '  %starget%s  %s\n' "$DIM" "$RST" "$TARGET_ABS"
if [ -z "$OLD_VER" ]; then
  printf '  %sversion%s %s (new install)\n' "$DIM" "$RST" "$NEW_VER"
elif [ "$OLD_VER" = "$NEW_VER" ]; then
  printf '  %sversion%s %s (unchanged)\n' "$DIM" "$RST" "$NEW_VER"
else
  printf '  %sversion%s %s → %s\n' "$DIM" "$RST" "$OLD_VER" "$NEW_VER"
fi
[ "$DRY_RUN" -eq 1 ] && printf '  %b(dry-run — no changes will be made)%b\n' "$YLW" "$RST"

# ---- Decide backup policy ----
overwrite_n=0
for i in "${!DESTS[@]}"; do
  if [ -f "${DESTS[$i]}" ] && ! cmp -s "${SRCS[$i]}" "${DESTS[$i]}"; then
    overwrite_n=$((overwrite_n+1))
  fi
done

DO_BACKUP=1
if   [ "$FORCE" -eq 1 ];           then DO_BACKUP=0
elif [ "$BACKUP_OPT" = "yes" ];    then DO_BACKUP=1
elif [ "$BACKUP_OPT" = "no" ];     then DO_BACKUP=0
elif [ "$ASSUME_YES" -eq 1 ];      then DO_BACKUP=1
elif [ "$overwrite_n" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ "$HAVE_TTY" -eq 1 ]; then
    menu_select "$overwrite_n file(s) already exist. Back them up before overwriting?" \
                "Yes — back up each to <file>.bak  (recommended)" \
                "No  — overwrite without a backup"
    [ "$MENU_CHOICE" -eq 0 ] && DO_BACKUP=1 || DO_BACKUP=0
  else
    DO_BACKUP=1
    printf '  %b⚠%b non-interactive: backing up overwritten files by default (use --no-backup to skip)\n' "$YLW" "$RST"
  fi
fi

printf '\n'

# ---- Apply ----
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$TARGET_ABS/.claude/rules" "$TARGET_ABS/.claude/hooks"
for i in "${!DESTS[@]}"; do
  install_file "${SRCS[$i]}" "${DESTS[$i]}"
done
[ "$DRY_RUN" -eq 1 ] || chmod +x "$TARGET_ABS/.claude/hooks/bash-guard.sh" \
                                 "$TARGET_ABS/.claude/hooks/file-guard.sh" \
                                 "$TARGET_ABS/.claude/hooks/verify-gate.sh"

# ---- Version stamp (written directly, not via install_file: a stamp never
# needs a .bak and must not trigger the backup prompt) ----
STAMP_SOURCE="${AVN_SOURCE:-}"
if [ -z "$STAMP_SOURCE" ]; then
  case "$SRC_DESC" in
    remote:*) STAMP_SOURCE="${AVN_REPO}@${AVN_REF}" ;;
    *)        STAMP_SOURCE="local" ;;
  esac
fi
STAMP_CONTENT="# Claude Code baseline — written by install.sh; do not edit by hand.
version=$NEW_VER
source=$STAMP_SOURCE"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$STAMP_CONTENT" ]; then
  line "$DIM" "=" "unchanged" ".claude/avn-version"; N_UNCHANGED=$((N_UNCHANGED+1))
else
  if [ -z "$OLD_VER" ]; then
    line "$GRN" "+" "create" ".claude/avn-version ($NEW_VER)"; N_CREATE=$((N_CREATE+1))
  elif [ "$OLD_VER" != "$NEW_VER" ]; then
    line "$YLW" "~" "update" ".claude/avn-version ($OLD_VER → $NEW_VER)"; N_UPDATE=$((N_UPDATE+1))
  else
    line "$YLW" "~" "update" ".claude/avn-version (source changed)"; N_UPDATE=$((N_UPDATE+1))
  fi
  [ "$DRY_RUN" -eq 1 ] || { mkdir -p "$TARGET_ABS/.claude"; printf '%s\n' "$STAMP_CONTENT" > "$STAMP"; }
fi

# .gitignore — append Claude lines when missing (creates the file if absent)
GI="$TARGET_ABS/.gitignore"
for ln in "CLAUDE.local.md" ".claude/settings.local.json"; do
  if [ ! -f "$GI" ] || ! grep -qxF "$ln" "$GI"; then
    line "$CYN" "✎" "gitignore" "+= $ln"
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$ln" >> "$GI"
  fi
done

# ---- Reconcile: remove files the baseline has dropped (legacy research workflow) ----
# Runs on every install so an older install is brought exactly up to date. A file is removed
# only when (a) it is in the target but NOT in the current baseline source, AND (b) its sha256
# matches the exact content the old baseline shipped (commit 6d5418d) — a same-named file with
# different content is user-made and is kept. If the baseline ever ships these paths again, the
# [ ! -e "$SRC/$rf" ] guard keeps them (the copy loop above installs them).
legacy_sha() {
  case "$1" in
    ".claude/agents/impact-research.md")   echo "3166e8b7a972aade3c4655b251787097eac0b308071a2579814b5915563e02ea" ;;
    ".claude/agents/security-research.md") echo "22f3cba74273063f96379b8bb815a1e0a24f10d5a9c07f489fe6f31d6fa71d50" ;;
    ".claude/skills/research/SKILL.md")    echo "b0d09c2604255b285d7463299a88810e9a1670105ecced47d7076332c06eb2c7" ;;
  esac
}
file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo "unavailable"; fi   # never matches a real hash -> file is kept (safe direction)
}
for rf in ".claude/agents/impact-research.md" \
          ".claude/agents/security-research.md" \
          ".claude/skills/research/SKILL.md"; do
  if [ -f "$TARGET_ABS/$rf" ] && [ ! -e "$SRC/$rf" ]; then
    if [ "$(file_sha "$TARGET_ABS/$rf")" = "$(legacy_sha "$rf")" ]; then
      line "$RED" "-" "remove" "$rf"
      [ "$DRY_RUN" -eq 1 ] || rm -f "$TARGET_ABS/$rf"
      N_REMOVE=$((N_REMOVE+1))
    else
      line "$YLW" "⚠" "keep" "$rf (same name as a dropped baseline file but content differs — looks user-made)"
    fi
  fi
done
# prune legacy dirs only if now empty (rmdir refuses non-empty dirs — never touches user files)
[ "$DRY_RUN" -eq 1 ] || rmdir "$TARGET_ABS/.claude/skills/research" \
  "$TARGET_ABS/.claude/agents" 2>/dev/null || true

# ---- Summary ----
printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  printf '%b▸ dry-run complete%b — nothing was changed.\n' "$BOLD$YLW" "$RST"
else
  printf '%b✓ done%b  %sbaseline %s · created %d · updated %d · unchanged %d' "$BOLD$GRN" "$RST" "$DIM" "$NEW_VER" "$N_CREATE" "$N_UPDATE" "$N_UNCHANGED"
  [ "$N_BACKUP" -gt 0 ] && printf ' · backed up %d' "$N_BACKUP"
  [ "$N_REMOVE" -gt 0 ] && printf ' · removed %d' "$N_REMOVE"
  printf '%b\n' "$RST"
fi
printf '  %bnext%b open Claude Code here and run %b/permissions%b to review the rules.\n' "$DIM" "$RST" "$CYN" "$RST"
