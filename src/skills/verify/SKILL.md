---
name: verify
description: Runs the project's full verification (lint, typecheck, unit, integration, e2e where available) and produces the evidence report. Use before reporting a coding task as done, or when the user asks to verify.
---

# Verify: run everything, report evidence

## 1. Discover the project's commands

Collect every verification command the project actually defines, in this order; never invent a
command the repo does not define:

1. `.claude/verify-commands` (one command per line, `#` = comment; the file the verify-gate Stop
   hook reads).
2. `package.json` scripts (lint, typecheck, test, build, e2e).
3. `Makefile` targets.
4. `pyproject.toml` / `pytest.ini` / `setup.cfg` (pytest, ruff, mypy).
5. `go.mod` conventions (`go vet ./...`, `go test ./...`, `go build ./...`).
6. CI config (`.github/workflows/`, `.gitlab-ci.yml`, …).
7. README instructions.

A layer with no command is reported as "Not run", not faked.

## 2. Run every layer

Run the full suite for each discovered layer (lint/format, typecheck, unit, integration, e2e),
not only the tests near the change. Run e2e under a hard timeout (`timeout 600 <e2e command>`) so
a hanging browser cannot stall the run. If the change has a UI, also walk the UI/UX checklist in
`.claude/rules/ui.md` §2 and report both of its groups.

## 3. On failure

Fix it when it is within the task's scope; otherwise report the root cause and stop. Never
delete, skip, or weaken a test to go green.

Infrastructure failure is not a test failure: when the e2e layer hangs or dies on browser
launch/interaction, probe one known-good spec (`.claude/rules/testing.md`, "When the environment
cannot run e2e"), report that layer as `Not run: e2e — <probe evidence>; run <cmd> on CI/dev`,
and continue with the remaining layers. Do not retry in a loop.

## 4. Report

Commands and results, in the CLAUDE.md §10 template:

```md
## Summary
## Changed
## Verified
- `command`: passed / failed because ...
- Not run: <layer> — no command configured
## Notes / Risks
```

To enforce this at turn end, copy `.claude/verify-commands.example` to `.claude/verify-commands`.
