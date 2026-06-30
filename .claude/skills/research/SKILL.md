---
name: research
description: "Pre-implementation research protocol. Use at the start of any task that could change code, config, data, or behavior — bug fix, feature, refactor, or brainstorm — even when the request has no such keyword. Runs deep, web, impact, and security research via subagents before implementing."
---

# Research before implementing

The standard pre-implementation research protocol for Asilla work. It complements
`CLAUDE.md` §2 (Explore → Clarify → Plan): run it **before** writing code so the plan
rests on evidence, not assumptions.

**Priority, always: quality, stability, accuracy — above token cost. When unsure
whether a research lens applies, run it.**

## Step 0 — Triage (do this first; do NOT rely on keywords)

Classify the request by its *intent and effect*, not by the words used:

1. Could it change code, config, data, or behavior? (Includes exploratory "what if
   we…" / brainstorm questions that would lead to a change.)
2. Could its subject plausibly touch an **impact** zone — multiple files, a public
   API, the database/schema, auth, UI, or realtime/performance?
3. Could its subject plausibly touch a **security/data** zone — auth, permissions,
   secrets, customer data, APIs, MCP/external tools, CI/CD, deploy, infra, production?

Judge by the subject matter, not the phrasing. **When you cannot be sure a lens
applies, assume it does and run it.**

**Narrow escape-hatch — skip the protocol only when ALL hold:** the change provably
fits in one sentence (typo, log line, rename), touches no impact or security surface,
and leaves no open unknown. Otherwise, research.

## The four lenses

| Lens | When | How |
| --- | --- | --- |
| **deep-research** | Always | built-in **Explore** subagent(s), read-only |
| **impact-research** | Always | `impact-research` subagent |
| **security-research** | Always | `security-research` subagent |
| **web-research** | When the codebase or your own knowledge is not enough to understand or decide — even a small point | a subagent with web tools (Explore / general-purpose) |

All four run in **subagents** (isolated context; only findings return). Right-size the
**depth and number** of subagents to the task's complexity — never skip a lens to save
effort.

## Dispatch

- **deep-research** — delegate codebase investigation to the built-in **Explore** agent
  (read-only, breadth-first, returns findings with `file:line`). For a complex task,
  **fan out several Explore agents in parallel**, one per subsystem; for a focused task,
  one is enough.
- **impact-research** — delegate to the `impact-research` subagent to map the blast
  radius: callers/dependents, API/data contracts, affected tests, migrations, backward
  compatibility, realtime/performance surfaces.
- **security-research** — delegate to the `security-research` subagent: auth/permissions,
  secret exposure, PII/customer-data handling, injection, API/MCP/supply-chain, CI/CD and
  infra risk. It references secrets **by name only** — never reads or prints values.
- **web-research** — only when the codebase plus your existing knowledge are not enough to
  understand or decide. Delegate to a subagent with web tools and require findings to cite
  **source URLs**.

Launch independent subagents **in parallel** (one batch) when their work does not depend
on each other.

## Synthesize

Fold every subagent's findings into the **Clarify the spec / Plan** step of `CLAUDE.md` §2
before coding:

- Acceptance criteria (expected vs actual), files/interfaces involved, what is out of
  scope, the end-to-end check.
- Impact summary and risk level; security findings and anything that needs the user's
  approval first (`CLAUDE.md` §5, §8).
- Open questions — resolve with more research, or ask the user (`CLAUDE.md` §1).

Research is **read-only**: it never mutates files, connects to non-local systems, or
handles secret values (`CLAUDE.md` §7, §8).
