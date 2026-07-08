# ThieuNV Claude Code baseline

A shared Claude Code configuration baseline for ThieuNV's projects:

- `CLAUDE.md` — quality-focused working agreement (workflow, scope, secrets, production, testing).
- `.claude/rules/` — path-scoped rules that load on demand: `ui.md`, `realtime-performance.md`, `testing.md`, `migrations.md`, `deploy.md`.
- `.claude/skills/` — invocable workflows: `/brainstorm` (idea → spec), `/map` (generate/refresh the codebase knowledge base), `/code-review` (independent review in a fresh context), `/verify` (run all verification layers, report evidence).
- `.claude/hooks/bash-guard.sh` — PreToolUse hook that deterministically blocks dangerous Bash commands (push to main — including a bare `git push` while the checkout sits on main/master, `rm -rf`, secret reads, destructive SQL/redis/mongo/docker/kubectl, `git clean -f`, discarding uncommitted changes via `checkout`/`restore`/`stash drop`, shell edits of the guard files themselves, …).
- `.claude/hooks/file-guard.sh` — PreToolUse hook for the file tools (Read/Edit/Write/Grep, …): blocks every dotenv file **except** the placeholder templates `.env.example` / `.env.sample` / `.env.template` / `.env.dist`, and blocks the write tools on the baseline guard files so the agent cannot neutralize its own guard layer.
- `.claude/hooks/verify-gate.sh` — Stop hook that can enforce "tests green before finishing"; **dormant by default** (see below).
- `.claude/verify-commands.example` — template for opting in to the verify gate.
- `.claude/settings.json` — permission baseline (allow / ask / deny) plus the hook wiring.
- `VERSION` + `bin/avn` — SemVer for the baseline and a pip-style manager CLI (`avn install` /
  `update` / `check`); each install stamps `.claude/avn-version` into the target repo.

**Repo layout:** the sources of everything above live under **`src/`** (`src/CLAUDE.md`,
`src/settings.json`, `src/hooks/`, `src/rules/`, `src/skills/`, `src/verify-commands.example`) —
deliberately with no `.claude` path segment, so the guard hooks never block editing the sources.
The `CLAUDE.md` and `.claude/**` at this repo's root are its own **installed copy** (the baseline
dogfoods itself). Refresh that copy with `./install.sh .` — it only runs in an interactive
terminal and asks for confirmation; no flag bypasses it (see Threat model).

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

Requirements: `tar` plus `curl` or `wget` on PATH (standard on Linux/macOS), and `python3` at
runtime — the guard hooks parse tool-call JSON with it and **fail closed**: without python3 every
Bash/file tool call is blocked until it is installed.

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
| `avn uninstall [DIR]` | Remove the baseline from a repo (see [Uninstalling](#uninstalling)). |
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
2. Run the suites: `bash tests/install-version-test.sh && bash tests/bash-guard-test.sh && bash tests/file-guard-test.sh`.
3. Refresh this repo's own installed copy and include it in the commit: `./install.sh .`
   (interactive — the self-target gate asks for confirmation).
4. Commit, then tag and push: `git tag v<version> && git push origin master --tags`.

CI (`.github/workflows/ci.yml`) runs the same three suites plus shellcheck on every push and PR,
and fails when the root installed copy has drifted from `src/` (self-target `--dry-run` must
report no pending changes) — a release should only be tagged from a green master.

## Day-to-day usage

| Situation | Practice |
| --- | --- |
| New repo, or every session re-explores from scratch | `/map` — generates the codebase KB: an auto-loaded index (`.claude/rules/codebase-map.md`) + on-demand docs under `docs/codebase/`; sessions read it first, then explore to confirm |
| Raw idea, no clear solution yet | `/brainstorm` — interviews you, researches options, produces a spec |
| Non-trivial task | Plan Mode + the spec-driven Clarify/Plan steps (CLAUDE.md §2) |
| Risky data operation (DB, volumes, prod-like systems) | Data-risk assessment first (CLAUDE.md §8); the hook blocks the worst commands outright |
| Finished coding | `/verify` — runs every layer the project defines, reports evidence |
| Before a PR / after non-trivial changes | `/code-review` — independent review in a fresh context |
| Changed a convention/pattern/signature | Pattern sweep (CLAUDE.md §3) — update or list all similar occurrences |

## Threat model

Know what the guard layer is — and is not — before relying on it:

- **The hooks are a seatbelt, not a sandbox.** They deterministically stop *accidents*: the
  regexes catch dangerous commands in any flag order, but a model (or user) deliberately
  obfuscating a command can get around a string match. Do not treat a governed session as a
  security boundary for untrusted code or prompts.
- **Branch protection lives on the server.** The push rules (including the bare-`git push`-on-main
  check) are a local convenience; the real protection is server-side branch protection on
  main/master. Enable it on every repo that adopts the baseline.
- **Self-protection has one deliberate gap.** The agent cannot edit `.claude/hooks/*`,
  `.claude/verify-commands`, or `.claude/avn-version` (file-guard + deny rules), and shell edits of
  any guard file including `settings.json` are blocked by bash-guard. `settings.json` itself is
  protected by its own deny rule only — listing it in file-guard would make it permanently
  uneditable from a governed session.
- **Sources are editable; the running copy is not.** Everything ships from `src/`, which an agent
  may edit like any other code — the control there is PR review. The installed copy at a repo's
  root (`.claude/**` — the guard that actually runs) is protected by the deny rules and hooks,
  and refreshing the source repo's own copy (`./install.sh .`) demands a real terminal plus an
  explicit confirmation that no flag bypasses — an agent session cannot self-apply guard changes.
- **Hooks are code that runs on every developer machine.** Review the baseline (or pin a reviewed
  tag with `--ref`) before installing it fleet-wide; anyone who can change the source repo can
  change what runs in every governed session.
- **python3 is required.** bash-guard and file-guard fail closed without it (every guarded tool
  call is blocked); verify-gate fails open by design (a Stop gate must never brick a session).

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

## Uninstalling

`avn uninstall [DIR]` (or `./install.sh --uninstall [DIR]`, or the `curl | bash` one-liner with
`-s -- --uninstall`) removes exactly what the baseline installed:

- Files **byte-identical to the shipped release** are deleted — nothing is lost, a reinstall
  restores them. Anything you modified (a customized `CLAUDE.md`, a merged `settings.json`) is
  **kept** with a warning.
- Your own files are never touched: `.claude/verify-commands`, `.claude/settings.local.json`,
  `CLAUDE.local.md`, and any agents/skills you added yourself.
- The `.gitignore` lines the installer appended are taken back, and `.claude/` directories are
  pruned only when empty.

Non-interactive runs need an explicit `-y`; preview with `--dry-run`. If the repo runs an older
release than the source you uninstall with, files won't match — pin the matching release:
`avn uninstall --ref v<installed-version>`. Uninstalling from the baseline source repo itself is
TTY-gated like the self-install. Afterwards, restart any Claude Code session in that repo — the
hooks and permission rules no longer apply.

## Notes

- Project `.claude/settings.json` permissions **merge** with your user-level `~/.claude/settings.json`
  (they do not clobber it). A deny rule at either level always wins.
- Run the `curl | bash` bootstrap in a **normal terminal**, not inside a Claude Code session that is
  already governed by this baseline: the baseline's own deny-list blocks `curl`/`wget` and the hook
  blocks `curl | sh`. (Bootstrapping a fresh repo from a plain shell is the expected flow.)

## License

Proprietary — all rights reserved. Any use requires prior written permission from the author; see
[LICENSE](LICENSE).
