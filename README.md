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
| `make up-gpu` | Avvia con GPU NVIDIA |

## Portabilità

Tutta la configurazione dipende da due variabili nel `.env`:

- **`DATA_ROOT`** — config e database (SSD consigliato). Default: `./data`
- **`MEDIA_ROOT`** — file grandi, foto, documenti (RAID/HDD). Default: `./media`

Per migrare su un'altra macchina: clona il repo, copia il `.env`, punta i path ai tuoi dischi, `make up`.

## Disabilitare uno stack

Commenta la riga corrispondente nel `docker-compose.yml` root:

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
