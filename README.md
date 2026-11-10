# ThieuNV Claude Code baseline

A shared Claude Code configuration baseline for ThieuNV's projects:

- `CLAUDE.md` — quality-focused working agreement (workflow, scope, secrets, production, testing).
- `.claude/rules/` — path-scoped rules that load on demand: `realtime-performance.md`, `testing.md`, `migrations.md`, `deploy.md`.
- `.claude/skills/` — invocable workflows: `/brainstorm` (idea → spec), `/code-review` (independent review in a fresh context, pinned to Opus), `/verify` (run all verification layers, report evidence).
- **Website UI** — no UI rules of its own since v2.12.0: `settings.json` enables the third-party `taste-skill` plugin, whose `design-taste-frontend` skill builds and browser-checks websites and landing pages (see [Website UI](#website-ui-the-design-taste-frontend-plugin)).
- `.claude/agents/` — task-scoped subagents pinned to **Sonnet** (cheaper/faster for heavy delegated work): `web-researcher` (web/docs research), `codebase-explorer` (read-only source exploration with `file:line`), `docs-writer` (documentation grounded in the code). **Subagent model policy:** every subagent except the built-in `Plan` must run on Sonnet or Opus — in every permission mode, plan mode included — and forks are denied; `agent-guard.sh` enforces it (below), and `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in `settings.json` gives model-less agents a compliant default (the built-in `Explore` ignores it and needs an explicit `model`).
- `.claude/hooks/bash-guard.sh` — PreToolUse hook that deterministically blocks dangerous Bash commands (push to main — including a bare `git push` while the checkout sits on main/master, `rm -rf` in any flag order/case plus recursive `rm` outside the project dir, secret reads, destructive SQL/redis/mongo/docker/kubectl, `git clean -f`, discarding uncommitted changes via `checkout`/`restore`/`stash drop`, shell edits of the guard files themselves, …).
- `.claude/hooks/file-guard.sh` — PreToolUse hook for the file tools (Read/Edit/Write/Grep, …): blocks every dotenv file **except** the placeholder templates `.env.example` / `.env.sample` / `.env.template` / `.env.dist`, and blocks the write tools on the baseline guard files so the agent cannot neutralize its own guard layer.
- `.claude/hooks/agent-guard.sh` — PreToolUse hook for the `Agent` tool: blocks any subagent call that would not run on Sonnet or Opus (a missing `model` inherits the main model), except the built-in `Plan`; `subagent_type: "fork"` is always blocked (and denied by `Agent(fork)` in `settings.json`). It resolves the model the way Claude Code does — call parameter, then the agent definition's `model:` frontmatter, then `CLAUDE_CODE_SUBAGENT_MODEL` — and tells Claude how to re-issue the call.
- `.claude/hooks/verify-gate.sh` — Stop hook that can enforce "tests green before finishing"; **dormant by default**, and it re-runs the commands only when the working tree changed since the last green run (see below).
- `.claude/verify-commands.example` — template for opting in to the verify gate.
- `.claude/settings.json` — permission baseline (allow / ask / deny) plus the hook wiring. Sessions start in **`acceptEdits`** with the bare `Bash` rule allowed, so file edits and every Bash command that no deny/ask rule names run without a prompt — the deny/ask lists and the hooks are the boundary (see [Auto-accept](#auto-accept-what-still-prompts-or-blocks)). Ships as the **strict** profile by default, with a **relaxed** variant for isolated systems (see [Guard profiles](#guard-profiles)). Both profiles also switch off AI attribution on commits and pull requests and declare the `taste-skill` plugin.
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
(idempotent).

### The installed copy is not committed

The installer keeps `CLAUDE.md` and `.claude/` out of the target repo's history, so each
developer runs it in their own checkout:

- **`.gitignore`** gets `CLAUDE.md` and `.claude/`, plus `CLAUDE.local.md`,
  `.claude/settings.local.json` and the `.bak` patterns (the file is created if needed). Since
  v2.12.0 the two patterns match at every directory depth; an update replaces the root-anchored
  `/CLAUDE.md` and `/.claude/` that v2.11.0 wrote. A last line without a trailing newline is
  handled. A line an older installer glued together (for example `.env/CLAUDE.md`, which leaves
  `.env` un-ignored) is reported with its line number and left for you to split.
- **A copy that is already committed** is not affected by `.gitignore`. When `CLAUDE.md` or
  anything under `.claude/` at the target root is tracked (repos installed before v2.11.0), the
  installer offers to untrack it with `git rm -r --cached`; the files stay on disk. A terminal run
  asks, `-y` and `--force` accept, a headless run without a flag only prints the command, and
  `--dry-run` reports. It waits while a merge or rebase is in progress and never passes `-f`.
  Commit the staged removal together with `.gitignore`.

> **Know what that removal does to other checkouts before you commit it.** Git deletes
> `CLAUDE.md` and `.claude/` from every clone that pulls the commit, and from your own working
> tree whenever you switch between a branch that still tracks the copy and one that does not.
> Run `avn install` again afterwards; `avn check` exiting 2 with "no version stamp" is the sign.
> Files of your own under `.claude/` (a `verify-commands`, your own skills) are untracked with the
> rest and the installer cannot restore them, so it lists them first: share them another way
> before committing. The patterns also hide a new `CLAUDE.md` or `.claude/` in any subdirectory
> (`git add -f` the ones you want tracked), and worktrees and cloud sessions start without the
> baseline.

When a file would be overwritten, you get an arrow-key menu asking whether to back it up first
(default: **Yes** → `<file>.bak`). Control it non-interactively with flags:

| Flag | Effect |
| --- | --- |
| `--dry-run` | Preview only; change nothing. |
| `--backup` / `--no-backup` | Choose backup behavior without prompting. |
| `-y`, `--yes` | Don't prompt; use defaults (backup = yes, untrack a committed copy = yes). |
| `--force` | Overwrite without backups and without prompts; also untracks a committed copy. |
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
install writes a stamp to `.claude/avn-version` in the target repo (version + source + profile).
The installed copy, stamp included, is gitignored since v2.11.0 and untracked on update since
v2.12.0 (see [The installed copy is not committed](#the-installed-copy-is-not-committed)): each
developer runs `avn install` in their own checkout, and `avn check` tells them when it is outdated
or missing. The installer header and summary show the version change (`2.0.0 → 2.1.0`).

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
2. Run all six suites: `bash tests/install-version-test.sh && bash tests/bash-guard-test.sh &&
   bash tests/file-guard-test.sh && bash tests/agent-guard-test.sh &&
   bash tests/settings-profile-test.sh && bash tests/verify-gate-test.sh` — plus
   `shellcheck install.sh bin/avn src/hooks/*.sh` if shellcheck is installed.
3. When `src/` markdown changed (CLAUDE.md, rules, skills, agents): open Claude Code in this repo
   and run `/doctor prompt-audit` (Claude Code ≥ 2.1.283) — it flags instructions written for
   older models, dead references, and contradictions across those files.
4. QA the two menus once by hand in a scratch repo, since no test can drive a terminal:
   `./install.sh --profile relaxed <dir>` — the "No" default aborts and "Yes" installs the relaxed
   settings + stamp; and `./install.sh <repo that committed CLAUDE.md>` — "Yes" stages the removal
   and "No" leaves the index alone and prints the command.
5. Optionally refresh this repo's own installed copy to dogfood the release: `./install.sh .`
   (interactive — the self-target gate asks for confirmation). The copy is untracked since v2.8.0,
   so there is nothing to commit; `./install.sh --dry-run .` afterwards must report no pending
   changes (no drift between `src/` and the root copy).
6. Commit, then tag and push: `git tag v<version> && git push origin master --tags`.

## Day-to-day usage

| Situation | Practice |
| --- | --- |
| Raw idea, no clear solution yet | `/brainstorm` — interviews you, researches options, produces a spec |
| Non-trivial task | Plan Mode + the spec-driven Clarify/Plan steps (CLAUDE.md §2) |
| Risky data operation (DB, volumes, prod-like systems) | Data-risk assessment first (CLAUDE.md §8); the hook blocks the worst commands outright |
| Finished coding | `/verify` — runs every layer the project defines, reports evidence |
| Asking for a commit, push or PR | Claude reuses the verification already done in the session, or asks first when there is none (CLAUDE.md §6); commits and PRs carry no AI attribution |
| Website or landing page | `design-taste-frontend` (plugin `taste-skill`) — plans, builds and checks the page in a real browser, then reports a `GATE:` line |
| Before a PR / after non-trivial changes | `/code-review` — independent review in a fresh context |
| Changed a convention/pattern/signature | Pattern sweep (CLAUDE.md §3) — update or list all similar occurrences |
| Heavy research / exploration / web lookup | Delegate to a subagent with `model: "sonnet"` (or the shipped Sonnet agents); `agent-guard.sh` blocks anything else except `Plan` |

## Website UI: the `design-taste-frontend` plugin

Since v2.12.0 the baseline ships no UI rules of its own. For **websites and landing pages** it
relies on [`taste-skill`](https://github.com/Leonxlnx/taste-skill) (MIT), whose
`design-taste-frontend` skill plans the page, builds it, and checks it in a real headless browser
before finishing. In-app screens (dashboards, tables, forms) are outside that skill; they follow
the project's own components and patterns (CLAUDE.md §3).

`settings.json` registers the marketplace and enables the plugin, but Claude Code does not fetch a
plugin that is enabled only in project settings. Install it once per machine, from a normal
terminal:

```bash
claude plugin install taste-skill@taste-skill --scope user
```

`--scope user` makes the plugin available in every project on the machine; use `--scope project`
to install it for this checkout only.

- **Requirements:** Node 22+ and Chrome, Edge or Chromium. Until the plugin is installed, `/plugin`
  lists it under **Errors** as "enabled in project settings but isn't installed here"; that is
  harmless.
- **Use:** ask for a site or landing page, or call `/taste-skill:design-taste-frontend`. Its
  finish gate prints a `GATE:` line, which goes under `## Verified` in the report. The skill
  registers its own Stop hook only after it has been used in a session.
- **Updates:** the marketplace entry sets `autoUpdate`, so an installed copy follows upstream.
- **Opt out in one checkout:** `{"enabledPlugins": {"taste-skill@taste-skill": false}}` in
  `.claude/settings.local.json`. The project setting outranks a `false` in your user settings.

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
- **A third-party plugin is in the trusted set.** The baseline declares the
  `Leonxlnx/taste-skill` marketplace with auto-update and enables its plugin. Once a developer
  installs it, its skill — and the Stop hook that skill registers when used — run that
  repository's current code. Review it like the baseline, or opt out per checkout (see
  [Website UI](#website-ui-the-design-taste-frontend-plugin)).
- **verify-gate remembers a pass by content.** The pass file in the git dir is writable by the
  agent, like the block counter in `$TMPDIR` — the same seatbelt caveat. Ignored files (`.env`,
  `node_modules/`, build output) are not part of the fingerprint.
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

Since v2.12.0 it also skips a Stop when the working tree holds the same content, as git would
commit it, as the last run that passed — so committing, staging or asking a question does not run
the suite again. The hook fingerprints that content (tracked and untracked files; ignored ones are
excluded) on a copy of the index, without writing to the real index or `.git/objects`. A pass is
remembered only when the commands left the tree as they found it. There is no reuse — the gate
then behaves as before — for a repo with submodules or a sparse checkout, and when more than
32 MiB of untracked or modified files would have to be hashed at every Stop
(`AVN_VERIFY_FP_MAX_BYTES` changes the cap). Clean filters still run while fingerprinting, so Git
LFS may store objects for changed files. Delete `<git dir>/avn-verify-gate.pass` to force a run.
Each command now reads stdin from `/dev/null`, so one that reads stdin can no longer swallow the
commands listed after it.

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

> Earlier versions shipped a research workflow (`.claude/agents/{impact,security}-research.md` and
> `.claude/skills/research/`), a `/map` skill, and `.claude/rules/ui.md` (dropped in v2.12.0). A
> normal re-run deletes those — but only when the file content is byte-identical (sha256) to a
> version the baseline shipped. A same-named file you wrote or edited yourself is kept, and your
> own agents or skills are never touched. Preview with `--dry-run`.

## Uninstalling

`avn uninstall [DIR]` (or `./install.sh --uninstall [DIR]`, or the `curl | bash` one-liner with
`-s -- --uninstall`) removes exactly what the baseline installed:

- Files **byte-identical to the shipped release** are deleted — nothing is lost, a reinstall
  restores them. Anything you modified (a customized `CLAUDE.md`, a merged `settings.json`) is
  **kept** with a warning.
- Your own files are never touched: `.claude/verify-commands`, `.claude/settings.local.json`,
  `CLAUDE.local.md`, and any agents/skills you added yourself.
- Every `.gitignore` line any release of the installer appended is taken back (the file keeps its
  mode and stays a symlink if it was one), and `.claude/` directories are pruned only when empty.
  Uninstalling does not re-track anything an install untracked.

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
- Commits and pull requests made in a governed session carry no AI attribution: both profiles set
  `attribution.commit` and `attribution.pr` to empty strings. Keep the object form — an older
  Claude Code that meets `attribution: false` skips the whole settings file, guard rules included.
- Run the `curl | bash` bootstrap in a **normal terminal**, not inside a Claude Code session that is
  already governed by this baseline: the baseline's own deny-list blocks `curl`/`wget` and the hook
  blocks `curl | sh`. (Bootstrapping a fresh repo from a plain shell is the expected flow.)

## License

Proprietary — all rights reserved. Any use requires prior written permission from the author; see
[LICENSE](LICENSE).
