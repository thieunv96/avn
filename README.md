# Asilla Claude Code baseline

A shared Claude Code configuration baseline for Asilla projects:

- `CLAUDE.md` — quality-focused working agreement (workflow, scope, secrets, production, testing).
- `.claude/rules/` — path-scoped rules that load on demand: `ui.md`, `realtime-performance.md`, `testing.md`.
- `.claude/hooks/bash-guard.sh` — PreToolUse hook that deterministically blocks dangerous Bash commands.
- `.claude/settings.json` — permission baseline (allow / ask / deny) plus the hook wiring.

## Install — one command, no clone needed

Run this **inside the target repo** (a normal terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash
```

Or target a specific repo / pass flags (note the `-- ` separator):

```bash
curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash -s -- /path/to/repo
curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash -s -- --dry-run /path/to/repo
```

The script downloads the baseline from GitHub, copies the four pieces above into the target repo,
and **rewrites the hook command to `${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-guard.sh`** so the
baseline is self-contained per repo. It backs up any file it would overwrite to `<file>.bak`
(unless `--force`), is safe to re-run (idempotent), and appends `CLAUDE.local.md` /
`.claude/settings.local.json` to an existing `.gitignore` if missing.

Requirements: `tar` plus `curl` or `wget` on PATH (standard on Linux/macOS).

Pin a different source with env vars:

```bash
AVN_REF=some-branch curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash
AVN_REPO=myfork/avn  curl -fsSL https://raw.githubusercontent.com/myfork/avn/master/install.sh | bash
```

After installing, open Claude Code in the target repo and run `/permissions` to review the rules.

### From a clone (offline / no download)

```bash
git clone --depth 1 https://github.com/thieunv96/avn.git
./avn/install.sh /path/to/target-repo
./avn/install.sh --dry-run /path/to/target-repo
```

When run from a clone, the script installs the local files directly (no download).

## Notes

- Project `.claude/settings.json` permissions **merge** with your user-level `~/.claude/settings.json`
  (they do not clobber it).
- Run the `curl | bash` bootstrap in a **normal terminal**, not inside a Claude Code session that is
  already governed by this baseline: the baseline's own deny-list blocks `curl`/`wget` and the hook
  blocks `curl | sh`. (Bootstrapping a fresh repo from a plain shell is the expected flow.)
