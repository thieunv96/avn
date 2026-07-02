---
name: brainstorm
description: Turn a raw idea or vague problem into a validated spec. Use when the user brings an idea, feature request, or problem without a clear solution, or asks "how should we approach this". Interviews the user about business intent, researches the codebase and options in parallel, presents 2-3 approaches with a recommendation, and produces a spec.
argument-hint: [raw idea or problem]
---

# Brainstorm: idea → validated spec

Run the four steps in order. Do not skip the interview, and do not start
implementing — the deliverable of this skill is a spec, not code.

## 1. Interview (business intent only)

Use AskUserQuestion — at most 2 rounds of up to 4 questions. Skip anything the
prompt already answers. Only ask what cannot be derived from the code or docs
(CLAUDE.md §1): technical facts must be researched in step 2, not asked.

Cover:
- The problem and the goal — what changes for whom when this works?
- Who is affected (users, operators, other teams, other systems)?
- Constraints: deadline, compatibility, tech choices already fixed.
- Success criteria — measurable, checkable.
- Explicit non-goals (what this is NOT).
- Priority and rough size expectation.

Never proceed on an unstated assumption about business intent — ask.

## 2. Research (parallel, read-only)

Launch independent Explore subagents in one parallel batch — one per relevant
angle:
- Similar existing features/implementations in this codebase to reuse.
- Integration points and conventions the solution must follow.
- Callers/usages of anything that would change (cross-impact).

Add a web-research subagent only when the codebase plus your own knowledge is
insufficient; findings must cite URLs.

## 3. Options

Present 2–3 approaches with a short table: effort / risk / fit with existing
patterns. Recommend one and say why. Let the user pick via AskUserQuestion.

## 4. Spec

Write the spec with this template (the shared funnel — every brainstorm ends in
the same shape):

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
<required if any data store is touched — see CLAUDE.md §8>
```

Offer to save it to `docs/specs/<yyyy-mm-dd>-<slug>.md` — ask before creating
the file. Then either stop with the spec, or proceed to the Plan step of
CLAUDE.md §2 if the user asks.
