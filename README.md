# Asilla Claude Code baseline

A shared Claude Code configuration baseline for Asilla projects:

- `CLAUDE.md` — quality-focused working agreement (workflow, scope, secrets, production, testing).
- `.claude/rules/` — path-scoped rules that load on demand: `ui.md`, `realtime-performance.md`, `testing.md`, `migrations.md`.
- `.claude/skills/` — invocable workflows: `/brainstorm` (idea → spec), `/code-review` (independent review in a fresh context), `/verify` (run all verification layers, report evidence).
- `.claude/hooks/bash-guard.sh` — PreToolUse hook that deterministically blocks dangerous Bash commands (push to main, `rm -rf`, secret reads, destructive SQL/redis/mongo/docker/kubectl, `git clean -f`, …).
- `.claude/hooks/verify-gate.sh` — Stop hook that can enforce "tests green before finishing"; **dormant by default** (see below).
- `.claude/verify-commands.example` — template for opting in to the verify gate.
- `.claude/settings.json` — permission baseline (allow / ask / deny) plus the hook wiring.
- `VERSION` + `bin/avn` — SemVer for the baseline and a pip-style manager CLI (`avn install` /
  `update` / `check`); each install stamps `.claude/avn-version` into the target repo.

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

The script downloads the baseline from GitHub and copies the pieces above into the target repo.
`settings.json` ships as-is — its hook commands already use `${CLAUDE_PROJECT_DIR}`, so the
baseline is self-contained per repo (and protects this repo itself, too). It is safe to re-run
(idempotent) and adds `CLAUDE.local.md` / `.claude/settings.local.json` to `.gitignore`
(creating the file if needed).

When a file would be overwritten, you get an arrow-key menu asking whether to back it up first
(default: **Yes** → `<file>.bak`). Control it non-interactively with flags:

| Flag | Effect |
| --- | --- |
| `--dry-run` | Preview only; change nothing. |
| `--backup` / `--no-backup` | Choose backup behavior without prompting. |
| `-y`, `--yes` | Don't prompt; use defaults (backup = yes). |
| `--force` | Overwrite without backups and without prompts. |
| `--no-color` | Plain output. |

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

## Versioning & the `avn` CLI

The baseline is versioned with SemVer: the `VERSION` file is the single source of truth, and every
install writes a stamp to `.claude/avn-version` in the target repo (version + source). **Commit the
stamp** — the whole team then sees which baseline the repo runs, and upgrades show up in git
history. The installer header and summary show the version change (`2.0.0 → 2.1.0`).

`bin/avn` is a pip-style manager around the installer. Install it once (normal terminal):

```bash
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/bin/avn -o ~/.local/bin/avn && chmod +x ~/.local/bin/avn
```

(or from a clone: `./avn/bin/avn self-install`). Then, inside any repo:

| Command | Effect |
| --- | --- |
| `avn install [DIR]` | Install the baseline / bring it up to date. |
| `avn update [DIR]` | Same, but refuses a repo that was never installed (no stamp). |
| `avn check [DIR]` | Compare the stamp with the latest `VERSION` on GitHub. Exit 0 = up to date, 1 = outdated, 2 = error (no stamp / network) — CI can rely on 0/1. |
| `avn version` | CLI version + the baseline version of the current repo. |
| `avn self-update` | Replace the `avn` script itself with the latest from GitHub. |

Flags after the directory pass through to `install.sh` (`--dry-run`, `-y`, `--force`, …).

**Pinning**: `AVN_REF` (and `avn --ref`) accepts a branch **or a tag**, so a repo can stay on a
fixed release:

```bash
avn install --ref v2.1.0
AVN_REF=v2.1.0 curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash
```

### Releasing (maintainers)

1. Bump `VERSION` and `AVN_CLI_VERSION` in `bin/avn` (the test suite fails if they diverge).
2. Run the suites: `bash tests/install-version-test.sh && bash tests/bash-guard-test.sh`.
3. Commit, then tag and push: `git tag v<version> && git push origin master --tags`.

## Day-to-day usage

| Situation | Practice |
| --- | --- |
| Raw idea, no clear solution yet | `/brainstorm` — interviews you, researches options, produces a spec |
| Non-trivial task | Plan Mode + the spec-driven Clarify/Plan steps (CLAUDE.md §2) |
| Risky data operation (DB, volumes, prod-like systems) | Data-risk assessment first (CLAUDE.md §8); the hook blocks the worst commands outright |
| Finished coding | `/verify` — runs every layer the project defines, reports evidence |
| Before a PR / after non-trivial changes | `/code-review` — independent review in a fresh context |
| Changed a convention/pattern/signature | Pattern sweep (CLAUDE.md §3) — update or list all similar occurrences |

## Optional: enforced verification on Stop

The baseline wires a Stop hook (`verify-gate.sh`) that is a **no-op until you opt in**:

```bash
cp .claude/verify-commands.example .claude/verify-commands
# then uncomment/add the commands your project actually defines
```

With the file present, Claude Code cannot end a coding turn while any listed command fails.
The gate skips read-only turns (clean git tree), skips non-git directories, and gives up after
3 consecutive blocks (asking Claude to report failures honestly) so it can never loop forever.
Delete `.claude/verify-commands` to turn it off.

## Troubleshooting

**The AI doesn't wait for your answers during `/brainstorm` (or any AskUserQuestion) and decides
by itself** — Claude Code v2.1.198+ added a 60s "AFK" auto-advance to unanswered questions
([#73125](https://github.com/anthropics/claude-code/issues/73125)). The baseline disables it via
`env.CLAUDE_AFK_TIMEOUT_MS` in `.claude/settings.json`; if your Claude Code version shows a
question-timeout toggle in `/config`, keep it OFF. Also: run `/brainstorm` only in an interactive
session — in background/headless runs the question tool cannot collect answers, and the skill is
instructed to stop and ask in plain text instead.

## Updating / reconciling

**Just re-run the installer** (the same way you first installed it) — or run `avn update` — to
bring a repo **exactly** up to the current baseline. It updates changed files, refreshes the
`.claude/avn-version` stamp, and also removes files the baseline has since dropped, so an older
install is fully reconciled — no special flag needed. Not sure whether a repo is stale? `avn check`.

> An earlier version shipped a research workflow (`.claude/agents/{impact,security}-research.md` and
> `.claude/skills/research/`). A normal re-run deletes those — but only when the file content is
> byte-identical (sha256) to what that old baseline shipped. A same-named file you wrote yourself
> is kept, and your own agents or skills are never touched. Preview with `--dry-run`.

## Notes

- Project `.claude/settings.json` permissions **merge** with your user-level `~/.claude/settings.json`
  (they do not clobber it). A deny rule at either level always wins.
- Run the `curl | bash` bootstrap in a **normal terminal**, not inside a Claude Code session that is
  already governed by this baseline: the baseline's own deny-list blocks `curl`/`wget` and the hook
  blocks `curl | sh`. (Bootstrapping a fresh repo from a plain shell is the expected flow.)
