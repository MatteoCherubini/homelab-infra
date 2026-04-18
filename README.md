# 🏠 Homelab Infrastructure

Infrastruttura Docker Compose modulare, portabile e versionata.

## Quick Start

```bash
git clone <repo> && cd homelab
make init          # crea .env e directory
nano .env          # configura password e path
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

## Aggiungere un nuovo servizio

1. Crea `stacks/nome/compose.yml`
2. Usa `${DATA_ROOT}` e `${MEDIA_ROOT}` per i volumi
3. Usa `${NOME_PORT}` per le porte
4. Aggiungi le variabili in `.env.example`
5. Aggiungi l'include nel `docker-compose.yml` root

## Versioning immagini

| Criticità | Strategia | Esempio |
|-----------|-----------|---------|
| 🔴 Critico | Tag fisso | `postgres:16-alpine`, `nextcloud:30.0.6` |
| 🟠 Medio | Major/minor | `forgejo:10`, `kopia:0.19` |
| 🟢 Non critico | Latest ok | `excalidraw:latest` |

## Sicurezza

- Le password sono nel `.env` (non nel repo)
- `.env` è in `.gitignore`
- Nessun `container_name` (evita conflitti)
- Docker socket montato in `:ro` dove possibile
