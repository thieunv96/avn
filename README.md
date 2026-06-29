# Asilla Claude Code baseline

A shared Claude Code configuration baseline for Asilla projects:

- `CLAUDE.md` — quality-focused working agreement (workflow, scope, secrets, production, testing).
- `.claude/rules/` — path-scoped rules that load on demand: `ui.md`, `realtime-performance.md`, `testing.md`.
- `.claude/hooks/bash-guard.sh` — PreToolUse hook that deterministically blocks dangerous Bash commands.
- `.claude/settings.json` — permission baseline (allow / ask / deny) plus the hook wiring.

## Install into a repo (one command)

```bash
/path/to/avn/install.sh /path/to/target-repo
```

Or from inside the target repo (target defaults to the current directory):

```bash
/path/to/avn/install.sh
```

Useful flags:

```bash
install.sh --dry-run /path/to/target-repo   # preview, change nothing
install.sh --force   /path/to/target-repo    # overwrite without .bak backups
install.sh --help
```

The installer copies the four pieces above into the target repo and **rewrites the hook command to
`${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-guard.sh`** so the baseline is self-contained per repo. It
backs up any file it would overwrite to `<file>.bak` (unless `--force`), is safe to re-run
(idempotent), and appends `CLAUDE.local.md` / `.claude/settings.local.json` to an existing
`.gitignore` if missing.

After installing, open Claude Code in the target repo and run `/permissions` to review the rules.

## Notes

- Project `.claude/settings.json` permissions **merge** with your user-level `~/.claude/settings.json`
  (they do not clobber it).
- This baseline's own deny-list blocks `curl`/`wget` and the hook blocks `curl | sh`, so there is no
  `curl … | bash` one-liner by design. If you host this repo on Git, install without piping to a
  shell, e.g.: `git clone --depth 1 <url> /tmp/avn && /tmp/avn/install.sh /path/to/target-repo`.
