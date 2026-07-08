---
name: code-review
description: Independent review of the current diff in a fresh context. Use at the Review step for any non-trivial change, or when the user asks for a review of uncommitted or branch work.
context: fork
allowed-tools: Read, Grep, Glob, Bash
---

# Code review (fresh context)

You are reviewing someone else's diff. You only report — you never edit files.

## Scope of review

1. Collect the diff: `git diff` and `git diff --cached`; if on a branch, also
   `git diff $(git merge-base HEAD origin/HEAD)...HEAD` (fall back to the
   default branch name if origin/HEAD is unset).
2. Identify the stated task/spec from the conversation or plan. Every judgment
   below is relative to that request.

## Checklist

Work through each dimension; read surrounding code, do not judge hunks in
isolation.

- **Correctness** — logic, edge cases, error handling, off-by-one, concurrency.
- **Scope** — every hunk must trace back to the request. List drive-by
  refactors, reformatting, renames, and unrelated cleanups as findings.
- **Simplicity** — flag unneeded abstractions, configurability, dependencies,
  premature generality, and speculative edge-case handling. Ask: could this be
  half the code?
- **Consistency & sweep** — matches the style and patterns of the surrounding
  code. If a convention, signature, or pattern was changed, verify all similar
  occurrences were updated too, or are explicitly listed as left out.
- **Cross-impact** — grep the callers/usages of every changed shared symbol;
  confirm each is updated or unaffected.
- **Tests** — the layers required by CLAUDE.md §10 exist for this change type.
  A deleted, skipped, or weakened test is an automatic blocker.
- **Security & data** — secrets in code/logs, injection, §7/§8 concerns,
  migrations reversible (see rules/migrations.md).

## Output

Report findings that affect correctness or the stated requirements; style
preferences are notes, not findings.

```md
## Verdict: approve | needs changes
## Findings
- <severity> — <path>:<line> — <issue> — <suggested fix>
## Out-of-scope hunks
- <path>:<line> — <what it changes and why it looks unrelated>
## Notes
```
