---
paths:
  - "**/*.{test,spec}.{ts,tsx,js,jsx}"
  - "**/test_*.py"
  - "**/*_test.py"
  - "**/tests/**"
  - "**/conftest.py"
  - "**/playwright.config.*"
---

# Test-authoring conventions

Complements `CLAUDE.md` §2 (Implement) and §10 (Testing): how to write a test once you are in a
test file, and the practical side of running e2e.

- Arrange-Act-Assert: set up, perform one action, assert the outcome.
- Name the test after the behavior it checks (`returns_401_when_token_expired`), not the function.
- One behavior per test; tests are independent, with no shared mutable state or order dependence.
- Deterministic: no wall-clock time, network, randomness, or external services; inject or fake
  them.
- Mock at the boundary (I/O, network, time), not internal logic; over-mocked tests pass while the
  code is broken.
- Cover the behavior under change and everything it can impact (happy path, its edge cases,
  affected callers and shared components); reuse existing fixtures/helpers instead of building
  new infrastructure.

## Which layer

- Unit: pure logic in isolation; fast; the bulk of tests.
- Integration: several real components together (DB, service, pipeline stage).
- End-to-end: a full user/flow path through a real automation tool (Playwright/Puppeteer/
  Cypress); few, high-value, scoped to the flows the change touches or can impact. UI changes
  also walk the UI/UX checklist in `.claude/rules/ui.md` §2 and report it (ui.md §4).

## E2E on a shared environment

When e2e runs against an environment shared with developers, treat the data you create as a
guest:

- Tag everything you create (a `claude-e2e-` prefix, a dedicated test account/namespace, or a
  recorded list of IDs) so test data is unambiguous.
- Clean up after the run: delete exactly what you created, never pre-existing or developer data.
- If you cannot reliably isolate and remove what you create, stop and ask first; prefer an
  isolated or ephemeral environment when one exists.

## Browser automation preflight

Before concluding that e2e/screenshots cannot run, rule out the fixable causes once:

1. Playwright pinned? Check `package.json` for `@playwright/test` (or `playwright`); if absent,
   ask the user to pin it, because a bare `npx playwright` downloads a transient copy and fails
   offline.
2. Browsers installed? `npx playwright --version` and `ls ~/.cache/ms-playwright`; if missing,
   run `npx playwright install chromium` once (asks for approval; ~150 MB).
3. Run headless-friendly: `--reporter=line` plus a hard cap such as `--global-timeout=120000` so
   a hang fails fast.

## When the environment cannot run e2e

Sandboxed sessions and headless CI shells may not drive a browser. Detect it once:

1. Probe once, time-boxed: run one existing known-good spec (smoke/login) with a hard timeout
   (`npx playwright test <smoke-spec> --global-timeout=120000 --reporter=line`). If a spec that
   passes on CI hangs or fails on browser launch here, the environment is the cause.
2. Do not loop: no repeated retries, no repeated browser installs, no rewriting the spec to dodge
   the hang. One retry outside the sandbox, with user approval, is the only escalation.
3. Still write the e2e spec for the change so CI/dev covers it; verify locally with the strongest
   layers that do run (typecheck, build, unit/component/integration, API-level checks).
4. Report it as "Not run" with the probe evidence and the exact command for the user, e.g.
   `Not run: e2e — browser automation hangs in this sandbox (probe: auth.spec.ts timed out); run
   'pnpm e2e' on CI or a dev machine.`
