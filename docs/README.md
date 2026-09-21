# Documentation

Reference for the homelab infrastructure. The [root README](../README.md) is
the overview; this is the detail.

## Cross-cutting

| Document | Covers |
|----------|--------|
| [Architecture](architecture.md) | Stacks, networking, external access, storage, GPU, design decisions |
| [Configuration](configuration.md) | The `.env` model, secrets, public hostnames, local-only overrides |
| [Operations](operations.md) | The `make` targets, first run, day-to-day, what to be careful with |
| [Updating](updating.md) | Version policy, the release checker, the upgrade procedure |
| [Testing](testing.md) | The two verification layers and what neither covers |

## Stacks

| Stack | Services |
|-------|----------|
| [core](stacks/core.md) | Nginx Proxy Manager, Homepage, Cloudflared, ntfy |
| [ai](stacks/ai.md) | Ollama |
| [automation](stacks/automation.md) | n8n, worker, PostgreSQL, Redis, Syncthing |
| [git](stacks/git.md) | Forgejo |
| [security](stacks/security.md) | Vaultwarden |
| [tools](stacks/tools.md) | Excalidraw |

## Host

Not everything runs in a container. Artefacts installed on the host live in
`host/`.

| Document | Covers |
|----------|--------|
| [UPS orchestration](stacks/ups.md) | NUT, systemd, SSH forced command — ordered shutdown on mains failure |

## Conventions

Comments in the code explain the line they sit on; these documents explain
why a thing is shaped the way it is. If an explanation is needed to safely
edit a specific line, it belongs in the file, not here.
