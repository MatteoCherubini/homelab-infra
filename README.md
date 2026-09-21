# Homelab Infrastructure

A self-hosted infrastructure stack running on Ubuntu Server, managed entirely
through Docker Compose and versioned as code.

Thirteen services across six stacks — reverse proxying, Git hosting, workflow
automation with a queue-mode worker, a local LLM runtime on GPU, a password
manager, file sync, push notifications — plus a seventh stack for UPS
orchestration, written and left disabled until the hardware is installed.

The point of this repository is not that it runs containers. It is that every
version, hostname and credential lives in one place, that upgrades are checked
automatically and applied deliberately, and that there is a way to tell whether
the thing still works after you have changed it.

---

## Services

| Service             | Stack      | Role                                            |
| ------------------- | ---------- | ----------------------------------------------- |
| Nginx Proxy Manager | `core`     | Reverse proxy, TLS termination                  |
| Homepage            | `core`     | Dashboard and service discovery                 |
| Cloudflared         | `core`     | Cloudflare Tunnel for external access           |
| ntfy                | `core`     | Push notifications (auth required, deny-by-default) |
| Ollama              | `ai`       | Local LLM runtime, NVIDIA GPU reservation       |
| n8n                 | `automation` | Workflow automation, queue execution mode     |
| n8n-worker          | `automation` | Executes workflow nodes off the Redis queue   |
| PostgreSQL 18       | `automation` | n8n persistence                               |
| Redis 8             | `automation` | n8n job queue                                 |
| Syncthing           | `automation` | File ingress, driven over its REST API by n8n |
| Forgejo             | `git`      | Self-hosted Git forge                           |
| Vaultwarden         | `security` | Bitwarden-compatible password manager           |
| Excalidraw          | `tools`    | Whiteboard                                      |
| NUT                 | `ups`      | UPS monitoring — defined, not currently enabled |

---

## Repository layout

```text
.
├── docker-compose.yml       # root: includes the stacks, defines the shared network
├── docker-compose.override.yml.example
├── .env.example             # single source of truth for versions and configuration
├── Makefile                 # operational entrypoints
├── stacks/
│   ├── core/  ai/  automation/  git/  security/  tools/  ups/
├── scripts/
│   ├── init.sh              # first-run setup: .env, directories, permissions
│   ├── check-env.sh         # .env vs .env.example drift detection
│   ├── check_updates.py     # release checker + service manifest generator
│   └── healthcheck.sh       # end-to-end verification
├── workflows/               # n8n workflow definitions, exported as JSON
├── UPS/                     # ordered shutdown orchestration (NUT + systemd + SSH)
└── services_metadata.json   # per-service criticality and upstream repository
```

Persistent data lives outside the repository, under the paths set by
`DATA_ROOT` and `MEDIA_ROOT`. Nothing stateful is tracked in Git.

---

## Configuration model

Everything environment-specific is in `.env`, which is never committed. No
image tag, published port or public hostname is written into a compose file;
they are variable references, with a sensible default where one exists:

```yaml
image: ${FORGEJO_IMAGE}:${FORGEJO_VERSION}
ports: ["${FORGEJO_HTTP_PORT:-3001}:3000"]
FORGEJO__server__DOMAIN: "${FORGEJO_DOMAIN}"
```

This is what makes the stacks reusable by someone else, and it is checked
rather than assumed: `make check-env` fails when `.env` is missing a key that
`.env.example` declares and warns about keys it has in addition, while
`make verify` compares the image tags declared in the repository against the
images actually running.

Two notes worth reading before a first deployment, both also in
`.env.example`: changing `FORGEJO_DOMAIN` after the first start breaks
existing Git remotes and webhook URLs, and changing `VAULTWARDEN_DOMAIN`
invalidates registered WebAuthn passkeys, which are bound to the exact domain.

### Local-only services

Services that should run on one machine without entering the repository —
a separate project, or something being trialled — go in a gitignored
`docker-compose.override.yml`. See `docker-compose.override.yml.example` for
why this is preferable to a dedicated branch.

---

## Operations

```
make init           Bootstrap: .env, data directories, permissions
make up             Start everything
make down           Stop everything
make ps             Status of running services
make logs           Live logs

make check          Prerequisites and compose config validity
make check-env      .env vs .env.example drift
make verify         Declared image tags vs running containers
make healthcheck    End-to-end verification (see below)
make health         Containers that are not healthy
make gpu-check      NVIDIA runtime availability
make check-updates  Generate the service manifest and check for new releases
```

---

## Verifying that it actually works

`docker compose ps` reports that a process is alive, which is not the same as
the service working. `make healthcheck` queries each service's health endpoint,
and where a service returns something meaningful it asserts on the response
body too — Nginx and Forgejo both answer `200` from the frontend while the
backend behind them is broken.

It also prints a fingerprint of the n8n database: workflow count, active
workflows, credentials, migrations applied. Comparing that fingerprint before
and after an upgrade is the most direct way to notice that a migration lost
something. The script exits non-zero on the first failure, so it can gate a
rollback.

```bash
make healthcheck              # everything
./scripts/healthcheck.sh n8n  # one service
```

---

## Update workflow

Image versions are pinned in `.env` and never floated, except for three
services deliberately tracked on `latest`: Cloudflared and Excalidraw, which
hold no state, and Ollama, whose models live in a volume the image does not
own.

The upgrade path is automated up to the point of decision, and manual past it:

1. `scripts/check_updates.py` builds a manifest of every service from
   `docker compose config`, enriches it from `services_metadata.json`, and
   queries each upstream forge — GitHub, Codeberg, or any Gitea-compatible
   API — for the newest stable release on the current major branch.
   Pre-releases are filtered out, and candidates are compared by semantic
   version rather than by the order the API returns them.
2. An n8n workflow runs it on a schedule and pushes a summary to ntfy.
3. A second pass asks a locally hosted model, through Ollama, to rank the
   updates by risk and propose an order.
4. A human reads the release notes, applies the change, and verifies it.

Step 4 is not automated on purpose. The risk assessment is an aid, not an
authority: it has no access to the upstream release notes, so it reasons from
version numbers alone and will call a patch release harmless when that patch
closes a remote code execution hole.

Applying an update means bumping the version in `.env`, pulling, recreating
the service, and running `make healthcheck` on both sides of the change.
Because tags are pinned, rolling back a container is a matter of restoring the
previous value — but a database migration is not reversible that way, so
stateful services get a snapshot first.

---

## Networking and external access

Services share a single Docker bridge network and are addressed by service
name. External access is fronted by Nginx Proxy Manager for TLS and by a
Cloudflare Tunnel, which reaches Cloudflare through an outbound connection
rather than an inbound one.

Internal calls use container addresses rather than public hostnames: n8n
reaches Forgejo at `http://forgejo:3000`, which keeps working when the tunnel
is down and never leaves the host. n8n's SSRF protection is left enabled, with
an explicit hostname allowlist.

Syncthing publishes its GUI and API on loopback only; its sync ports are on
the LAN, and n8n drives it over the internal network with an API key.

---

## GPU

Ollama holds an NVIDIA device reservation for local inference. Homepage takes
a `utility`-capability reservation on the same GPU to read telemetry for the
dashboard.

---

## UPS orchestration

`UPS/` contains an ordered shutdown design built on NUT, systemd and an SSH
forced-command handler: on mains failure the workstation is shut down first
and the server second, with automatic recovery when power returns. The compose
stack is written and left commented out in the root file, pending the physical
install.

---

## Deployment

```bash
git clone <this repository>
cd homelab-infra

cp .env.example .env
$EDITOR .env          # set domains, paths, and generate every secret

make init             # data directories and permissions
make check            # validate prerequisites and compose config
make up
make healthcheck
```

Every password and token in `.env.example` is a placeholder. `make check`
reports how many `CHANGE_ME` values are still in place.

---

## Design decisions

**Compose rather than Kubernetes.** The workload is a single host with a GPU.
Kubernetes would add an orchestration layer whose failure modes are harder to
debug than the problems it would solve here.

**One stack per responsibility.** Stacks are included from a root compose file
and can be disabled by commenting out a single line. They share one network,
declared once at the root; included files inherit it rather than redeclaring
it.

**Pinned tags, with three exceptions.** Cloudflared, Excalidraw and Ollama
track `latest` because they hold no state worth a rollback. Everything else is
pinned so that "what is running" is answerable from the repository.

**Configuration is data, not shell.** `.env` is parsed key by key rather than
sourced. A legitimate value containing spaces — a Gmail app password, for
instance — makes a shell try to execute its second word.
