#!/usr/bin/env bash
# Self-test for the settings profile pair — baseline repo only, never installed.
# src/settings.relaxed.json must differ from src/settings.json in EXACTLY the
# documented ways (this file is the machine-checked delta spec); everything
# outside permissions.deny/ask/allow must be identical (except $comment*).
# Usage: bash tests/settings-profile-test.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRICT="$ROOT/src/settings.json"
RELAXED="$ROOT/src/settings.relaxed.json"
[ -f "$STRICT" ]  || { echo "missing: $STRICT" >&2; exit 1; }
[ -f "$RELAXED" ] || { echo "missing: $RELAXED" >&2; exit 1; }

python3 - "$STRICT" "$RELAXED" <<'PY'
import json, sys

strict_path, relaxed_path = sys.argv[1], sys.argv[2]
strict = json.load(open(strict_path))
relaxed = json.load(open(relaxed_path))

failures = []


def fail(msg):
    failures.append(msg)


# ---- the documented delta (relaxed vs strict) ----
DENY_REMOVED = {
    "Bash(curl:*)", "Bash(wget:*)",
    "Read(./.env)", "Read(**/.env)", "Read(**/*.key)", "Read(**/*.pem)",
    "Read(**/*.p12)", "Read(**/*.pfx)", "Read(**/credentials.json)",
    "Read(**/secrets/**)",
    "Edit(**/.env)", "Edit(**/secrets/**)",
}
DENY_ADDED = set()
ASK_REMOVED = {
    "Bash(npx playwright install:*)", "Bash(npm install:*)", "Bash(yarn add:*)",
    "Bash(pnpm add:*)", "Bash(pip install:*)", "Bash(uv add:*)",
    "Bash(docker compose:*)", "Bash(docker-compose:*)", "Bash(docker inspect:*)",
    "Bash(psql:*)", "Bash(mysql:*)", "Bash(redis-cli:*)",
}
ASK_ADDED = {"Bash(curl:*)", "Bash(wget:*)"}
ALLOW_REMOVED = set()
ALLOW_ADDED = {
    "Bash(docker:*)", "Bash(docker compose:*)", "Bash(docker-compose:*)",
    "Bash(npm install:*)", "Bash(yarn add:*)", "Bash(pnpm add:*)",
    "Bash(pip install:*)", "Bash(uv add:*)", "Bash(npx playwright install:*)",
    "Bash(psql:*)", "Bash(mysql:*)", "Bash(redis-cli:*)",
}

# ---- permission lists: no duplicates, exact expected delta ----
for name, removed_exp, added_exp in (
    ("deny", DENY_REMOVED, DENY_ADDED),
    ("ask", ASK_REMOVED, ASK_ADDED),
    ("allow", ALLOW_REMOVED, ALLOW_ADDED),
):
    s = strict["permissions"][name]
    r = relaxed["permissions"][name]
    for label, lst in (("strict", s), ("relaxed", r)):
        dupes = {x for x in lst if lst.count(x) > 1}
        if dupes:
            fail(f"{name} ({label}): duplicate entries {sorted(dupes)}")
    removed = set(s) - set(r)
    added = set(r) - set(s)
    if removed != removed_exp:
        fail(f"{name}: removed-in-relaxed mismatch\n"
             f"  unexpected removals: {sorted(removed - removed_exp)}\n"
             f"  missing removals:    {sorted(removed_exp - removed)}")
    if added != added_exp:
        fail(f"{name}: added-in-relaxed mismatch\n"
             f"  unexpected additions: {sorted(added - added_exp)}\n"
             f"  missing additions:    {sorted(added_exp - added)}")

# ---- everything outside the permission lists must be identical ----
def strip(d):
    return {k: v for k, v in d.items()
            if k != "permissions" and not k.startswith("$comment")}

if strip(strict) != strip(relaxed):
    diff_keys = [k for k in set(strip(strict)) | set(strip(relaxed))
                 if strip(strict).get(k) != strip(relaxed).get(k)]
    fail(f"non-permission keys differ between profiles: {sorted(diff_keys)}")

for label, d in (("strict", strict), ("relaxed", relaxed)):
    if d.get("defaultMode") != "default":
        fail(f'defaultMode must stay "default" in {label}, got {d.get("defaultMode")!r}')

if failures:
    for f in failures:
        print("FAIL:", f, file=sys.stderr)
    print(f"\nsettings-profile-test: {len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("settings-profile-test: all checks passed")
PY
