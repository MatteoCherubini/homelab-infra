# Homelab Infrastructure

A self-hosted infrastructure stack running on Ubuntu Server, managed entirely
through Docker Compose and versioned as code.

Thirteen services across six stacks — reverse proxying, Git hosting, workflow
automation with a queue-mode worker, a local LLM runtime on GPU, a password
manager, file sync and push notifications — plus a UPS subsystem that runs on
the host rather than in a container, because ordered shutdown means halting
the host itself.

The point of this repository is not that it runs containers. It is that every
version, hostname and credential lives in one place, that upgrades are checked
automatically and applied deliberately, and that there is a way to tell whether
the thing still works after you have changed it.

---

## Services

| Service             | Stack        | Role                                        |
| ------------------- | ------------ | ------------------------------------------- |
| Nginx Proxy Manager | `core`       | Reverse proxy, TLS termination              |
| Homepage            | `core`       | Dashboard and service discovery             |
| Cloudflared         | `core`       | Cloudflare Tunnel for external access       |
| ntfy                | `core`       | Push notifications, deny-by-default         |
| Ollama              | `ai`         | Local LLM runtime, NVIDIA GPU reservation   |
| n8n                 | `automation` | Workflow automation, queue execution mode   |
| n8n-worker          | `automation` | Executes workflow nodes off the Redis queue |
| PostgreSQL 18       | `automation` | n8n persistence                             |
| Redis 8             | `automation` | n8n job queue                               |
| Syncthing           | `automation` | File ingress, driven by n8n over its API    |
| Forgejo             | `git`        | Self-hosted Git forge                       |
| Vaultwarden         | `security`   | Bitwarden-compatible password manager       |
| Excalidraw          | `tools`      | Whiteboard                                  |

---

## Quick start

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

Every password and token in `.env.example` is a placeholder; `make check`
reports how many are still in place.

---

## Documentation

Detail lives in [`docs/`](docs/README.md).

**Cross-cutting**

- [Architecture](docs/architecture.md) — stacks, networking, external access,
  storage, GPU, and the design decisions behind them
- [Configuration](docs/configuration.md) — the `.env` model, secrets, public
  hostnames, local-only overrides
- [Operations](docs/operations.md) — the `make` targets, first run, day-to-day,
  and what to be careful with
- [Updating](docs/updating.md) — version policy, the release checker, the
  upgrade procedure
- [Testing](docs/testing.md) — the two verification layers, and what neither
  covers

**Per stack**

[core](docs/stacks/core.md) ·
[ai](docs/stacks/ai.md) ·
[automation](docs/stacks/automation.md) ·
[git](docs/stacks/git.md) ·
[security](docs/stacks/security.md) ·
[tools](docs/stacks/tools.md)

**Host-level**

- [UPS orchestration](docs/stacks/ups.md) — NUT, systemd and an SSH forced
  command; runs on the host, not in Compose

---

## Repository layout

```text
.
├── docker-compose.yml       # includes the stacks, declares the shared network
├── docker-compose.override.yml.example
├── .env.example             # single source of truth for versions and config
├── Makefile                 # operational entrypoints
├── stacks/                  # one compose file per responsibility
│   └── core/ ai/ automation/ git/ security/ tools/
├── scripts/
│   ├── init.sh              # first-run setup
│   ├── check-env.sh         # .env vs .env.example drift
│   ├── check_updates.py     # release checker + service manifest
│   ├── healthcheck.sh       # live verification of the running stack
│   └── run-tests.sh         # offline suite
├── tests/                   # unit tests (stdlib unittest, no dependencies)
├── host/                    # artefacts installed on the host, not in a container
├── docs/
├── workflows/               # n8n workflow definitions, exported as JSON
└── services_metadata.json   # per-service criticality and upstream repository
```

Persistent data lives outside the repository, under `DATA_ROOT` and
`MEDIA_ROOT`. Nothing stateful is tracked in git.

---

## How it hangs together

**Configuration is a single source of truth.** No image tag, published port or
public hostname is written into a compose file — they are variable references
resolved from `.env`. `make check-env` fails when `.env` drifts from the
template, and `make verify` compares the tags the repository declares against
the images actually running.

**Upgrades are checked automatically and applied deliberately.** A scheduled
job queries each upstream forge for the newest stable release on the current
major, pushes a summary to ntfy, and asks a local model to rank the updates by
risk. A person then reads the actual release notes and applies the change. That
last step is manual on purpose: the risk assessment reasons from version
numbers alone, and has called a patch release routine on a day when it closed
two remote code execution holes.

**Verification is a first-class artefact.** `make test` runs offline with no
Docker and no `.env`, so it works on a fresh clone and in CI. `make healthcheck`
runs against the live system, asserts on response bodies rather than status
codes, and prints a fingerprint of the n8n database to compare on both sides of
an upgrade.

**Compose rather than Kubernetes.** The workload is a single host with a GPU.
Kubernetes would add an orchestration layer whose failure modes are harder to
debug than the problems it would solve here.
