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
| Tracked JSON parses | `services_metadata.json` drives the checker; `workflows/` are n8n exports, and broken JSON surfaces at import time, which is when it is needed; a stack's settings file, like Immich's, stops that service from starting |
| Every compose file parses, every include resolves | A wrong include path breaks *every* compose command, not just that stack |
| A stack the root file does not include has its own `name:`, joins the network as `external`, and is asked by the Makefile, the health check and the update checker | The AI stack runs apart so a GPU failure stops only it; a tool that forgets that project reports Ollama as missing, or drops it from the update manifest without a word |
| Workflows and host scripts reach other machines by role, never by name or private address | A host name or an address written in is silently wrong on the next machine this is cloned to |
| Every event the UPS runbook configures has a case in `host/kg-ups-handler`, and its `upsmon.conf` sets `POWERDOWNFLAG` | NUT is configured by hand from the runbook; an event renamed on one side only ends in "unknown event" during the outage itself, and a missing flag means no killpower, silently |
| No private key or JWT in tracked files; `.env` not tracked | The check that matters before publishing |
| No name of this installation in tracked files: the machines, domains and addresses listed in `.private-names`, which git ignores | Roles and placeholders only, because the repository is meant to be published. Without the file the check is a skip, not a pass |
| Unit tests | See below |

**Checks that cannot run produce an explicit skip, not a pass.** A test that
reports success without having executed is worse than no test, because it
removes the reason to look elsewhere. On a machine without `shellcheck` the
suite reports one skip rather than a clean sweep.

### The unit tests

39 tests, standard library only — nothing to install — with HTTP calls replaced
by canned responses.

They exist for one reason: `scripts/check_updates.py` **fails silently**. If
release selection wrongly discards a valid release it raises nothing and
reports "no updates", which is indistinguishable from there genuinely being
none. Each test pins one concrete way of failing like that, including the
defects found in this codebase — picking whichever release the forge listed
first, matching pre-release keywords as bare substrings, and a display name
carried over from the previous service (or a crash, when a dependency came
first). Others check that the manifest reads both compose projects, and that
a calendar version is searched across years rather than kept on one.

`tests/test_check_updates.py` also asserts on `services_metadata.json` itself:
a service that loses its `repo` or owner/name pair stays *tracked* but becomes
*uncheckable*, which is exactly the case that goes unnoticed. The same goes for a
`versioning` value outside the known ones.

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
workflows, credentials, migrations applied. And it fails when the last
successful off-site backup is older than `BACKUP_MAX_AGE_HOURS` — the check
that still works when the nightly notification itself never left — and when
another machine's newest configuration copy is older than
`HOST_CONFIG_MAX_AGE_DAYS`. See [backup](backup.md). Comparing that fingerprint on both
sides of an upgrade is the most direct way to notice that a migration lost
something.

For each flow kept in `workflows/`, it checks that n8n runs that very flow:
present under the file's id, published, and with no other active flow of the
same name. An import replaces a flow only when the ids match, and otherwise
adds a second one; it also always leaves the flow unpublished. Both happened
to the nightly backup in October 2026, and either would have gone unnoticed
until a night was missing.

Where NUT is installed it also reads every UPS the server knows, and fails
unless the status is on line: a UPS the server cannot read protects nothing,
and says so nowhere else. See [ups](stacks/ups.md).

It runs every check before reporting, rather than stopping at the first
failure — when you are comparing before and after an upgrade, the full picture
is the point — and exits non-zero if any of them failed, so it can gate a
rollback.

```bash
make healthcheck              # everything
./scripts/healthcheck.sh n8n  # one service
```

Container names are resolved through `docker compose ps -q` rather than
assuming the project prefix, and ports are read from `.env` — key by key, not
by sourcing it. See [configuration](configuration.md).

---

## What neither layer covers

A full restore. `make backup-restore-test` brings every set back from
off-site and proves it opens — every Postgres dump with `pg_restore -l`, every
SQLite copy with `pragma integrity_check`, every copy of another machine against
its checksum, every other file verified against the repository — but nothing automated rebuilds a service from them into a
scratch instance. Restoring a
whole service, or the whole server, remains a manual exercise, described in
[backup](backup.md).
