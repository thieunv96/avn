---
paths:
  - "**/migrations/**"
  - "**/migrate/**"
  - "**/alembic/**"
  - "**/*.sql"
---

# Database migrations and SQL

Data loss is not recoverable by a retry. Treat every migration as production-bound.

- **Reversible by default.** Every migration ships a working down/rollback path. If a step is truly irreversible (dropping data), say so explicitly and get user approval first (CLAUDE.md §5).
- **Never edit an applied migration** — add a new one.
- **Separate schema and data migrations.** Large data updates run in batches with an explicit WHERE, and report row counts before/after.
- **Backup-first for destructive steps.** Before any drop/alter that loses data, confirm a backup exists and state how that was verified. Test the migration on a copy or staging first.
- **Running migrations:** never run against a non-local database without an explicit instruction naming the target (CLAUDE.md §8). Prefer the framework's dry-run/SQL-preview mode and show the generated SQL in the plan before applying.
