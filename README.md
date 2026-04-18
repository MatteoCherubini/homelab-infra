# Homelab Infrastructure

Docker Compose modulare per AMD Nexus (Ubuntu Server 24.04).

## Quick Start

```bash
git clone <repo> && cd homelab
make init          # crea .env, directory e config
nano .env          # configura password e path
make check         # verifica configurazione
make up            # avvia tutto
```

## Struttura

```
homelab/
├── docker-compose.yml      ← root (include tutti gli stack)
├── .env.example             ← template variabili
├── Makefile                 ← comandi rapidi
├── configs/                 ← template config (copiati da init.sh)
│   ├── headscale/config.yaml
│   ├── loki/loki.yml
│   ├── promtail/config.yml
│   └── garage/garage.toml
├── scripts/init.sh          ← bootstrap ambiente
└── stacks/
    ├── core/        Nginx Proxy Manager, Headscale, Portainer, Homepage
    ├── cloud/       Nextcloud + PostgreSQL + Redis
    ├── photos/      Immich v2 + PostgreSQL + Redis + ML
    ├── docs/        Paperless-ngx + PostgreSQL + Redis
    ├── ai/          Ollama + Open WebUI
    ├── automation/  n8n + PostgreSQL
    ├── git/         Forgejo
    ├── security/    Vaultwarden
    ├── storage/     Garage S3, Kopia
    ├── monitoring/  Netdata, Grafana, Loki, Promtail
    ├── tools/       ntfy, Excalidraw
    └── ups/         NUT (disabilitato di default)
```

## Comandi

| Comando | Descrizione |
|---------|-------------|
| `make up` | Avvia tutto |
| `make down` | Ferma tutto |
| `make ps` | Stato servizi |
| `make logs` | Log live |
| `make pull` | Aggiorna immagini |
| `make check` | Verifica config |
| `make health` | Container non healthy |
| `make up-gpu` | Avvia con GPU NVIDIA |

## Versioni immagini (Aprile 2026)

| Servizio | Versione | Criticità |
|----------|----------|-----------|
| Nextcloud | 30.0.6 | 🔴 Critico — tag fisso |
| Immich | v2.7.5 | 🔴 Critico — tag fisso |
| Paperless-ngx | 2.20.13 | 🔴 Critico — tag fisso |
| Vaultwarden | 1.33.2 | 🔴 Critico — tag fisso |
| PostgreSQL | 16-alpine | 🔴 Critico — major fisso |
| n8n | 1.93 | 🟠 Medio — minor fisso |
| Ollama | 0.21 | 🟠 Medio — minor fisso |
| Open WebUI | v0.8.12 | 🟠 Medio — tag fisso |
| Forgejo | 10 | 🟠 Medio — major fisso |
| Grafana | 11.5.2 | 🟡 Basso — tag fisso |
| Excalidraw | latest | 🟢 Stateless — latest ok |

## Disabilitare uno stack

Commenta la riga nel `docker-compose.yml` root:

```yaml
include:
  - stacks/core/compose.yml
  # - stacks/ai/compose.yml    ← disabilitato
```

## Sicurezza

- Password nel `.env` (gitignored, mai nel repo)
- Backup password in Vaultwarden + copia offline
- Config template in `configs/` (senza segreti)
- Docker socket montato in `:ro` dove possibile
