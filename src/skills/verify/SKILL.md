---
name: verify
description: Run the project's full verification (lint, typecheck, unit, integration, e2e where available) and produce the evidence report. Use before reporting a coding task as done, or when the user asks to verify.
---

# Verify: run everything, report evidence

## 1. Discover the project's commands

Check in this order and collect every verification command the project
actually defines — **never invent a command the repo does not define**:

1. `.claude/verify-commands` (one command per line, `#` = comment — the same
   file the verify-gate Stop hook reads).
2. `package.json` scripts (lint, typecheck, test, build, e2e).
3. `Makefile` targets.
4. `pyproject.toml` / `pytest.ini` / `setup.cfg` (pytest, ruff, mypy).
5. `go.mod` conventions (`go vet ./...`, `go test ./...`, `go build ./...`).
6. CI config (`.github/workflows/`, `.gitlab-ci.yml`, ...).
7. README instructions.

If a layer has no command, it is reported as "Not run", not faked.

## 2. Run every layer

Run the full suite for each discovered layer — lint/format, typecheck, unit,
integration, e2e — not just the tests near the change (CLAUDE.md §10).
Run the e2e layer with a hard timeout (e.g. `timeout 600 <e2e command>`) so a
hanging browser cannot stall the whole verification.

## 3. On failure

Fix it if it is within the task's scope; otherwise report the root cause and
stop. **Never delete, skip, or weaken a test to go green.**

Infrastructure failure ≠ test failure: if the e2e layer hangs or dies on
browser launch/interaction (probe an existing known-good spec to confirm — see
`.claude/rules/testing.md` "When the environment cannot run e2e"), report that layer as
`Not run: e2e — <probe evidence>; run <cmd> on CI/dev` and continue with the
remaining layers. Do not retry in a loop.

## 4. Report

Use exactly the CLAUDE.md §10 template — commands and results, not "it works":

```md
## Summary
## Changed
## Verified
- `command`: passed / failed because ...
- Not run: <layer> — no command configured
## Notes / Risks
```

If the repo wants this enforced at turn end, point the user to
`.claude/verify-commands.example` (copy it to `.claude/verify-commands`).
