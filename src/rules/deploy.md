---
paths:
  - "**/docker-compose*"
  - "**/Dockerfile*"
  - "deploy/**"
  - "infra/**"
  - "ansible/**"
---

# Deploying a new release (pull-based)

When a deploy means pulling a new version onto a host (git pull + rebuild/restart), follow these
steps in order. The production rules of `CLAUDE.md` §8 apply throughout: read-only by default,
and any mutating action needs an explicit instruction naming the target.

1. **Investigate before pulling (read-only):** fetch, then review `git log` / `git diff
   <current>..origin/<branch>`; scan the name-status diff for migrations, seeds, schema files,
   Dockerfile/compose, and `.env*.example` changes.
2. **Review incoming migrations/seeds BEFORE building** when the pipeline auto-applies them on
   container start — there is no later checkpoint. Classify each per `.claude/rules/migrations.md`
   ("Reviewing incoming migrations"); destructive or non-idempotent → stop and report.
3. **Config drift:** a changed default in `.env*.example`/config only takes effect if the real env
   file does not override it — check by variable name (`CLAUDE.md` §7) and call it out explicitly.
4. **Pull fast-forward only** (`git pull --ff-only`) and confirm the expected version landed.
5. **Run long builds in the background.** If the completion notification is lost, do NOT start a
   second build — detect the running one first (build processes, image timestamps) and wait.
6. **Verify after deploy:** running version, migration logs, health endpoint, error-level log
   scan, container status — plus read-only data checks when a data migration ran.
7. **Rollback ladder:** additive-only changes → check out the previous version and rebuild; env
   change → restore the old value and recreate; applied data migration → requires a backup,
   report before acting.
