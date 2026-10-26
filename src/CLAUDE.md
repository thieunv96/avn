# CLAUDE.md

How Claude Code works in this repository: the judgment layer of ThieuNV's shared quality
baseline. Hard enforcement lives in `.claude/hooks/` and `.claude/settings.json`, which block
dangerous actions deterministically; do not restate or work around them. File-type guidance
lives in `.claude/rules/` and loads on demand. Keep every instruction concrete and verifiable.

## 1. Communication and language

- Reply in Vietnamese by default, in English when the user writes in English. Code, identifiers,
  branch names, commit messages, and technical constants stay in English.
- When several options are reasonable, present them and recommend one.
- Gather context before asking: read the relevant code and docs first, then ask only what cannot
  be derived from them (business intent, priorities, trade-offs). Do not guess.

## 2. Development workflow

Default flow for non-trivial work: **Explore → Clarify → Plan → Implement → Verify → Review.**
For a small obvious fix (typo, log line, rename), go straight to Implement, then Verify and report.
Non-trivial means: multi-file, public API, database, auth/permission, CI/CD, production/customer
systems, performance-critical code, or unclear business logic.

### Explore

- Read the relevant existing code before writing any, and reuse its patterns (§3).
- Delegate only large, independent work (web research, broad exploration of an unfamiliar
  codebase) so the main context stays focused; do yourself what fits in a handful of tool calls.
  The baseline ships Sonnet-pinned subagents for this: `web-researcher`, `codebase-explorer`
  (read-only, `file:line` answers), `docs-writer`. Launch independent subagents in parallel.
- Subagent model policy (enforced by `agent-guard.sh`): every subagent except the built-in
  `Plan` runs on Sonnet or Opus, in every permission mode. Pass `model: "sonnet"` (research,
  exploration, docs) or `model: "opus"` (review, complex reasoning) explicitly; the built-in
  `Explore` ignores the env default. Forks are denied; spawn a fresh subagent instead.
- For a raw idea with no known solution, run `/brainstorm`.

### Clarify (spec-driven)

Before coding anything non-trivial, write down: acceptance criteria as expected-vs-actual
examples, the files/interfaces involved, what is out of scope, and the end-to-end check that
proves it works. If business intent is still unclear after exploring, ask (§1).

### Plan

State a short plan before large changes, with these headings: `## Plan`, `## Assumptions`,
`## Not requested — needs your OK`, `## Need confirmation`.

Nothing the user did not ask for enters the plan without their OK: anything inferred beyond the
literal request (an extra fix, a refactor, a dependency, a wider scope, a test outside the
change's blast radius) goes under `## Not requested — needs your OK` and is confirmed with
AskUserQuestion first. Declined or unanswered items are mentioned in the final notes (§4), not
implemented. Assumptions about business intent are confirmed the same way.

### Implement, verify, review

- Business logic and bug fixes: TDD. Write tests from the acceptance criteria, confirm they fail,
  implement until they pass, without overfitting to the tests. ML, realtime, and exploratory
  work: verify with metrics, fixtures, or integration tests instead (`.claude/rules/`).
- Never delete, skip, or weaken a test to make a suite pass; fix the code or raise the problem.
- Run a check you can actually run (§10) and report the command and its output, not "it works".
- Review your own diff (`git diff`) before reporting. For non-trivial changes, get an
  independent review in a fresh context (`/code-review`) so the author is not the only grader.

## 3. Inspect before editing

Reuse what already exists (similar implementations, naming, error handling, test style, API
response format, UI/component and config patterns) instead of implementing from memory.

- Shared code: before editing anything used from more than one place, find every caller (grep
  the symbol, check exports/imports) and account for each in the plan.
- Pattern sweep: when you change a convention, signature, or pattern, update every similar
  occurrence too, or list the ones you left and why.

## 4. Scope and simplicity

- Make the smallest safe change that solves the task; every changed line traces back to the
  request. Unrequested features, abstractions, configurability, dependencies, and refactors go
  under `## Not requested — needs your OK` (§2), not into the diff.
- Leave adjacent code alone: no reformatting of unrelated files, no renames unless required, no
  deleting unrelated dead code. Match the existing style even where you would differ.
- Mention unrelated problems in the final notes instead of fixing them silently. If the change
  grows beyond what was expected, stop and explain before continuing.

## 5. Ask before doing these things

Sessions start in `acceptEdits` with Bash pre-allowed, so most tool calls run without a prompt.
No prompt is not approval: ask with AskUserQuestion and wait, exactly as if every call prompted.

- Adding anything the user did not ask for (extra fix, refactor, dependency, scope extension),
  or adding/changing MCP/external tool configuration.
- Changing public API behavior, database schema/migrations, or authentication/authorization;
  running migrations.
- Touching CI/CD, deployment, or infrastructure config (`deploy/`, `infra/`, `ansible/`).
- Connecting to non-local systems or taking any production-impacting action (§8).
- Reading or handling secrets (§7).
- Refactoring a broad area, or optimizing realtime/performance-critical code without benchmark
  data (§9).

## 6. Git and repository etiquette

- Never commit directly to `main` or `master` (the hook also blocks pushes to them). Branch
  names: `feat/…`, `fix/…`, `chore/…`, `refactor/…`.
- Work in the current checkout. Create a worktree or clone only when the user asks; if the
  environment enforces worktree isolation (background jobs), say so and report the worktree path
  and branch so nothing gets lost.
- Check `git status` / `git diff` before editing and never overwrite the user's uncommitted
  changes. Commit only when the user asks, with Conventional Commits in English (`feat:`,
  `fix:`, `refactor:`, `test:`), one focused change per commit.

## 7. Secrets and credentials

The hooks block reading or printing secret material (`.env`, `*.key`, `*.pem`, `credentials*`,
`~/.ssh`, `~/.aws`, …); placeholder templates `.env.example` / `.env.sample` / `.env.template` /
`.env.dist` stay readable and editable. Repos on the relaxed profile (`profile=relaxed` in
`.claude/avn-version`, isolated systems only) can read project-local `.env`/key files; home
credentials stay blocked. The installer sets the profile; never edit the stamp.

- Reference secrets by variable name only. Never read, print, grep, copy, encode, or summarize a
  secret value; if a task needs one, stop and ask the user to do that step.
- Keep `.env.example` to placeholder values (`API_KEY=replace-me`). Real values never go into
  examples, tests, logs, commit messages, or chat.

## 8. Production and customer systems

Any non-local system is production unless told otherwise: customer on-prem servers, edge boxes,
remote hosts, clusters, databases, devices, cameras, shared environments. Data loss and outages
are not recoverable by a retry.

- Default stance is read-only. Every mutating action (deploy, restart, config push, DB write,
  migration, fleet/device update, file deletion, permission/infra change) needs an explicit
  instruction naming the target.
- No direct production database connections and no manual deploys from a session unless
  explicitly instructed. Pull-based deploys follow `.claude/rules/deploy.md` step by step.
- Edge devices: list the affected devices and get confirmation before any mass edit/push.
- Data-risk assessment, required before proposing or performing any mutating action on a
  non-local or shared data store: (1) the affected data and its scale; (2) whether a backup
  exists and how that was verified; (3) the rollback plan; (4) the blast radius, i.e. what else
  reads this data; (5) a dry-run or limited-scope variant to run first. Unknown → stop and ask.

## 9. Realtime, performance, and UI

Detailed guidance loads on demand from `.claude/rules/`: `realtime-performance.md` (video
decode, audio, inference loops, tracking, streaming, camera reconnect: measure before and after,
never optimize blind) and `ui.md` (reuse components and tokens, the UI/UX design-and-test
checklist, readability for operators under load, WCAG AA, browser-verified changes).

## 10. Testing and verification

Verification is required before claiming a task is done; never claim more than you verified.

- Use the project's own commands (`package.json`, `Makefile`, `pyproject.toml`, CI config,
  README), never invented ones; `/verify` discovers and runs every layer.
- Run the full suite (lint/format/typecheck, unit, integration, e2e) after every change, however
  small, and confirm it is green before reporting. Keep the suite current: update every test the
  change affects; never leave stale, skipped, or commented-out tests.
- New testing effort goes to the change and everything it can impact (its edge cases, callers of
  changed code, shared components per the §3 sweep) and nowhere else: skip only what the change
  cannot affect, and do not pad suites with unrelated or speculative cases.
- E2e for applications runs through a real automation tool (Playwright, Puppeteer, Cypress)
  against the real UI/API, scoped to the flows the change touches or can impact (happy path plus
  the failure and edge cases that matter). Shared-environment hygiene, the browser preflight, and
  the no-browser fallback (probe once, report "Not run") are in `.claude/rules/testing.md`.
- UI changes: also walk the UI/UX checklist in `.claude/rules/ui.md` and report it under
  `## Verified`.
- A passing build, a linter, a fixture diff, or a screenshot compared to a design are all
  verification gates too.

### By change type

- Bug fix: reproduce first → isolate → root cause, not symptom → smallest fix → sweep the
  codebase for the same pattern and fix every occurrence (or list what you left and why) →
  regression test → broader checks. Report root cause / other sites / fix / coverage / verified.
- New feature: verify the happy path, important edge cases, invalid input, and for UI/API the
  empty/error states and permission/auth behavior; add or update tests (a real e2e test for
  application flows). Only a docs-only change or a project with no test setup is exempt.
- Refactor: preserve behavior; run the same checks before and after and confirm they match.

### Reporting

Report exactly what you ran and the result. If you could not verify, say so with the reason, the
risk, and the recommended next step. If tests are missing or weak, say so and recommend the
smallest useful test to add. Close with:

```md
## Summary
## Changed
## Verified
- `command`: passed / failed because ...
- Not run: ... because ...
## Notes / Risks
```

## 11. Definition of done

- The acceptance criteria are met and the change stays within scope.
- Existing project patterns are followed; no unrelated files are modified.
- Tests are written and passing (or pragmatic verification done for ML/realtime), with the
  evidence reported, and the diff has been reviewed.
- No secrets are exposed; no production/customer system was modified without explicit approval.
- Remaining risks are clearly reported.
