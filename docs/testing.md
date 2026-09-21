# Testing and verification

Two layers, deliberately separate: one that never touches the infrastructure,
and one that can only be run against it.

---

## `make test` — offline, no Docker

Runs with no network, no containers and no `.env`. That is what lets it run on
a freshly cloned laptop and in CI, and lets it run *before* touching the server
rather than after.

| Check | Why |
|-------|-----|
| Shell syntax, and `shellcheck` at `warning` severity | Behavioural defects only, not style — a gate that reports everything stops being read |
| Python syntax | |
| Tracked JSON parses | `services_metadata.json` drives the checker; `workflows/` are n8n exports, and broken JSON surfaces at import time, which is when it is needed |
| Every compose file parses, every include resolves | A wrong include path breaks *every* compose command, not just that stack |
| No private key or JWT in tracked files; `.env` not tracked | The check that matters before publishing |
| Unit tests | See below |

**Checks that cannot run produce an explicit skip, not a pass.** A test that
reports success without having executed is worse than no test, because it
removes the reason to look elsewhere. On a machine without `shellcheck` the
suite reports one skip rather than a clean sweep.

### The unit tests

24 tests, standard library only — nothing to install — with HTTP calls replaced
by canned responses.

They exist for one reason: `scripts/check_updates.py` **fails silently**. If
release selection wrongly discards a valid release it raises nothing and
reports "no updates", which is indistinguishable from there genuinely being
none. Each test pins one concrete way of failing like that, including the two
defects found in this codebase — picking whichever release the forge listed
first, and matching pre-release keywords as bare substrings.

`tests/test_check_updates.py` also asserts on `services_metadata.json` itself:
a service that loses its `repo` or owner/name pair stays *tracked* but becomes
*uncheckable*, which is exactly the case that goes unnoticed.

### Has the suite ever failed?

A suite that has only ever been green is unproven. This one was verified by
injecting six faults and confirming each is caught: broken YAML, a missing
include target, a committed JWT, a committed private key, broken shell syntax,
and the release-selection regression reintroduced. The last fails with
`'n8n@2.39.9' != 'n8n@2.39.10'`.

---

## `make healthcheck` — against the running system

`docker compose ps` reports that a process is alive, which is not the same as
the service working.

This queries each service's health endpoint and, where a service returns
something meaningful, **asserts on the response body too** — Nginx and Forgejo
both answer `200` from the frontend while the backend behind them is broken.

It also prints a fingerprint of the n8n database: workflow count, active
workflows, credentials, migrations applied. Comparing that fingerprint on both
sides of an upgrade is the most direct way to notice that a migration lost
something.

It exits non-zero on the first failure, so it can gate a rollback.

```bash
make healthcheck              # everything
./scripts/healthcheck.sh n8n  # one service
```

Container names are resolved through `docker compose ps -q` rather than
assuming the project prefix, and ports are read from `.env` — key by key, not
by sourcing it. See [configuration](configuration.md).

---

## What neither layer covers

Restore. The snapshots taken before an upgrade are verified as *readable* — a
`pg_dump` is checked with `pg_restore -l`, a SQLite file with
`pragma integrity_check` — but no automated test performs an actual restore
into a scratch database. That remains a manual exercise.
