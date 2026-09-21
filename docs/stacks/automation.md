# Automation stack

`stacks/automation/compose.yml` — n8n in queue mode with a dedicated worker,
PostgreSQL 18, Redis 8, and Syncthing.

| Service | Role |
|---------|------|
| `n8n` | Editor, REST API, webhook listener, scheduler |
| `n8n-worker` | Executes workflow nodes off the Redis queue |
| `n8n-db` | PostgreSQL 18 — workflows, credentials, execution history |
| `n8n-redis` | Redis 8 — the Bull job queue |
| `syncthing` | File ingress, driven over its REST API by n8n |

---

## Queue mode, and the trap it sets

`EXECUTIONS_MODE` is `queue`. Nodes do not run in the `n8n` container; they run
in `n8n-worker`. The `n8n` process serves the editor, registers webhooks and
schedules triggers, then pushes jobs onto Redis for the worker to pick up.

This has one consequence that is easy to get wrong and hard to debug:
**`{{ $env.X }}` is resolved by whichever process executes the node.** A
variable set only on `n8n` produces a workflow that looks perfectly configured
in the editor and resolves to an empty string at run time. The failure surfaces
far from its cause — as an `ssh '' 'some command'` that does nothing, rather
than as a missing-variable error.

That is why every variable the workflows read as `$env` lives in a single YAML
anchor, `x-kg-env`, merged into both services:

```yaml
x-kg-env: &kg-env
  KG_AI_HOST: ${KG_AI_HOST}
  # ...

services:
  n8n:
    environment:
      <<: *kg-env
  n8n-worker:
    environment:
      <<: *kg-env
```

Before the anchor, both `environment:` blocks repeated the same keys by hand,
which is precisely how a variable ends up on one service and not the other.
With the anchor, that state is not representable.

`.env` supplies the values; the anchor guarantees they reach both processes.

### Variables that deliberately are *not* in the anchor

Webhook paths. A Webhook node's `path` is registered when the workflow is
**activated**, before any execution context exists, so it cannot be an
expression and n8n cannot read it from the environment. The value is typed into
the node by hand on import.

Three `KG_*_WEBHOOK_PATH` variables were passed in for a year, read by nothing.
A rotation was once carried out against them while the nodes went on listening
on their old paths. They were removed rather than left as decoration.

This is a recurring failure mode in this repository — a value that looks
configured and never reaches its destination. Two more were found and removed
the same way: `N8N_WORKER_VERSION` (the worker image comes from `N8N_VERSION`)
and `N8N_NODE_FUNCTION_ALLOW_BUILTIN` (never passed to any container).

---

## Addressing: container names, not public hostnames

Internal calls use the Docker network. n8n reaches Forgejo at
`http://forgejo:3000` — the **internal** port, not the published one — for two
reasons: `forgejo` is on the `N8N_SSRF_ALLOWED_HOSTNAMES` allowlist and the
public hostname is not, and the call never leaves the machine, so it keeps
working while the Cloudflare tunnel is down.

`FORGEJO_WEB_BASE` exists for the opposite case and must never hold the same
value. It is the address a **person** reaches. Notifications build their tap
target from it; a link built from the container address opens nothing on a
phone. Left unset, the workflows emit no link and name the missing key in the
message body instead — a tap that fails is worse than a line saying why.

SSRF protection stays enabled, with an explicit hostname allowlist rather than
being switched off.

---

## Syncthing

Syncthing lives in this stack rather than in `tools` because it works as a pair
with n8n: n8n polls the Syncthing REST API to detect modified files, maps them
to a collaborator, and commits them.

**Reachability.** `STGUIADDRESS=0.0.0.0:8384` makes the API listen on the whole
container network, so n8n can call `http://syncthing:8384` with an
`X-API-Key` header. `syncthing` must be on `N8N_SSRF_ALLOWED_HOSTNAMES` or SSRF
protection blocks it.

**Exposure.** Port 8384 (GUI and API) is published on the host's `127.0.0.1`
only — it is an admin surface, not a LAN service. The sync ports are on the LAN
for peers: 22000 TCP and UDP for data, 21027/UDP for local discovery.

**Volumes.** The entire Syncthing home directory is mounted, not just a
`/config` subpath: v2 keeps its SQLite index database alongside the config, and
the official Docker guide mounts the whole `/var/syncthing`.

The working tree is mounted at an **identical host and container path**, so the
SSH-based commit job running on the host and Syncthing inside the container
refer to the same path and no translation is needed.

---

## Operational notes

- Execution history is pruned automatically: `EXECUTIONS_DATA_PRUNE=true` with
  `EXECUTIONS_DATA_MAX_AGE=168` (7 days).
- Binary data goes to the filesystem, not the database.
- `NODE_OPTIONS=--max-old-space-size=1024` caps n8n's heap.
- Both services run as `PUID:PGID` from `.env`, so files written into the
  mounted data directory stay owned by the host user.

### Upgrading

n8n runs database migrations on startup of the **main** instance. Start `n8n`
alone, wait for `/healthz` to answer, then start the worker — a worker that
comes up mid-migration is a race with nothing to gain.

Migrations are not reversible by restoring the previous image tag, so take a
logical dump first and verify it is restorable rather than assuming it:

```bash
docker compose stop n8n-worker n8n
docker exec <db-container> pg_dump -U n8n -Fc -d n8n > n8n-db.dump
docker exec <db-container> pg_restore -l /path/inside/container.dump   # verify

# bump N8N_VERSION in .env
docker compose pull n8n n8n-worker
docker compose up -d --no-deps n8n          # migrations run here
# wait for healthz, then:
docker compose up -d --no-deps n8n-worker
```

Compare `make healthcheck` on both sides: the workflow, active-workflow,
credential and migration counts are the fingerprint that shows whether a
migration lost anything. See [testing](../testing.md).

Restarting a service that other workflows poll produces a transient failure in
those workflows. Stopping Syncthing for 34 seconds during an upgrade made one
scheduled run fail on its `GET Syncthing folders` node; the next run a minute
later succeeded. Expected, and self-healing.
