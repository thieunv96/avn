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

These complement the testing workflow in `CLAUDE.md` (§2 Implement, §10 Testing). They cover how to
write a test once you are in a test file, and the practical side of running e2e.

- **Arrange-Act-Assert**: set up, perform one action, assert the outcome.
- Name the test after the behavior it checks (e.g. `returns_401_when_token_expired`), not the function name.
- One behavior per test. Keep tests independent — no shared mutable state, no reliance on order.
- **Deterministic**: no dependence on wall-clock time, network, randomness, or external services. Inject or fake those.
- **Avoid over-mocking**: mock at the boundary (I/O, network, time), not internal logic. Over-mocked tests pass while the code is broken.
- **Stay on target**: cover the behavior under change and everything it can impact — happy path, its edge cases, and affected callers/shared components. Skip only what the change cannot affect: no tests for unrelated behavior or speculative edge cases, and reuse existing fixtures/helpers instead of building new test infrastructure.

## Which layer

- **Unit** — pure logic in isolation; fast; the bulk of tests.
- **Integration** — several real components together (DB, service, pipeline stage).
- **End-to-end** — a full user/flow path through a real automation tool (Playwright/Puppeteer/Cypress); few, high-value, scoped to the flows the change touches or can impact.

## E2E on a shared environment

When e2e tests run against an environment shared with developers (not a throwaway/isolated one),
treat the data you create as a guest:

- **Tag and track everything Claude Code creates** — use a recognizable marker (a `claude-e2e-` prefix, a dedicated test account/namespace, or a recorded list of created IDs) so it is unambiguous which records are test data.
- **Clean up after the run**: delete exactly the data you created — nothing else. Never touch or delete pre-existing or developer data.
- If you cannot reliably isolate and remove what you create, **stop and ask** first; prefer an isolated or ephemeral environment when one is available.

## Browser automation preflight

Before concluding that e2e/screenshots cannot run, rule out the fixable causes once:

1. **Playwright pinned?** Check `package.json` for `@playwright/test` (or `playwright`). If it is
   not a dependency, ask the user to pin it — a bare `npx playwright` downloads a transient copy
   on every run and fails without network.
2. **Browsers installed?** Check with `npx playwright --version` and `ls ~/.cache/ms-playwright`.
   If browsers are missing, run `npx playwright install chromium` once (asks for approval;
   ~150 MB download).
3. **Run headless-friendly**: prefer `--reporter=line` and a hard cap like
   `--global-timeout=120000` so a hang fails fast instead of blocking the session.

## When the environment cannot run e2e

Some environments (sandboxed sessions, headless CI shells) cannot drive a browser. Detect this
quickly instead of fighting it:

1. **Probe once, time-boxed**: after the preflight above, run ONE existing known-good spec (a
   smoke/login spec) with a hard timeout (e.g. `npx playwright test <smoke-spec>
   --global-timeout=120000 --reporter=line`). If a spec that passes on CI hangs or fails on
   browser launch/interaction here, the environment is the cause — not the feature, not the spec.
2. **Do not loop on it**: no repeated retries, no repeated browser reinstalls (the preflight
   install runs at most once), no rewriting the spec to dodge the hang. One retry outside the
   sandbox (with user approval) is the only escalation.
3. **Still write the e2e spec** for the change so CI/dev covers it; verify locally with the
   strongest layers that do run (typecheck, build, unit/component/integration, API-level checks).
4. **Report it as "Not run"** with the probe evidence and the exact command for the user to run
   on CI/dev — e.g. `Not run: e2e — browser automation hangs in this sandbox (probe:
   auth.spec.ts timed out); run 'pnpm e2e' on CI or a dev machine.` This is an honest, complete
   report — not a failure to verify.
