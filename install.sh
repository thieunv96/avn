#!/usr/bin/env bash
# install.sh — install the ThieuNV Claude Code baseline into a target repo.
#
# Sources live under src/ (src/CLAUDE.md, src/settings.json, src/hooks/,
# src/rules/, src/skills/, src/agents/, src/verify-commands.example) and are
# installed as TARGET_DIR/CLAUDE.md + TARGET_DIR/.claude/** — the installed
# layout is unchanged from earlier releases. The src/ dir deliberately has no
# ".claude" path segment so the guard hooks never block editing the sources,
# while the installed copies stay protected. settings.json ships as-is: its
# hook commands already use ${CLAUDE_PROJECT_DIR}, so the baseline is fully
# self-contained per repo (no rewrite step). A real .claude/verify-commands is
# never installed — enabling the verify gate is a per-repo opt-in.
#
# Installing INTO a baseline source repo (a target that has src/ + install.sh)
# refreshes that repo's own installed copy — its RUNNING guard — and therefore
# requires an interactive terminal plus an explicit confirmation; no flag
# bypasses that (--dry-run stays allowed headless).
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
UNINSTALL=0
BACKUP_OPT=""          # "", "yes", or "no"
NO_COLOR_FLAG=0
TARGET=""
AVN_REPO="${AVN_REPO:-thieunv96/avn}"
AVN_REF="${AVN_REF:-master}"
DL_DIR=""

N_CREATE=0; N_UPDATE=0; N_UNCHANGED=0; N_BACKUP=0; N_REMOVE=0

usage() {
  cat <<'EOF'
Install the ThieuNV Claude Code baseline into a target repo.

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
  --uninstall    Remove the baseline from TARGET_DIR instead of installing:
                 deletes only files byte-identical to the shipped release
                 (modified files are kept with a warning; your own files such
                 as .claude/verify-commands are never touched), removes the
                 gitignore lines the installer appended, prunes empty .claude
                 dirs. Non-interactive runs need -y. Preview with --dry-run.
  --no-color     Disable colored output.
  -h, --help     Show this help.

When a file would be overwritten and no backup choice was given, you get an
interactive menu (default: back up). Non-interactive runs back up by default.

Env:
  AVN_REPO       GitHub owner/repo to fetch when run without a clone (default: thieunv96/avn).
  AVN_REF        Branch or tag to fetch, e.g. master or v2.1.0 (default: master).

Installs (from the src/ tree of the baseline) CLAUDE.md, .claude/rules/*.md,
.claude/skills/** (brainstorm, map, code-review, verify), .claude/agents/*.md
(if any), the hooks bash-guard.sh, file-guard.sh and verify-gate.sh (executable),
.claude/verify-commands.example, and .claude/settings.json (shipped as-is;
hook paths use ${CLAUDE_PROJECT_DIR}). Also writes the baseline version to
.claude/avn-version (commit this stamp so the whole team can see which
baseline the repo runs).

When TARGET_DIR is itself a baseline source repo (it has src/ + install.sh),
the install refreshes that repo's own installed copy — its running guard —
and requires an interactive terminal plus confirmation. No flag bypasses
this; --dry-run is still allowed without a terminal.
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
    --uninstall) UNINSTALL=1 ;;
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

# spin_wait PID MESSAGE — braille spinner on the current line while PID runs.
# Caller gates on HAVE_TTY; the line is erased when the process finishes.
spin_wait() {
  local pid="$1" msg="$2" frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %b%s%b %s ' "$CYN" "${frames:$((i % 10)):1}" "$RST" "$msg"
    i=$((i+1)); sleep 0.1
  done
  printf '\r\033[K\033[?25h'
}

cleanup() {
  [ -n "$DL_DIR" ] && [ -d "$DL_DIR" ] && rm -rf "$DL_DIR"
  # restore the cursor if an interrupt landed mid-spinner/menu (both hide it)
  [ "${HAVE_TTY:-0}" -eq 1 ] && printf '\033[?25h'
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

# ---- Legacy reconcile (shared by install and uninstall) ----
# Removes files an old baseline shipped and the current one has dropped
# (the legacy research workflow; the /map skill dropped in v2.6.1). A file is
# removed only when (a) it is in the target but NOT in the current baseline
# source (target .claude/X maps to source src/X), AND (b) its sha256 matches
# the exact content that prior baseline shipped — a same-named file with
# different content is user-made and is kept. If the baseline ever ships these
# paths again under src/, the source-existence guard keeps them.
legacy_sha() {
  case "$1" in
    ".claude/agents/impact-research.md")   echo "3166e8b7a972aade3c4655b251787097eac0b308071a2579814b5915563e02ea" ;;
    ".claude/agents/security-research.md") echo "22f3cba74273063f96379b8bb815a1e0a24f10d5a9c07f489fe6f31d6fa71d50" ;;
    ".claude/skills/research/SKILL.md")    echo "b0d09c2604255b285d7463299a88810e9a1670105ecced47d7076332c06eb2c7" ;;
    ".claude/skills/map/SKILL.md")         echo "5654b3c54d0271e80af1be0a050075c86a7ec723e3525897885ce58d89a5fd5f" ;;
  esac
}
file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo "unavailable"; fi   # never matches a real hash -> file is kept (safe direction)
}
reconcile_legacy() {
  local rf
  for rf in ".claude/agents/impact-research.md" \
            ".claude/agents/security-research.md" \
            ".claude/skills/research/SKILL.md" \
            ".claude/skills/map/SKILL.md"; do
    if [ -f "$TARGET_ABS/$rf" ] && [ ! -e "$SRC/src/${rf#.claude/}" ]; then
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
    "$TARGET_ABS/.claude/skills/map" \
    "$TARGET_ABS/.claude/agents" 2>/dev/null || true
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

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/src/CLAUDE.md" ] && [ -f "$SELF_DIR/src/settings.json" ]; then
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
  # AVN_REF may be a branch or a tag — codeload uses a different path for each.
  download_baseline() {
    fetch "https://codeload.github.com/${AVN_REPO}/tar.gz/refs/heads/${AVN_REF}" "$DL_DIR/baseline.tgz" 2>/dev/null \
      || fetch "https://codeload.github.com/${AVN_REPO}/tar.gz/refs/tags/${AVN_REF}" "$DL_DIR/baseline.tgz" 2>/dev/null
  }
  DL_OK=0
  if [ "$HAVE_TTY" -eq 1 ]; then
    download_baseline & DL_PID=$!
    spin_wait "$DL_PID" "downloading ${AVN_REPO}@${AVN_REF} ..."
    wait "$DL_PID" && DL_OK=1 || DL_OK=0
  else
    printf '  %b⇣%b downloading %s@%s ...\n' "$CYN" "$RST" "$AVN_REPO" "$AVN_REF"
    download_baseline && DL_OK=1 || DL_OK=0
  fi
  [ "$DL_OK" -eq 1 ] \
    || { printf '%b✗%b download failed: network error, or no branch/tag "%s" in %s\n' "$RED" "$RST" "$AVN_REF" "$AVN_REPO" >&2; exit 1; }
  [ "$HAVE_TTY" -eq 1 ] && printf '  %b⇣%b downloaded %s@%s\n' "$CYN" "$RST" "$AVN_REPO" "$AVN_REF"
  tar -xzf "$DL_DIR/baseline.tgz" -C "$DL_DIR" || { printf '%b✗%b failed to extract baseline archive\n' "$RED" "$RST" >&2; exit 1; }
  SRC=""
  for d in "$DL_DIR"/*/; do SRC="${d%/}"; break; done
  SRC_DESC="remote: ${AVN_REPO}@${AVN_REF}"
fi

for f in "src/CLAUDE.md" "src/settings.json" "src/hooks/bash-guard.sh" "src/hooks/file-guard.sh" "src/hooks/verify-gate.sh"; do
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

# ---- Build the file plan (sources under src/, installed under .claude/) ----
# settings.json ships as-is: hook commands already use ${CLAUDE_PROJECT_DIR}.
# The deny rules Read/Edit(~/.claude/**) intentionally point at the user's HOME
# and must never be rewritten — they protect the user's global config.
SRCS=(); DESTS=()
add_pair() { SRCS+=("$1"); DESTS+=("$2"); }
add_pair "$SRC/src/CLAUDE.md" "$TARGET_ABS/CLAUDE.md"
for r in "$SRC"/src/rules/*.md; do
  [ -e "$r" ] || continue
  add_pair "$r" "$TARGET_ABS/.claude/rules/$(basename "$r")"
done
for a in "$SRC"/src/agents/*.md; do
  [ -e "$a" ] || continue
  add_pair "$a" "$TARGET_ABS/.claude/agents/$(basename "$a")"
done
if [ -d "$SRC/src/skills" ]; then
  while IFS= read -r sk; do
    add_pair "$sk" "$TARGET_ABS/.claude/${sk#"$SRC"/src/}"
  done < <(find "$SRC/src/skills" -type f | sort)
fi
add_pair "$SRC/src/hooks/bash-guard.sh" "$TARGET_ABS/.claude/hooks/bash-guard.sh"
add_pair "$SRC/src/hooks/file-guard.sh" "$TARGET_ABS/.claude/hooks/file-guard.sh"
add_pair "$SRC/src/hooks/verify-gate.sh" "$TARGET_ABS/.claude/hooks/verify-gate.sh"
add_pair "$SRC/src/verify-commands.example" "$TARGET_ABS/.claude/verify-commands.example"
add_pair "$SRC/src/settings.json" "$TARGET_ABS/.claude/settings.json"

# ---- Header ----
printf '\n'
printf '  %b▄▀█ █░█ █▄░█%b\n' "$CYN$BOLD" "$RST"
printf '  %b█▀█ ▀▄▀ █░▀█%b  %bThieuNV Claude Code baseline%b\n' "$CYN$BOLD" "$RST" "$BOLD" "$RST"
printf '\n'
printf '  %ssource%s  %s\n' "$DIM" "$RST" "$SRC_DESC"
printf '  %starget%s  %s\n' "$DIM" "$RST" "$TARGET_ABS"
if [ "$UNINSTALL" -eq 1 ]; then
  printf '  %sversion%s %s (uninstall)\n' "$DIM" "$RST" "${OLD_VER:-not installed}"
elif [ -z "$OLD_VER" ]; then
  printf '  %sversion%s %s (new install)\n' "$DIM" "$RST" "$NEW_VER"
elif [ "$OLD_VER" = "$NEW_VER" ]; then
  printf '  %sversion%s %s (unchanged)\n' "$DIM" "$RST" "$NEW_VER"
else
  printf '  %sversion%s %s → %s\n' "$DIM" "$RST" "$OLD_VER" "$NEW_VER"
fi
[ "$DRY_RUN" -eq 1 ] && printf '  %b(dry-run — no changes will be made)%b\n' "$YLW" "$RST"

# ---- Self-target gate: touching a source repo's own installed copy ----
# When the target itself is a baseline source repo (it carries src/ +
# install.sh), its root .claude/ + CLAUDE.md are the RUNNING guard for
# sessions in that repo. Refreshing OR removing them must stay a human action:
# a real /dev/tty plus explicit confirmation is required, and no flag
# (-y/--force included) substitutes for it — an agent session has no TTY and
# must ask the user to run this. --dry-run stays allowed headless (preview /
# CI drift check). Detection is content-based so it also fires in remote
# (curl | bash) mode; faking src/ in an ordinary repo only ADDS a TTY
# requirement, so the safe direction holds.
SELF_TARGET=0
[ -f "$TARGET_ABS/src/settings.json" ] && [ -f "$TARGET_ABS/install.sh" ] && SELF_TARGET=1
if [ "$SELF_TARGET" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ "$HAVE_TTY" -ne 1 ]; then
    printf '%b✗%b target is a baseline source repo; changing its installed copy (.claude/, CLAUDE.md) needs a human.\n' "$RED" "$RST" >&2
    printf '  Run %s./install.sh%s in an interactive terminal — no flag bypasses this (--dry-run is allowed).\n' "$BOLD" "$RST" >&2
    exit 1
  fi
  if [ "$UNINSTALL" -eq 1 ]; then
    menu_select "Target is the baseline source repo itself — REMOVE its installed copy (.claude/, CLAUDE.md)?" \
                "No  — keep it" \
                "Yes — remove the installed copy"
    if [ "$MENU_CHOICE" -ne 1 ]; then
      printf '  %b✗%b aborted — nothing changed.\n' "$RED" "$RST"; exit 1
    fi
  else
    menu_select "Target is the baseline source repo itself — refresh its installed copy (.claude/, CLAUDE.md) from src/?" \
                "Yes — refresh the installed copy" \
                "No  — abort"
    if [ "$MENU_CHOICE" -ne 0 ]; then
      printf '  %b✗%b aborted — nothing changed.\n' "$RED" "$RST"; exit 1
    fi
  fi
fi

# ---- Uninstall confirmation (non-self targets; the gate above covers self) ----
if [ "$UNINSTALL" -eq 1 ] && [ "$SELF_TARGET" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && \
   [ "$ASSUME_YES" -ne 1 ] && [ "$FORCE" -ne 1 ]; then
  if [ "$HAVE_TTY" -eq 1 ]; then
    menu_select "Remove the ThieuNV baseline from $TARGET_ABS?" \
                "No  — keep it" \
                "Yes — remove the baseline files"
    if [ "$MENU_CHOICE" -ne 1 ]; then
      printf '  %b✗%b aborted — nothing changed.\n' "$RED" "$RST"; exit 1
    fi
  else
    printf '%b✗%b non-interactive uninstall needs an explicit -y (or --force).\n' "$RED" "$RST" >&2
    exit 1
  fi
fi

# ---- Uninstall: remove what the baseline installed, keep what the user made ----
# Mirrors the file plan above. A file is deleted only when it is byte-identical
# to the shipped source (cmp) — nothing is lost, a reinstall restores it. A
# file that differs (customized CLAUDE.md, merged settings.json) is kept with
# a warning. User-made files (.claude/verify-commands, settings.local.json,
# CLAUDE.local.md, own agents/skills) are never in the plan, so never touched.
if [ "$UNINSTALL" -eq 1 ]; then
  printf '\n'
  N_KEPT=0
  if [ -n "$OLD_VER" ] && [ "$OLD_VER" != "$NEW_VER" ]; then
    printf '  %b⚠%b installed %s but the uninstall source is %s — only byte-identical files are removed;\n' "$YLW" "$RST" "$OLD_VER" "$NEW_VER"
    printf '    if files are kept unexpectedly, pin the matching release: --ref v%s\n' "$OLD_VER"
  fi
  for i in "${!DESTS[@]}"; do
    d="${DESTS[$i]}"; s="${SRCS[$i]}"; r="$(rel "$d")"
    [ -f "$d" ] || continue
    if cmp -s "$s" "$d"; then
      line "$RED" "-" "remove" "$r"
      [ "$DRY_RUN" -eq 1 ] || rm -f "$d"
      N_REMOVE=$((N_REMOVE+1))
    else
      line "$YLW" "⚠" "keep" "$r (differs from the shipped file — looks user-edited)"
      N_KEPT=$((N_KEPT+1))
    fi
  done
  if [ -f "$STAMP" ]; then
    if head -n1 "$STAMP" | grep -q "written by install.sh"; then
      line "$RED" "-" "remove" ".claude/avn-version"
      [ "$DRY_RUN" -eq 1 ] || rm -f "$STAMP"
      N_REMOVE=$((N_REMOVE+1))
    else
      line "$YLW" "⚠" "keep" ".claude/avn-version (unexpected content)"
      N_KEPT=$((N_KEPT+1))
    fi
  fi
  reconcile_legacy
  # gitignore — take back exactly the lines the installer appends
  GI="$TARGET_ABS/.gitignore"
  if [ -f "$GI" ]; then
    for ln in "CLAUDE.local.md" ".claude/settings.local.json" "CLAUDE.md.bak" ".claude/**/*.bak"; do
      if grep -qxF "$ln" "$GI"; then
        line "$CYN" "✎" "gitignore" "-= $ln"
        if [ "$DRY_RUN" -eq 0 ]; then
          grep -vxF "$ln" "$GI" > "$GI.avn-tmp" || true
          mv "$GI.avn-tmp" "$GI"
        fi
      fi
    done
  fi
  # prune now-empty baseline dirs (rmdir refuses non-empty — user files keep them alive)
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -d "$TARGET_ABS/.claude/skills" ]; then
      find "$TARGET_ABS/.claude/skills" -depth -type d -exec rmdir {} \; 2>/dev/null || true
    fi
    rmdir "$TARGET_ABS/.claude/hooks" "$TARGET_ABS/.claude/rules" \
          "$TARGET_ABS/.claude/agents" "$TARGET_ABS/.claude" 2>/dev/null || true
  fi
  printf '\n'
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%b▸ dry-run complete%b — nothing was changed.\n' "$BOLD$YLW" "$RST"
  else
    printf '%b✓ uninstalled%b  %sremoved %d' "$BOLD$GRN" "$RST" "$DIM" "$N_REMOVE"
    [ "$N_KEPT" -gt 0 ] && printf ' · kept %d (user-edited)' "$N_KEPT"
    printf '%b\n' "$RST"
    [ "$N_KEPT" -gt 0 ] && printf '  %bnote%b kept files were modified locally — review and delete them yourself if wanted.\n' "$DIM" "$RST"
    printf '  %bnext%b restart Claude Code sessions in this repo — the baseline hooks/permissions no longer apply.\n' "$DIM" "$RST"
  fi
  exit 0
fi

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

# ---- Apply (streams one status line per file; a TTY additionally gets a live progress bar) ----
TOTAL=${#DESTS[@]}
draw_bar() { # CUR TOTAL — rendered in place below the streaming status lines
  [ "$HAVE_TTY" -eq 1 ] || return 0
  local cur=$1 total=$2 width=24 filled bar="" j
  filled=$(( cur * width / total ))
  for (( j = 0; j < width; j++ )); do
    if [ "$j" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
  done
  printf '\r  %b%s%b %d/%d files' "$CYN" "$bar" "$RST" "$cur" "$total"
}
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$TARGET_ABS/.claude/rules" "$TARGET_ABS/.claude/hooks"
CUR_N=0
for i in "${!DESTS[@]}"; do
  [ "$HAVE_TTY" -eq 1 ] && printf '\r\033[K'   # clear the bar before the next status line
  install_file "${SRCS[$i]}" "${DESTS[$i]}"
  CUR_N=$((CUR_N+1))
  draw_bar "$CUR_N" "$TOTAL"
done
[ "$HAVE_TTY" -eq 1 ] && printf '\r\033[K'
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
STAMP_CONTENT="# ThieuNV Claude Code baseline — written by install.sh; do not edit by hand.
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

# .gitignore — append Claude lines when missing (creates the file if absent).
# The .bak patterns cover exactly the backups install_file creates (CLAUDE.md
# at the root, everything else under .claude/) so they never get committed.
GI="$TARGET_ABS/.gitignore"
for ln in "CLAUDE.local.md" ".claude/settings.local.json" "CLAUDE.md.bak" ".claude/**/*.bak"; do
  if [ ! -f "$GI" ] || ! grep -qxF "$ln" "$GI"; then
    line "$CYN" "✎" "gitignore" "+= $ln"
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$ln" >> "$GI"
  fi
done

# ---- Reconcile: remove files the baseline has dropped (see reconcile_legacy) ----
reconcile_legacy

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
