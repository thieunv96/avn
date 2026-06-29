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
TARGET=""
AVN_REPO="${AVN_REPO:-thieunv96/avn}"
AVN_REF="${AVN_REF:-master}"
DL_DIR=""
TMP_SETTINGS=""

usage() {
  cat <<'EOF'
Install the Asilla Claude Code baseline into a target repo.

Usage:
  install.sh [--dry-run] [--force] [TARGET_DIR]
  curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash -s -- [--dry-run] [TARGET_DIR]

  TARGET_DIR   Target repository directory (default: current directory).
  --dry-run    Show what would happen; change nothing (still downloads if run remotely).
  --force      Overwrite existing files without creating .bak backups.
  -h, --help   Show this help.

Env:
  AVN_REPO     GitHub owner/repo to fetch from when run without a clone (default: thieunv96/avn).
  AVN_REF      Branch or tag to fetch (default: master).

Installs:
  CLAUDE.md
  .claude/rules/{ui,realtime-performance,testing}.md
  .claude/hooks/bash-guard.sh        (made executable)
  .claude/settings.json              (hook path rewritten to ${CLAUDE_PROJECT_DIR})

After installing, open Claude Code in the target repo and run /permissions to review the rules.
EOF
}

note() { printf '%s\n' "$*"; }
act()  { if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*"; else printf '%s\n' "$*"; fi; }
abspath() { (cd "$1" 2>/dev/null && pwd); }
rel()  { printf '%s' "${1#"$TARGET_ABS"/}"; }

cleanup() {
  [ -n "$DL_DIR" ] && [ -d "$DL_DIR" ] && rm -rf "$DL_DIR"
  [ -n "$TMP_SETTINGS" ] && [ -f "$TMP_SETTINGS" ] && rm -f "$TMP_SETTINGS"
  return 0
}
trap cleanup EXIT

# install_file SRC_FILE DEST_FILE
install_file() {
  local s="$1" d="$2"
  if [ -f "$d" ]; then
    if cmp -s "$s" "$d"; then
      note "  unchanged  $(rel "$d")"
      return 0
    fi
    if [ "$FORCE" -eq 0 ]; then
      act "  backup     $(rel "$d") -> $(rel "$d").bak"
      [ "$DRY_RUN" -eq 1 ] || mv -f "$d" "$d.bak"
    fi
    act "  overwrite  $(rel "$d")"
  else
    act "  create     $(rel "$d")"
  fi
  [ "$DRY_RUN" -eq 1 ] || cp "$s" "$d"
}

# ---- Parse args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$TARGET" ]; then echo "Error: multiple target dirs given." >&2; exit 2; fi
      TARGET="$1" ;;
  esac
  shift
done
if [ $# -gt 0 ] && [ -z "$TARGET" ]; then TARGET="$1"; fi

# ---- Resolve target ----
TARGET="${TARGET:-$PWD}"
if [ ! -d "$TARGET" ]; then
  echo "Error: target directory does not exist: $TARGET" >&2
  exit 1
fi
TARGET_ABS="$(abspath "$TARGET")"

# ---- Resolve baseline source: local script dir if it has the files, else download ----
SELF_DIR=""
case "${BASH_SOURCE[0]:-}" in
  ""|bash|sh|/dev/*|/proc/*) SELF_DIR="" ;;
  *) SELF_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)" ;;
esac

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/CLAUDE.md" ] && [ -f "$SELF_DIR/.claude/settings.json" ]; then
  SRC="$SELF_DIR"
  SRC_DESC="local: $SRC"
else
  command -v tar >/dev/null 2>&1 || { echo "Error: 'tar' is required to download the baseline." >&2; exit 1; }
  DL_DIR="$(mktemp -d)"
  URL="https://codeload.github.com/${AVN_REPO}/tar.gz/refs/heads/${AVN_REF}"
  note "Downloading baseline ${AVN_REPO}@${AVN_REF} ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$DL_DIR/baseline.tgz" || { echo "Error: download failed: $URL" >&2; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$DL_DIR/baseline.tgz" "$URL" || { echo "Error: download failed: $URL" >&2; exit 1; }
  else
    echo "Error: need 'curl' or 'wget' to download the baseline." >&2; exit 1
  fi
  tar -xzf "$DL_DIR/baseline.tgz" -C "$DL_DIR" || { echo "Error: failed to extract the baseline archive." >&2; exit 1; }
  SRC=""
  for d in "$DL_DIR"/*/; do SRC="${d%/}"; break; done
  SRC_DESC="remote: ${AVN_REPO}@${AVN_REF}"
fi

# self-install guard (local mode)
if [ "$TARGET_ABS" = "$SRC" ]; then
  echo "Error: target is the baseline source itself ($SRC). Choose another repo." >&2
  exit 1
fi

# sanity: required source files present
for f in "CLAUDE.md" ".claude/settings.json" ".claude/hooks/bash-guard.sh"; do
  if [ -z "${SRC:-}" ] || [ ! -f "$SRC/$f" ]; then
    echo "Error: baseline source is missing $f." >&2
    exit 1
  fi
done

note "Installing Asilla Claude Code baseline"
note "  from: $SRC_DESC"
note "  into: $TARGET_ABS"
[ "$DRY_RUN" -eq 1 ] && note "  (dry-run: no changes will be made)"
note ""

# 1. Directories
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$TARGET_ABS/.claude/rules" "$TARGET_ABS/.claude/hooks"

# 2. CLAUDE.md
install_file "$SRC/CLAUDE.md" "$TARGET_ABS/CLAUDE.md"

# 3. rules
for r in "$SRC"/.claude/rules/*.md; do
  [ -e "$r" ] || continue
  install_file "$r" "$TARGET_ABS/.claude/rules/$(basename "$r")"
done

# 4. hook (+ executable bit)
install_file "$SRC/.claude/hooks/bash-guard.sh" "$TARGET_ABS/.claude/hooks/bash-guard.sh"
[ "$DRY_RUN" -eq 1 ] || chmod +x "$TARGET_ABS/.claude/hooks/bash-guard.sh"

# 5. settings.json with the hook path rewritten to be project-relative.
# Only the hook command is rewritten. The deny rules Edit(~/.claude/settings.json) and
# Edit(~/.claude/hooks/**) are intentionally left as-is — they protect the user's global config.
TMP_SETTINGS="$(mktemp)"
sed 's#~/\.claude/hooks/bash-guard\.sh#${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-guard.sh#g' \
    "$SRC/.claude/settings.json" > "$TMP_SETTINGS"
if ! grep -qF '${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-guard.sh' "$TMP_SETTINGS"; then
  echo "Warning: could not rewrite the hook path in settings.json — the source format may have changed." >&2
  echo "         Verify the hook 'command' in $(rel "$TARGET_ABS/.claude/settings.json") after install." >&2
fi
install_file "$TMP_SETTINGS" "$TARGET_ABS/.claude/settings.json"

# 6. .gitignore — append Claude lines only if the file already exists and is missing them
GI="$TARGET_ABS/.gitignore"
if [ -f "$GI" ]; then
  for line in "CLAUDE.local.md" ".claude/settings.local.json"; do
    if ! grep -qxF "$line" "$GI"; then
      act "  gitignore  += $line"
      [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$line" >> "$GI"
    fi
  done
fi

note ""
note "Done. Open Claude Code in the target repo and run /permissions to review the rules."
[ "$DRY_RUN" -eq 1 ] && note "(dry-run only — nothing was written.)"
