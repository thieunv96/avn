# CLAUDE.md

This file defines how Claude Code should work in this repository. It covers **judgment** —
how to approach work, with quality at the center.

- Hard enforcement lives in `.claude/hooks/` and `.claude/settings.json` (these block dangerous
  actions deterministically). Do not restate or try to work around them.
- File-type-specific guidance lives in `.claude/rules/` and loads on demand (UI, realtime/
  performance, test-authoring conventions).

This is a shared quality baseline for Asilla projects. Keep instructions concrete and verifiable,
and refine this file like any frequently used prompt.

---

## 1. Communication and language

- Match the user's language in conversation: Vietnamese, Japanese, or English.
- Keep code, identifiers, branch names, commit messages, and technical constants in English unless the project already does otherwise.
- When there are multiple reasonable options, present them and recommend one.
- **When something is unclear, gather context before asking.** First read the relevant code and
  research the docs/web. Only ask the user when it is still unclear after that — typically for
  business intent, priorities, or trade-offs you cannot derive. **Do not guess, and do not ask
  what you can find out yourself.**

---

## 2. Development workflow

Default flow for non-trivial work: **Explore → Clarify → Plan → Implement → Verify → Review.**
For a small obvious fix (the diff fits in one sentence — typo, log line, rename), skip straight to
Implement, then Verify and report.

### Explore / brainstorm first

- Read the relevant existing code before writing any. Reuse existing patterns (see §3).
- **Always use a sub-agent for web research and for exploring a large or unfamiliar codebase.** It works in its own context and returns only the findings, keeping the main context focused. Reading a few known files directly is fine; broad searching and web research are not.
- Launch independent sub-agents in parallel when their searches do not depend on each other.
- **Run the research protocol before coding (see the `research` skill).** Classify each request by its intent and effect, not by keywords: if it could change code/config/data/behavior, run deep-research (always, via Explore), impact-research (always), and security-research (always); add web-research when the codebase or your knowledge is not enough to decide. Dispatch all of these via sub-agents, scaling their number to complexity. **When unsure whether a lens applies, run it — quality, stability, and accuracy outrank token cost.** The only exception is the one-sentence obvious fix above (no impact or security surface, no open unknown).

### Clarify the spec (spec-driven)

Before coding anything non-trivial, pin down the spec and write it down:

- **Acceptance criteria** as concrete expected-vs-actual examples (e.g. "Expected: returns 200 with user data. Actual today: returns 401").
- The **files/interfaces** involved.
- What is explicitly **out of scope**.
- The **end-to-end check** that will prove it works.

If business logic or requirements are unclear after exploring, ask the user (§1).

### Plan

State a short plan before large changes:

```md
## Plan
1. ...
## Assumptions
- ...
## Need confirmation
- ...
```

Non-trivial work includes multi-file changes, public API changes, database changes,
auth/permission changes, CI/CD changes, production/customer-system changes, performance-critical
code, or unclear business logic.

### Implement (test-driven, pragmatically)

- **Business logic and bug fixes: TDD.** Write tests from the acceptance criteria first, confirm
  they fail, then implement until they pass. Do not overfit to the tests.
- **ML, realtime, and exploratory work: pragmatic.** Strict unit-first TDD often does not fit;
  verify with metrics, fixtures, or integration tests instead (see `.claude/rules/`).
- **YOU MUST NOT delete, skip, or weaken tests to make a suite pass.** Fix the code, or raise the
  problem — never silence the test.

### Verify

Give yourself a check you can run and run it (see §10). **Show evidence over assertion**: report
the command and its output, not "it works".

### Review

- Review your own diff before reporting (`git diff`).
- For non-trivial changes, run an independent review in a fresh context — the `/code-review`
  skill, or a reviewer subagent — so the agent doing the work is not the only one grading it.

---

## 3. Inspect before editing

Before editing, inspect the relevant existing code and reuse what is there:

- Similar implementations, naming conventions, error handling.
- Existing test style, API response format, UI/component patterns, config/env patterns.

Do not implement from memory when the repository already has an example.

---

## 4. Scope and simplicity

- Make the smallest safe change that solves the task. Every changed line should trace back to the request.
- Do not add features, abstractions, configurability, dependencies, or refactors that were not requested.
- Do not clean up adjacent code, reformat unrelated files, rename files unless required, or delete unrelated dead code. Match the existing project style even if you would do it differently.
- If you notice unrelated problems, mention them in the final notes instead of fixing them silently.
- If the change becomes larger than expected, stop and explain why before continuing.

---

## 5. Ask before doing these things

Always ask before:

- Adding a new dependency, or adding/changing MCP/external tool configuration.
- Changing public API behavior.
- Changing database schema or migrations, or running migrations.
- Changing authentication or authorization logic.
- Touching CI/CD, deployment, or infrastructure config (e.g. `deploy/`, `infra/`, `ansible/`).
- Connecting to non-local systems, or performing any production-impacting action.
- Reading or handling secrets.
- Refactoring a broad area.
- Optimizing realtime/performance-critical code without benchmark data.

---

## 6. Git and repository etiquette

- Never commit directly to `main` or `master` (the hook also blocks pushes to them).
- Branch names: `feat/short-description`, `fix/…`, `chore/…`, `refactor/…`.
- Check `git status` / `git diff` before editing; review your own diff after. Do not overwrite the user's uncommitted changes.
- Commit only when the user explicitly asks. Use Conventional Commits in English and keep commits focused (do not mix unrelated changes):

```bash
feat: add camera status filter
fix: handle empty transcript result
refactor: simplify session cleanup
test: add validation tests
```

---

## 7. Secrets and credentials

The Bash hook blocks reading or printing secret material (`.env`, `*.key`, `*.pem`, `credentials*`,
`~/.ssh`, `~/.aws`, …). Do not try to work around it.

- Reference secrets **by variable name only**. Never read, print, grep, copy, encode, or summarize a secret value.
- If a task requires a secret, stop and ask the user to handle that step.
- Keep `.env.example` with placeholder values only (`API_KEY=replace-me`). Never put real values in examples, tests, logs, commit messages, or chat.

---

## 8. Production and customer systems

Assume any non-local system is production unless told otherwise (customer on-prem servers, edge
boxes, remote hosts, clusters, databases, devices, cameras, shared environments).

- **Default stance is read-only.** Any mutating action (deploy, restart, config push, DB write, migration, fleet/device update, file deletion, permission/infra change) requires an explicit instruction naming the target.
- Do not connect directly to production databases, or deploy manually from a Claude Code session, unless explicitly instructed.
- For edge devices, list the affected devices and get confirmation before any mass edit/push.

---

## 9. Realtime, performance, and UI

These are file-type-specific; detailed guidance loads on demand from `.claude/rules/`:

- **Realtime / performance-critical code** (`realtime-performance.md`): hot paths such as video
  decode, audio, inference loops, tracking, streaming/GStreamer, camera reconnect. Do not optimize
  without measuring first.
- **UI work** (`ui.md`): reuse existing components; prioritize readability and clear states for
  security operators.

---

## 10. Testing and verification

Verification is required before claiming a task is done. **Never claim completion beyond what you
actually verified.**

- Use the project's existing commands (from `package.json`, `Makefile`, `pyproject.toml`, `pytest.ini`, CI config, README). Do not invent commands the repo does not define.
- **Keep the entire test suite up to date.** When code changes, update every affected test to match the latest behavior — never leave stale, skipped, or commented-out tests.
- **Always run the full test suite after every change, however small** (plus lint / typecheck / build), and confirm it is green before reporting. Do not settle for running only the tests near your change.

### Test layers

Run every layer — the full suite — for every change, small or large:

- **Lint / format / typecheck** — always, for any code change.
- **Unit** — pure logic in isolation; fast. The default for business logic.
- **Integration** — several real components together (DB, services, pipeline stages).
- **End-to-end (e2e)** — a full user/flow path against the real running app. **For applications, always test through a real automation tool (Playwright, Puppeteer, Cypress, …)** that drives the actual UI/API — do not fake it with mocks.

A passing build, a linter, a script diffing output against a fixture, or a screenshot compared to a
design all count as verification gates.

### E2E on a shared environment

When e2e tests run against an environment shared with developers (not a throwaway/isolated one),
treat the data you create as a guest:

- **Tag and track everything Claude Code creates** — use a recognizable marker (a `claude-e2e-` prefix, a dedicated test account/namespace, or a recorded list of created IDs) so it is unambiguous which records are test data.
- **Clean up after the run**: delete exactly the data you created — nothing else. Never touch or delete pre-existing or developer data.
- If you cannot reliably isolate and remove what you create, **stop and ask** first; prefer an isolated or ephemeral environment when one is available.

### By change type

- **Bug fix — systematic debugging:** **reproduce first (always)** → isolate → find the root cause (not the symptom) → fix the smallest relevant path → **sweep the codebase for the same root cause/pattern elsewhere and fix every occurrence** (or list any you intentionally leave, with the reason) → add a regression test and run it → run broader checks. Report: root cause / other affected sites / fix / regression coverage / verified.
- **New feature:** verify the happy path, important edge cases, invalid input, and — for UI/API — empty/error states and permission/auth behavior. Add or update tests for it (cover application UI/flows with a real e2e test, see above); the only exception is a docs-only change or a project with no test setup.
- **Refactor:** preserve behavior. Run the same checks before and after when practical and confirm they are unchanged.

### Reporting

Report exactly what you ran and the result — not "tested" or "works". If you could not verify, say
so with the reason, the risk, and the recommended next step. Close with a brief summary:

```md
## Summary
- ...
## Changed
- ...
## Verified
- `command`: passed / failed because ...
- Not run: ... because ...
## Notes / Risks
- ...
```

If tests are missing or weak, say so and recommend the smallest useful test to add.

---

## 11. Definition of done

A task is done only when:

- The spec / acceptance criteria are met and the change stays within scope.
- Existing project patterns are followed; no unrelated files are modified.
- Tests are written and passing (or pragmatic verification was done for ML/realtime), and the **evidence is reported**.
- The diff has been reviewed.
- No secrets are exposed.
- No production/customer system was modified without explicit approval.
- Remaining risks are clearly reported.
