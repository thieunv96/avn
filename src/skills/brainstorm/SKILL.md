---
name: brainstorm
description: Turns a raw idea, vague feature request, or problem with no clear solution into a validated spec. Use when the user brings an idea or asks "how should we approach this". Interviews for business intent, researches the codebase and options in parallel, presents 2–3 approaches with a recommendation, and writes the spec.
argument-hint: [raw idea or problem]
---

# Brainstorm: idea → validated spec

Run the four steps in order. The deliverable is a spec, not code.

## 1. Interview (business intent only)

Use AskUserQuestion, at most 2 rounds of up to 4 questions, called on its own rather than batched
with other tool calls. Skip what the prompt already answers; technical facts are researched in
step 2, not asked (CLAUDE.md §1). Cover: the problem and goal (what changes for whom), who is
affected, fixed constraints (deadline, compatibility, tech choices), measurable success criteria,
explicit non-goals, priority and rough size.

The interview counts only when a human actually answered. A tool error, an empty result
(`User has answered your questions: .`), or a timeout message ("No response after 60s … proceed
using your best judgment") is not an answer: silence is not consent. In that case, or when
AskUserQuestion is unavailable (subagent, forked context, headless run), restate the questions as
plain text, end your turn, and wait for the user. The same applies to the option choice in step 3.

## 2. Research (parallel, read-only)

Launch independent Explore subagents in one batch (`model: "sonnet"`), one per angle:

- Similar existing features/implementations in this codebase to reuse.
- Integration points and conventions the solution must follow.
- Callers/usages of anything that would change (cross-impact).

Add `web-researcher` only when the codebase plus your own knowledge is insufficient; findings
cite URLs.

## 3. Options

Present 2–3 approaches in a short table (effort / risk / fit with existing patterns), recommend
one with the reason, and let the user pick via AskUserQuestion.

## 4. Spec

```md
# Spec: <title>
## Problem
## Goal
## Acceptance criteria
- Expected: ... / Actual today: ...
## Files & interfaces involved
## Out of scope
## End-to-end check (how we prove it works)
## Assumptions
- Confirmed: ...
- Open (must resolve before implementing): ...
## Risks & data impact
<required when any data store is touched; see CLAUDE.md §8>
```

Offer to save it to `docs/specs/<yyyy-mm-dd>-<slug>.md` (ask before creating the file). Then stop
with the spec, or continue to the Plan step of CLAUDE.md §2 if the user asks.
