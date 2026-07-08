---
name: map
description: Generate or refresh the codebase knowledge base — an auto-loaded index (.claude/rules/codebase-map.md) plus on-demand module docs under docs/codebase/ — so new sessions orient from the KB first and explore only to confirm and fill gaps. Use when onboarding Claude to a repo, when no KB exists yet, or when the KB has drifted from the code.
argument-hint: [optional: area to (re)map]
---

# Map: generate / refresh the codebase KB

The KB is an **orienting reference, not a replacement for exploring**. Future sessions read the
index and the relevant module file first, then explore the code to confirm and fill gaps; where
the KB and the code disagree, the code wins. Its job is to narrow the search and prevent missed
points. Content quality is the top priority: clear, concrete, and detailed enough that a fresh
session knows what to read and grep next.

## 1. Detect mode

- No `.claude/rules/codebase-map.md` in the target repo → **generate** a full KB.
- It exists → **refresh**: read its `generated: <date> @<commit>` stamp, run
  `git diff --stat <commit>..HEAD` and `git log --oneline <commit>..HEAD`, and update only the
  index plus the module files whose areas changed. Delete entries (or whole files) for things
  that no longer exist — a stale entry is worse than a missing one.

## 2. Explore (parallel subagents, read-only)

Launch independent Explore subagents in one parallel batch (CLAUDE.md §2), one per angle:

- **Structure & entry points** — top-level layout, where execution starts (main/server/CLI/jobs),
  and the 1-2 core flows end to end ("life of a request").
- **Modules/domains** — the major architectural areas: purpose, key files, public interfaces,
  and how they depend on each other.
- **Conventions & cross-cutting** — error handling, config, logging, auth, and repo-specific
  patterns that the code alone does not explain.
- **Commands** — how to build, test, lint, and run, taken from `package.json`/`Makefile`/
  `pyproject.toml`/CI config; never invented.

Every finding must carry evidence (file path, symbol name) that step 3 can verify against the
code. Discard unsupported claims — confident-but-wrong prose poisons every future session.

## 3. Write the KB

### Layout (fixed)

| File | Content | Cap |
| --- | --- | --- |
| `.claude/rules/codebase-map.md` | The INDEX. No `paths:` frontmatter, so Claude Code auto-loads it every session. | ≤60 lines |
| `docs/codebase/architecture.md` | Bird's Eye View · Entry Points · the 1-2 core flows · Cross-Cutting Concerns. | ≤150 lines |
| `docs/codebase/modules/<slug>.md` | One file per **architectural area** (not per directory). | ≤150 lines each |
| `docs/codebase/conventions.md` | Repo-specific patterns the code cannot state. | ≤150 lines |
| `docs/codebase/decisions.md` | Append-only decision log: date / decision / why / consequences. Supersede entries, never delete them. | grows |

For a small repo, generate the minimum that is genuinely useful (often just the index +
`architecture.md`); never emit empty or filler files.

### Index template

```md
> Usage: before exploring or changing an area, read its `docs/codebase/` file below as an
> orienting reference — then explore the code to confirm and fill gaps; the KB never replaces
> reading the code. If the KB and the code disagree, the code wins: fix the KB in the same
> change (CLAUDE.md §11).

# Codebase map — <project>

<2-3 lines: what this project is and does.>
Stack: <one line>

## Layout
- `src/<dir>/` — <one-line purpose>

## Knowledge base
- `docs/codebase/architecture.md` — <what it covers> — read before any cross-module change
- `docs/codebase/modules/<slug>.md` — <area: what it covers> — read before working in <area>
- `docs/codebase/conventions.md` — <what it covers> — read before writing new code
- `docs/codebase/decisions.md` — why things are the way they are — read before proposing redesigns

## Commands
- build: `<cmd>` · test: `<cmd>` · lint: `<cmd>` · run: `<cmd>`

generated: <yyyy-mm-dd> @<short-commit>
```

### Module file template

```md
# <Area name>

Purpose: <1-3 sentences>

## Key files & entry points
- `path/to/file_or_dir` — <role>; start at `SymbolName`

## Interfaces
<What calls into this area, what it calls out to — names to grep, not signatures.>

## Main flow
<Short bullet dataflow: input → steps → output.>

**Invariant:** <especially "never/none" statements — e.g. "X never imports Y", "this layer is stateless">
**Boundary:** <what this area must not know about / the API line other code may depend on>

## Gotchas
- <only the genuinely surprising>

generated: <yyyy-mm-dd> @<short-commit>
```

### Content policy (what makes the KB survive)

- **Routing over prose**: entry points, key files, symbol names to grep. The map tells the next
  session where to look; it does not retell the code.
- **Only what the code cannot say**: purposes, boundaries, invariants (especially negative ones),
  dataflow, gotchas. Litmus test per line: would a fresh session make a mistake without it?
  No → cut.
- **No rot vectors**: no line numbers, no full signatures, no exhaustive file lists, no restated
  common conventions, and no working state (current task/progress — auto memory covers that).
- **Relevance over completeness**: document the important, surprising, and risky; skip the boring.
- **Caps are guardrails against bloat, not an excuse to be vague**: if an area does not fit its
  file, split it into two area files — never compress into ambiguity.
- **Stamp every file**: `generated: <yyyy-mm-dd> @<short-commit>` (the refresh mode diffs from it).

## 4. Report

List every KB file created, updated, or deleted so the user can review the KB diff like code.
Close by reminding that from now on the KB is maintained **in the same change** that invalidates
it (CLAUDE.md §11) — and can be re-checked anytime with `/map`.
