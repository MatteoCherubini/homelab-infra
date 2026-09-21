# Git stack

`stacks/git/compose.yml` — Forgejo, a self-hosted Git forge.

| Service | Role |
|---------|------|
| `forgejo` | Git over HTTP and SSH, issues, pull requests, webhooks, Actions |

---

## Ports and addressing

- `${FORGEJO_HTTP_PORT}` (default 3001) → 3000 in the container
- `${FORGEJO_SSH_PORT}` (default 222) → 22 in the container

`FORGEJO__server__SSH_PORT` is set to `22`, not to the published port: it is
what Forgejo prints in the clone URLs it shows to users, who reach it through
the proxy on the standard port.

The public hostname comes from `FORGEJO_DOMAIN` in `.env` and is **not** hard
coded in the compose file — see [configuration](../configuration.md).

**Changing `FORGEJO_DOMAIN` after the first start breaks existing git remotes
and webhook URLs.** Decide it before the first run.

Other services address Forgejo as `http://forgejo:3000` on the internal
network, never by its public hostname. [automation](automation.md) explains
why.

## Webhooks

`FORGEJO__webhook__ALLOWED_HOST_LIST` permits `n8n` plus the Docker and private
subnets. Without it Forgejo refuses to deliver webhooks to internal addresses,
which is a sensible default that has to be relaxed deliberately for a forge
that drives local automation.

## Storage

Repositories and the SQLite database live under `${MEDIA_ROOT}/forgejo/data` —
on the RAID array, not on the root disk, because this is the one dataset whose
loss is not recoverable from an image.

## Upgrading

Forgejo runs database migrations on startup. Stop the container, snapshot the
whole `/data` directory (database *and* repositories), then upgrade:

```bash
docker compose stop forgejo
# snapshot ${MEDIA_ROOT}/forgejo/data
# bump FORGEJO_VERSION in .env
docker compose pull forgejo && docker compose up -d --no-deps forgejo
```

Verify with the health endpoint, which reports the database and cache
separately, and by checking that the repositories are still readable on disk:

```bash
curl -s http://127.0.0.1:3001/api/healthz          # checks database:ping and cache:ping
git --git-dir=<repo>.git show-ref | wc -l          # refs intact
```

Forgejo publishes several major lines in parallel. `scripts/check_updates.py`
deliberately stays on the current major: on 2026-09-21 it reported 15.0.9 while
16.0.5 existed, which is the intended behaviour. Crossing a major is a decision,
not an update.
