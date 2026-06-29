---
paths:
  - "**/*.{test,spec}.{ts,tsx,js,jsx}"
  - "**/test_*.py"
  - "**/*_test.py"
  - "**/tests/**"
  - "**/conftest.py"
---

# Test-authoring conventions

These complement the testing workflow in `CLAUDE.md` (§2 Implement, §10 Testing). They cover how to
write a test once you are in a test file.

- **Arrange-Act-Assert**: set up, perform one action, assert the outcome.
- Name the test after the behavior it checks (e.g. `returns_401_when_token_expired`), not the function name.
- One behavior per test. Keep tests independent — no shared mutable state, no reliance on order.
- **Deterministic**: no dependence on wall-clock time, network, randomness, or external services. Inject or fake those.
- **Avoid over-mocking**: mock at the boundary (I/O, network, time), not internal logic. Over-mocked tests pass while the code is broken.

## Which layer

- **Unit** — pure logic in isolation; fast; the bulk of tests.
- **Integration** — several real components together (DB, service, pipeline stage).
- **End-to-end** — a full user/flow path through a real automation tool (Playwright/Puppeteer/Cypress); few, high-value.
