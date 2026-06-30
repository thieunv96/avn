#!/usr/bin/env bash
# install.sh — install the Asilla Claude Code baseline into a target repo.
#
# Copies CLAUDE.md + .claude/{rules,hooks,settings.json} into TARGET_DIR and
# rewrites the hook command to be project-relative (${CLAUDE_PROJECT_DIR}) so the
# baseline is fully self-contained per repo.
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
ROLLBACK=0
TARGET=""
AVN_REPO="${AVN_REPO:-thieunv96/avn}"
AVN_REF="${AVN_REF:-master}"
DL_DIR=""
TMP_SETTINGS=""

N_CREATE=0; N_UPDATE=0; N_UNCHANGED=0; N_BACKUP=0; N_REMOVE=0

usage() {
  cat <<'EOF'
Install the Asilla Claude Code baseline into a target repo.

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
  --rollback     Roll back: reinstall the baseline, then remove the research-workflow files
                 (.claude/agents/{impact,security}-research.md, .claude/skills/research/).
  --no-color     Disable colored output.
  -h, --help     Show this help.

When a file would be overwritten and no backup choice was given, you get an
interactive menu (default: back up). Non-interactive runs back up by default.

Env:
  AVN_REPO       GitHub owner/repo to fetch when run without a clone (default: thieunv96/avn).
  AVN_REF        Branch or tag to fetch (default: master).

Installs CLAUDE.md, .claude/rules/*.md, .claude/hooks/bash-guard.sh (executable),
and .claude/settings.json (hook path rewritten to ${CLAUDE_PROJECT_DIR}).
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
    --rollback)  ROLLBACK=1 ;;
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
  [ -n "$TMP_SETTINGS" ] && [ -f "$TMP_SETTINGS" ] && rm -f "$TMP_SETTINGS"
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
  DL_DIR="$(mktemp -d)"
  URL="https://codeload.github.com/${AVN_REPO}/tar.gz/refs/heads/${AVN_REF}"
  printf '  %b⇣%b downloading %s@%s ...\n' "$CYN" "$RST" "$AVN_REPO" "$AVN_REF"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$DL_DIR/baseline.tgz" || { printf '%b✗%b download failed: %s\n' "$RED" "$RST" "$URL" >&2; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$DL_DIR/baseline.tgz" "$URL" || { printf '%b✗%b download failed: %s\n' "$RED" "$RST" "$URL" >&2; exit 1; }
  else
    printf '%b✗%b need "curl" or "wget" to download the baseline\n' "$RED" "$RST" >&2; exit 1
  fi
  tar -xzf "$DL_DIR/baseline.tgz" -C "$DL_DIR" || { printf '%b✗%b failed to extract baseline archive\n' "$RED" "$RST" >&2; exit 1; }
  SRC=""
  for d in "$DL_DIR"/*/; do SRC="${d%/}"; break; done
  SRC_DESC="remote: ${AVN_REPO}@${AVN_REF}"
fi

if [ "$TARGET_ABS" = "$SRC" ]; then
  printf '%b✗%b target is the baseline source itself (%s). Choose another repo.\n' "$RED" "$RST" "$SRC" >&2; exit 1
fi
for f in "CLAUDE.md" ".claude/settings.json" ".claude/hooks/bash-guard.sh"; do
  if [ -z "${SRC:-}" ] || [ ! -f "$SRC/$f" ]; then
    printf '%b✗%b baseline source is missing %s\n' "$RED" "$RST" "$f" >&2; exit 1
  fi
done

# ---- Prepare the rewritten settings.json (hook path -> project-relative) ----
# Only the hook command is rewritten. The deny rules Edit(~/.claude/settings.json) and
# Edit(~/.claude/hooks/**) are intentionally left as-is — they protect the user's global config.
TMP_SETTINGS="$(mktemp)"
sed 's#~/\.claude/hooks/bash-guard\.sh#${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-guard.sh#g' \
    "$SRC/.claude/settings.json" > "$TMP_SETTINGS"
if ! grep -qF '${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-guard.sh' "$TMP_SETTINGS"; then
  printf '%b⚠%b could not rewrite the hook path in settings.json — verify it after install.\n' "$YLW" "$RST" >&2
fi

# ---- Build the file plan ----
SRCS=(); DESTS=()
add_pair() { SRCS+=("$1"); DESTS+=("$2"); }
add_pair "$SRC/CLAUDE.md" "$TARGET_ABS/CLAUDE.md"
for r in "$SRC"/.claude/rules/*.md; do
  [ -e "$r" ] || continue
  add_pair "$r" "$TARGET_ABS/.claude/rules/$(basename "$r")"
done
add_pair "$SRC/.claude/hooks/bash-guard.sh" "$TARGET_ABS/.claude/hooks/bash-guard.sh"
add_pair "$TMP_SETTINGS" "$TARGET_ABS/.claude/settings.json"

# ---- Header ----
printf '\n%b▸ Asilla Claude Code baseline%b\n' "$BOLD" "$RST"
printf '  %ssource%s  %s\n' "$DIM" "$RST" "$SRC_DESC"
printf '  %starget%s  %s\n' "$DIM" "$RST" "$TARGET_ABS"
[ "$DRY_RUN" -eq 1 ] && printf '  %b(dry-run — no changes will be made)%b\n' "$YLW" "$RST"
[ "$ROLLBACK" -eq 1 ] && printf '  %brollback — research-workflow files will be removed after install%b\n' "$YLW" "$RST"

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
[ "$DRY_RUN" -eq 1 ] || chmod +x "$TARGET_ABS/.claude/hooks/bash-guard.sh"

# .gitignore — append Claude lines only if the file already exists and is missing them
GI="$TARGET_ABS/.gitignore"
if [ -f "$GI" ]; then
  for ln in "CLAUDE.local.md" ".claude/settings.local.json"; do
    if ! grep -qxF "$ln" "$GI"; then
      line "$CYN" "✎" "gitignore" "+= $ln"
      [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$ln" >> "$GI"
    fi
  done
fi

# ---- Rollback: remove research-workflow files a previous version installed ----
if [ "$ROLLBACK" -eq 1 ]; then
  for rf in ".claude/agents/impact-research.md" \
            ".claude/agents/security-research.md" \
            ".claude/skills/research/SKILL.md"; do
    if [ -f "$TARGET_ABS/$rf" ]; then
      line "$RED" "-" "remove" "$rf"
      [ "$DRY_RUN" -eq 1 ] || rm -f "$TARGET_ABS/$rf"
      N_REMOVE=$((N_REMOVE+1))
    fi
  done
  # prune dirs only if now empty (rmdir refuses non-empty dirs — never touches user files)
  [ "$DRY_RUN" -eq 1 ] || rmdir "$TARGET_ABS/.claude/skills/research" \
    "$TARGET_ABS/.claude/skills" "$TARGET_ABS/.claude/agents" 2>/dev/null || true
fi

# ---- Summary ----
printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$ROLLBACK" -eq 1 ]; then
    printf '%b▸ dry-run complete%b — nothing was written or removed.\n' "$BOLD$YLW" "$RST"
  else
    printf '%b▸ dry-run complete%b — nothing was written.\n' "$BOLD$YLW" "$RST"
  fi
else
  printf '%b✓ done%b  %screated %d · updated %d · unchanged %d' "$BOLD$GRN" "$RST" "$DIM" "$N_CREATE" "$N_UPDATE" "$N_UNCHANGED"
  [ "$N_BACKUP" -gt 0 ] && printf ' · backed up %d' "$N_BACKUP"
  [ "$N_REMOVE" -gt 0 ] && printf ' · removed %d' "$N_REMOVE"
  printf '%b\n' "$RST"
fi
printf '  %bnext%b open Claude Code here and run %b/permissions%b to review the rules.\n' "$DIM" "$RST" "$CYN" "$RST"
