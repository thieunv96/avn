# ThieuNV Claude Code baseline

A shared Claude Code configuration baseline for ThieuNV's projects:

- `CLAUDE.md` — quality-focused working agreement (workflow, scope, secrets, production, testing).
- `.claude/rules/` — path-scoped rules that load on demand: `ui.md`, `realtime-performance.md`, `testing.md`, `migrations.md`, `deploy.md`.
- `.claude/skills/` — invocable workflows: `/brainstorm` (idea → spec), `/code-review` (independent review in a fresh context, pinned to Opus), `/verify` (run all verification layers, report evidence).
- `.claude/agents/` — task-scoped subagents pinned to **Sonnet** (cheaper/faster for heavy delegated work): `web-researcher` (web/docs research), `codebase-explorer` (read-only source exploration with `file:line`), `docs-writer` (documentation grounded in the code). **Subagent model policy:** every subagent except the built-in `Plan` must run on Sonnet or Opus — in every permission mode, plan mode included — and forks are denied; `agent-guard.sh` enforces it (below), and `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in `settings.json` gives model-less agents a compliant default (the built-in `Explore` ignores it and needs an explicit `model`).
- `.claude/hooks/bash-guard.sh` — PreToolUse hook that deterministically blocks dangerous Bash commands (push to main — including a bare `git push` while the checkout sits on main/master, `rm -rf` in any flag order/case plus recursive `rm` outside the project dir, secret reads, destructive SQL/redis/mongo/docker/kubectl, `git clean -f`, discarding uncommitted changes via `checkout`/`restore`/`stash drop`, shell edits of the guard files themselves, …).
- `.claude/hooks/file-guard.sh` — PreToolUse hook for the file tools (Read/Edit/Write/Grep, …): blocks every dotenv file **except** the placeholder templates `.env.example` / `.env.sample` / `.env.template` / `.env.dist`, and blocks the write tools on the baseline guard files so the agent cannot neutralize its own guard layer.
- `.claude/hooks/agent-guard.sh` — PreToolUse hook for the `Agent` tool: blocks any subagent call that would not run on Sonnet or Opus (a missing `model` inherits the main model), except the built-in `Plan`; `subagent_type: "fork"` is always blocked (and denied by `Agent(fork)` in `settings.json`). It resolves the model the way Claude Code does — call parameter, then the agent definition's `model:` frontmatter, then `CLAUDE_CODE_SUBAGENT_MODEL` — and tells Claude how to re-issue the call.
- `.claude/hooks/verify-gate.sh` — Stop hook that can enforce "tests green before finishing"; **dormant by default** (see below).
- `.claude/verify-commands.example` — template for opting in to the verify gate.
- `.claude/settings.json` — permission baseline (allow / ask / deny) plus the hook wiring. Sessions start in **`acceptEdits`** with the bare `Bash` rule allowed, so file edits and every Bash command that no deny/ask rule names run without a prompt — the deny/ask lists and the hooks are the boundary (see [Auto-accept](#auto-accept-what-still-prompts-or-blocks)). Ships as the **strict** profile by default, with a **relaxed** variant for isolated systems (see [Guard profiles](#guard-profiles)).
- `VERSION` + `bin/avn` — SemVer for the baseline and a pip-style manager CLI (`avn install` /
  `update` / `check`); each install stamps `.claude/avn-version` into the target repo.

**Repo layout:** the sources of everything above live under **`src/`** (`src/CLAUDE.md`,
`src/settings.json`, `src/hooks/`, `src/rules/`, `src/skills/`, `src/agents/`,
`src/verify-commands.example`) — deliberately with no `.claude` path segment, so the guard hooks
never block editing the sources.
The `CLAUDE.md` and `.claude/**` at this repo's root are its own **installed copy** (the baseline
dogfoods itself) and are **untracked** via `.gitignore` since v2.8.0. Refresh that copy with
`./install.sh .` — it only runs in an interactive terminal and asks for confirmation; no flag
bypasses it (see Threat model).

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
| `--profile strict\|relaxed` | Guard profile to install (default: keep the installed one, else strict). Switching **to** relaxed is interactive-only — see [Guard profiles](#guard-profiles). |
| `--no-color` | Plain output. |

Requirements: `tar` plus `curl` or `wget` on PATH (standard on Linux/macOS), and `python3` at
runtime — the guard hooks parse tool-call JSON with it and **fail closed**: without python3 every
Bash/file tool call **and every subagent spawn** is blocked until it is installed.

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

## Guard profiles

The baseline ships two guard profiles. The installer stamps the choice into `.claude/avn-version`
(`profile=strict|relaxed`), the hooks read that stamp at runtime, and the choice persists across
updates. Anything other than the exact value `relaxed` — a missing line, an old stamp, an unknown
value — reads as strict, in the hooks and in the installer alike.

| | `strict` (default) | `relaxed` |
| --- | --- | --- |
| Project-local secrets (`.env*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `credentials.json`, `secrets/`) | blocked (deny rules + hooks) | readable/editable |
| `printenv` / `echo $SECRET…` | blocked | allowed |
| `curl` / `wget` | denied | ask |
| `docker` / `docker compose` | ask | allowed |
| `psql` / `mysql` / `redis-cli` | ask | allowed |
| Package installs (`npm install`, `pip install`, …) | ask | allowed |
| Auto-accept (`permissions.defaultMode: acceptEdits` + bare `Bash` allow; deny/ask rules still block or prompt) | on | on |

**What never relaxes:** machine credentials (`~/.ssh`, `~/.aws`, `~/.kube`,
`~/.docker/config.json`, `kubeconfig`), `rm -rf` in any spelling, recursive `rm` outside the
project dir, `sudo`/`su`, push to main/master and force pushes, `curl | sh`, destructive
SQL/redis/mongo, `docker volume rm/prune`, broad `kubectl delete`, `git clean -f` /
`checkout --` / `restore` / `stash drop`, `npm install -g`, the subagent model policy
(`agent-guard.sh` plus the `Agent(fork)` deny), and the self-protection of the guard files
themselves.

```bash
avn install --profile relaxed    # or: ./install.sh --profile relaxed [DIR]  (interactive only)
avn install --profile strict     # tighten back — runs headless
```

Switching a repo **to** relaxed requires a real terminal plus an explicit confirmation; no flag
(`-y`/`--force` included) bypasses it. The profile stamp is a guard file, so an agent cannot flip
it through the normal edit tools or the obvious shell rewrites — but, like the rest of the guard
layer, it is a seatbelt, not a sandbox (see [Threat model](#threat-model)). Once stamped, updates
keep the profile (`avn update` on a relaxed repo stays relaxed, headless), and `avn check` /
`avn version` display it. Use relaxed **only** on isolated systems with no real secrets.

## Auto-accept: what still prompts or blocks

Since v2.10.0 both profiles set `permissions.defaultMode` to `acceptEdits` and allow the bare `Bash`
rule, so a governed session runs file edits and any Bash command **without a permission prompt**
unless a rule or hook says otherwise. Claude Code evaluates rules deny → ask → allow, first match
wins, so the boundary is exactly:

- **Blocked, no prompt:** every `deny` rule (`sudo`, `rm -rf`, force pushes, `curl`/`wget` in strict,
  secret paths, guard-file edits, `Agent(fork)`, …) and every PreToolUse hook rule (`bash-guard.sh`,
  `file-guard.sh`, `agent-guard.sh`). Deny rules win in every permission mode.
- **Still prompts:** every `ask` rule — `git push`, `git reset --hard`, `gh pr merge` / `gh release` /
  `gh repo delete`, package installs, docker compose, DB CLIs, `kubectl`/`helm`/`terraform`/`ansible`,
  cloud CLIs, `ssh`/`scp`/`rsync`, `systemctl` (strict; the relaxed profile drops the docker/DB/package
  prompts). An ask rule prompts even though the bare `Bash` allow rule also matches.
- **Runs silently:** everything else. That is the point — but it means "no prompt" is not approval:
  CLAUDE.md §5/§8 (ask before dependencies, infra, migrations, production, …) apply as if every call
  prompted. Add project-specific `ask`/`deny` rules in `.claude/settings.local.json` or your user
  settings when a repo needs more prompts; a user-level deny always wins over a project allow.

`defaultMode` is only honoured inside `permissions` — a top-level key is silently ignored (earlier
baselines shipped it there, so they never changed the mode). Switch modes per session with
Shift+Tab or `--permission-mode`; the project setting only picks the starting mode.

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

Flags after the directory pass through to `install.sh` (`--dry-run`, `-y`, `--force`,
`--profile`, …).

**Pinning**: `AVN_REF` (and `avn --ref`) accepts a branch **or a tag**, so a repo can stay on a
fixed release:

```bash
avn install --ref v2.1.0
AVN_REF=v2.1.0 curl -fsSL https://raw.githubusercontent.com/thieunv96/avn/master/install.sh | bash
```

### Releasing (maintainers)

All checks run locally — there is no CI on this repo yet, so a release is only as good as this
checklist:

1. Bump `VERSION` and `AVN_CLI_VERSION` in `bin/avn` (the test suite fails if they diverge).
2. Run all five suites: `bash tests/install-version-test.sh && bash tests/bash-guard-test.sh &&
   bash tests/file-guard-test.sh && bash tests/agent-guard-test.sh &&
   bash tests/settings-profile-test.sh` — plus
   `shellcheck install.sh bin/avn src/hooks/*.sh` if shellcheck is installed.
3. QA the relax menu once by hand in a scratch repo: `./install.sh --profile relaxed <dir>` —
   confirm the "No" default aborts and the "Yes" path installs the relaxed settings + stamp.
4. Optionally refresh this repo's own installed copy to dogfood the release: `./install.sh .`
   (interactive — the self-target gate asks for confirmation). The copy is untracked since v2.8.0,
   so there is nothing to commit; `./install.sh --dry-run .` afterwards must report no pending
   changes (no drift between `src/` and the root copy).
5. Commit, then tag and push: `git tag v<version> && git push origin master --tags`.

## Day-to-day usage

| Situation | Practice |
| --- | --- |
| Raw idea, no clear solution yet | `/brainstorm` — interviews you, researches options, produces a spec |
| Non-trivial task | Plan Mode + the spec-driven Clarify/Plan steps (CLAUDE.md §2) |
| Risky data operation (DB, volumes, prod-like systems) | Data-risk assessment first (CLAUDE.md §8); the hook blocks the worst commands outright |
| Finished coding | `/verify` — runs every layer the project defines, reports evidence |
| Before a PR / after non-trivial changes | `/code-review` — independent review in a fresh context |
| Changed a convention/pattern/signature | Pattern sweep (CLAUDE.md §3) — update or list all similar occurrences |
| Heavy research / exploration / web lookup | Delegate to a subagent with `model: "sonnet"` (or the shipped Sonnet agents); `agent-guard.sh` blocks anything else except `Plan` |

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
- **The relaxed profile is installer-gated.** The profile lives in the `.claude/avn-version`
  stamp, protected the same way as the other guard files: the Edit deny rule + file-guard block
  the edit tools, and bash-guard blocks the shell vectors (redirects, `sed`/`cp`/`tee`/… and
  `git checkout` targeting a guard file — matched by operand basename, so a `cd` or a bare
  filename does not dodge it). The hooks treat anything but the exact value `relaxed` as strict,
  and switching a repo to relaxed demands a human on a real terminal. This raises the bar; it is
  not an airtight boundary — a deliberately obfuscated command (an `eval`, a here-doc that writes
  the stamp) can still get through, the same seatbelt caveat as everything above. Platform caveat,
  pre-existing and independent of profiles: a `hooks` array in `.claude/settings.local.json`
  *replaces* the project hooks wiring entirely under Claude Code's settings precedence — the file
  is deny-listed for edits, but keep it in the reviewed surface.
- **No prompt is not approval.** `acceptEdits` plus the bare `Bash` allow rule remove most permission
  prompts, so the deny/ask lists and the hooks are the only deterministic boundary left; everything
  they do not name runs silently. CLAUDE.md §5/§8 still bind the agent, and a repo that needs more
  prompts adds its own `ask`/`deny` rules (see [Auto-accept](#auto-accept-what-still-prompts-or-blocks)).
- **agent-guard judges the requested model, not the served one.** If an `availableModels` allowlist
  substitutes a model, or a future Claude Code changes how built-in agents resolve theirs, the hook
  cannot see it. Forked skills (`context: fork`) do not pass through the `Agent` tool either —
  `/code-review` pins `model: opus` in its own frontmatter for that reason.
- **Hooks are code that runs on every developer machine.** Review the baseline (or pin a reviewed
  tag with `--ref`) before installing it fleet-wide; anyone who can change the source repo can
  change what runs in every governed session.
- **python3 is required.** bash-guard, file-guard and agent-guard fail closed without it (every
  guarded tool call — Bash, file tools, subagent spawns — is blocked); verify-gate fails open by
  design (a Stop gate must never brick a session).

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
- The project `permissions.defaultMode` (`acceptEdits`) sets the **starting** mode of sessions in a
  governed repo and outranks the user-level default; Shift+Tab or `--permission-mode` changes it per
  session. `auto` and `bypassPermissions` cannot be granted from project settings.
- Run the `curl | bash` bootstrap in a **normal terminal**, not inside a Claude Code session that is
  already governed by this baseline: the baseline's own deny-list blocks `curl`/`wget` and the hook
  blocks `curl | sh`. (Bootstrapping a fresh repo from a plain shell is the expected flow.)

## License

Proprietary — all rights reserved. Any use requires prior written permission from the author; see
[LICENSE](LICENSE).
