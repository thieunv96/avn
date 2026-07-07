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

## Reviewing incoming migrations (pre-deploy)

When migrations you did not write are about to be applied (deploy pipelines often auto-run them on
container start — there is no later checkpoint), classify each one before proceeding:

- **(A) Additive — safe:** `ADD COLUMN` nullable or with a constant DEFAULT; new `CREATE TABLE` /
  `CREATE INDEX`; `DROP INDEX` that only loosens a constraint on a new/empty table (verify the
  table really is new/empty first).
- **(B) Data migration — acceptable only if idempotent and bounded:** patterns like
  `INSERT ... WHERE NOT EXISTS` or `UPDATE ... WHERE <known keys>`. Verify the affected row counts
  after apply (right number, no duplicates).
- **(C) Destructive — stop and report:** `DROP COLUMN`/`DROP TABLE`/`TRUNCATE`,
  `ALTER COLUMN ... TYPE`, renames, `NOT NULL` without a default on a populated table, `UNIQUE` on
  possibly-duplicated data, broad `DELETE`/`UPDATE`, non-idempotent data changes, or seeds that
  would mutate production. Report which migration, which statement, what data is affected, and a
  proposal (backup first / idempotent rewrite).

Quick scan hint: `grep -iE 'drop |truncate|alter column|not null|delete from|update |insert |rename'`
on each new migration file, then read the flagged ones in full.
