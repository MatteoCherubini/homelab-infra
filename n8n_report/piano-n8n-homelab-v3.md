# Piano Operativo — n8n Come Cervello del Nexus

### Versione 3.0 | Maggio 2026

> Questo documento sostituisce la v2.0. Le sezioni della v2 relative a
> infrastruttura, sicurezza SSH, SSRF e inventario servizi rimangono valide
> e non vengono ripetute. Qui si documenta solo l'architettura aggiornata
> dei workflow e tutto ciò che rimane da costruire.

---

## Stato Attuale — Cosa è già fatto

| Componente                                          | Stato         | Note                                            |
| --------------------------------------------------- | ------------- | ----------------------------------------------- |
| Utente `n8n-runner` + gruppo docker                 | ✅ Completato | SSH funzionante, `whoami` + `groups` verificati |
| Chiave SSH Ed25519 in n8n credential                | ✅ Completato | Credential `n8n-runner SSH` configurata         |
| Volume `n8n_known_hosts` persistente                | ✅ Completato | Dichiarato nel root compose, popolato           |
| Variabili SSRF nel compose automation               | ✅ Completato | `N8N_SSRF_*` attive                             |
| `N8N_ENCRYPTION_KEY` persistente                    | ✅ Completato | Salvato in Vaultwarden                          |
| Forgejo integrato nel root compose                  | ✅ Completato | Prefisso `homelab-infra-`, rete corretta        |
| WF-2: struttura nodi Webhook+HMAC+Timestamp+Payload | ✅ Parziale   | Nodi creati, da adattare al nuovo flusso        |
| Token GitHub PAT (RSS + repo write)                 | ⬜ Da fare    | Scope: `repo` — legge feed RSS E gestisce PR    |
| Credential GitHub API in n8n                        | ⬜ Da fare    | Token GitHub per creare branch, commit e PR     |
| Tabella `service_versions` in Postgres              | ⬜ Da fare    | Schema in Sezione 3                             |
| Makefile — target `versions` e `gpu-check`          | ⬜ Da fare    | Sezione 4                                       |
| WF-1: RSS Poller                                    | ⬜ Da fare    |                                                 |
| WF-2: LLM Agent + PR Creator                        | ⬜ Da fare    |                                                 |
| WF-3: PR Merge Handler                              | ⬜ Da fare    |                                                 |
| WF-4: Weekly Digest                                 | ⬜ Da fare    |                                                 |
| WF-5: Nightly Deploy                                | ⬜ Da fare    |                                                 |

---

## Indice

1. [Decisione Architetturale — Perché PR invece di Webhook](#1-decisione-architetturale)
2. [Flusso Completo End-to-End](#2-flusso-completo-end-to-end)
3. [Schema Database — Tabella Completa](#3-schema-database)
4. [Makefile — Target da Aggiungere](#4-makefile)
5. [I 5 Workflow — Specifica Completa](#5-i-5-workflow)
6. [LLM Agent — Configurazione e Prompt](#6-llm-agent)
7. [Logica Semver e Parsing Versioni](#7-logica-semver)
8. [Gestione Rate Limiting GitHub](#8-rate-limiting)
9. [Protocolli Speciali di Aggiornamento](#9-protocolli-speciali)
10. [Deployment Timing e Health Check](#10-deployment-timing)
11. [Strategia Notifiche ntfy](#11-notifiche)
12. [Credenziali da Configurare in n8n](#12-credenziali)
13. [Roadmap](#13-roadmap)

---

## 1. Decisione Architetturale

### Perché PR su Forgejo invece del Webhook di Approvazione

La v2 usava un webhook HMAC su cui cliccare per approvare ogni aggiornamento.
La v3 usa le **Pull Request di Forgejo** come meccanismo di approvazione.

Il cambio non è cosmético — cambia il modello di sicurezza e di tracciabilità:

| Aspetto               | v2 — Webhook HMAC                | v3 — Pull Request Forgejo       |
| --------------------- | -------------------------------- | ------------------------------- |
| Approvazione          | Click su link nel messaggio ntfy | Merge della PR su Forgejo       |
| Diff visibile         | No — solo notifica testo         | ✅ Sì — diff completo dei file  |
| Storico decisioni     | Solo nel DB                      | ✅ Git history permanente       |
| Rollback              | Manuale                          | ✅ `git revert` del commit      |
| Complessità sicurezza | Alta (HMAC, replay window)       | Bassa — Forgejo gestisce l'auth |
| Modifica file         | n8n scrive direttamente          | ✅ LLM propone, tu approvi      |
| Audit trail           | Parziale                         | ✅ Completo — chi, cosa, quando |

Il risultato: **tu non approvi un'azione, approvi una modifica di codice**.
Git diventa il registro di tutto ciò che è mai successo all'infrastruttura.

### Cosa succede ai nodi HMAC già costruiti

I nodi Webhook + HMAC + Timestamp + Payload già creati in n8n non vanno
eliminati — vengono **riutilizzati nel WF-3** per ricevere in modo sicuro il
webhook che Forgejo manda quando una PR viene mergiata.

---

## 2. Flusso Completo End-to-End

```
┌─────────────────────────────────────────────────────────────────────────┐
│  GitHub RSS Feed                                                         │
│  (ogni 6 ore)                                                            │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │ nuova versione rilevata
                       ▼
             ┌─────────────────┐
             │   WF-1          │
             │   RSS Poller    │  → aggiorna DB (status: pending)
             └────────┬────────┘
                      │
          ┌───────────┴────────────┐
          │                        │
          ▼                        ▼
    criticality =           criticality =
    stateless               critical/medium/low
          │                        │
          │                        ▼
          │              ┌─────────────────┐
          │              │   WF-2          │
          │              │   LLM Agent     │  → legge compose + README
          │              │   + PR Creator  │  → modifica file via LLM
          │              └────────┬────────┘  → apre PR su Forgejo
          │                       │            → ntfy: "PR aperta"
          │                       ▼
          │              ┌─────────────────┐
          │              │   Tu            │
          │              │   (Forgejo UI)  │  → leggi diff
          │              │                 │  → valuti, commenti
          └──────────────┤                 │  → mergi o chiudi PR
                         └────────┬────────┘
                                  │ merge event
                                  ▼
                         ┌─────────────────┐
                         │   WF-3          │
                         │   PR Merge      │  → SSH: make versions
                         │   Handler       │  → Postgres: UPDATE versioni
                         └────────┬────────┘  → status: pr_merged
                                  │
                    ┌─────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
           ┌─────────────────┐         ┌─────────────────┐
           │   WF-4          │         │   WF-5          │
           │   Weekly Digest │         │   Nightly Deploy│
           │   (dom 08:00)   │         │   (ogni 03:00)  │
           └─────────────────┘         └────────┬────────┘
                                                 │
                                    ┌────────────▼────────────┐
                                    │ SSH: make gpu-check      │
                                    │ SSH: make pull           │
                                    │ SSH: make down           │
                                    │ SSH: make up-gpu         │
                                    │ polling health status    │
                                    │ ntfy: esito deploy       │
                                    └─────────────────────────┘
```

---

## 3. Schema Database

La tabella `service_versions` è la fonte di verità **operativa** del sistema.
Le versioni attuali vengono lette dai compose file tramite `make versions` —
non inserite a mano — quindi il DB riflette sempre lo stato reale del repo.

### Creazione Tabella

Creare un workflow di init in n8n con un nodo **Postgres → Execute Query**:

```sql
CREATE TABLE IF NOT EXISTS service_versions (

  -- Identità
  id                    SERIAL PRIMARY KEY,
  service_name          VARCHAR(64) UNIQUE NOT NULL,
  display_name          VARCHAR(128),
  image_name            VARCHAR(128) NOT NULL,

  -- Posizione nel repository
  stack_name            VARCHAR(64) NOT NULL,
  compose_file          VARCHAR(256) NOT NULL,
  update_target         VARCHAR(8) NOT NULL
                        CHECK (update_target IN ('env','compose')),
  env_var_name          VARCHAR(64),

  -- Classificazione
  criticality           VARCHAR(16) NOT NULL
                        CHECK (criticality IN ('critical','medium','low','stateless')),
  special_protocol      VARCHAR(32),
  linked_services       VARCHAR(256),

  -- Versioni
  current_version       VARCHAR(64),
  latest_version        VARCHAR(64),
  previous_version      VARCHAR(64),

  -- Monitoraggio RSS
  rss_url               VARCHAR(256) NOT NULL,
  last_checked_at       TIMESTAMPTZ,
  check_count           INTEGER DEFAULT 0,

  -- Analisi bump
  bump_type             VARCHAR(8)
                        CHECK (bump_type IN ('major','minor','patch','none')),
  is_major_bump         BOOLEAN DEFAULT FALSE,

  -- Stato corrente
  status                VARCHAR(16) DEFAULT 'current'
                        CHECK (status IN (
                          'current',
                          'pending',
                          'pr_open',
                          'pr_merged',
                          'deploying',
                          'deployed',
                          'blocked',
                          'skipped',
                          'failed'
                        )),

  -- GitHub PR
  pr_number             INTEGER,
  pr_url                VARCHAR(256),
  pr_branch             VARCHAR(128),
  pr_created_at         TIMESTAMPTZ,
  pr_merged_at          TIMESTAMPTZ,
  pr_merged_by          VARCHAR(64),

  -- Deploy
  deploy_started_at     TIMESTAMPTZ,
  deployed_at           TIMESTAMPTZ,
  deploy_duration_sec   INTEGER,
  deploy_log            TEXT,

  -- Timestamp generali
  detected_at           TIMESTAMPTZ,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW(),

  notes                 TEXT
);

CREATE INDEX IF NOT EXISTS idx_sv_status       ON service_versions(status);
CREATE INDEX IF NOT EXISTS idx_sv_criticality  ON service_versions(criticality);
CREATE INDEX IF NOT EXISTS idx_sv_last_checked ON service_versions(last_checked_at);
```

### Popolamento Iniziale

Secondo nodo Postgres nello stesso workflow di init:

```sql
INSERT INTO service_versions (
  service_name, display_name, image_name,
  stack_name, compose_file, update_target, env_var_name,
  criticality, special_protocol, linked_services,
  current_version, rss_url
) VALUES
('nextcloud',           'Nextcloud',            'nextcloud',
 'cloud',       'stacks/cloud/compose.yml',       'compose', NULL,
 'critical', NULL, NULL,
 '33.0.2', 'https://github.com/nextcloud/server/releases.atom'),

('immich',              'Immich',               'ghcr.io/immich-app/immich-server',
 'photos',      'stacks/photos/compose.yml',      'compose', NULL,
 'critical', 'immich-cuda', 'immich-machine-learning',
 'v2.7.5', 'https://github.com/immich-app/immich/releases.atom'),

('paperless-ngx',       'Paperless-ngx',        'ghcr.io/paperless-ngx/paperless-ngx',
 'docs',        'stacks/docs/compose.yml',        'compose', NULL,
 'critical', NULL, NULL,
 '2.20.13', 'https://github.com/paperless-ngx/paperless-ngx/releases.atom'),

('vaultwarden',         'Vaultwarden',          'vaultwarden/server',
 'security',    'stacks/security/compose.yml',    'compose', NULL,
 'critical', 'vaultwarden', NULL,
 '1.33.2', 'https://github.com/dani-garcia/vaultwarden/releases.atom'),

('kopia',               'Kopia',                'kopia/kopia',
 'storage',     'stacks/storage/compose.yml',     'compose', NULL,
 'critical', NULL, NULL,
 '0.19', 'https://github.com/kopia/kopia/releases.atom'),

('n8n',                 'n8n',                  'n8nio/n8n',
 'automation',  'stacks/automation/compose.yml',  'compose', NULL,
 'medium', NULL, 'n8n-worker',
 '2.15.0', 'https://github.com/n8n-io/n8n/releases.atom'),

('ollama',              'Ollama',               'ollama/ollama',
 'ai',          'stacks/ai/compose.yml',          'compose', NULL,
 'medium', NULL, NULL,
 '0.21.0', 'https://github.com/ollama/ollama/releases.atom'),

('open-webui',          'Open WebUI',           'ghcr.io/open-webui/open-webui',
 'ai',          'stacks/ai/compose.yml',          'compose', NULL,
 'medium', NULL, NULL,
 'v0.8.12', 'https://github.com/open-webui/open-webui/releases.atom'),

('headscale',           'Headscale',            'headscale/headscale',
 'core',        'stacks/core/compose.yml',        'compose', NULL,
 'medium', NULL, NULL,
 '0.25', 'https://github.com/juanfont/headscale/releases.atom'),

('nginx-proxy-manager', 'Nginx Proxy Manager',  'jc21/nginx-proxy-manager',
 'core',        'stacks/core/compose.yml',        'compose', NULL,
 'medium', NULL, NULL,
 '2.14.0', 'https://github.com/NginxProxyManager/nginx-proxy-manager/releases.atom'),

('portainer',           'Portainer',            'portainer/portainer-ce',
 'core',        'stacks/core/compose.yml',        'compose', NULL,
 'medium', NULL, NULL,
 '2.25.1', 'https://github.com/portainer/portainer/releases.atom'),

('grafana',             'Grafana',              'grafana/grafana',
 'monitoring',  'stacks/monitoring/compose.yml',  'compose', NULL,
 'low', NULL, NULL,
 '11.5.2', 'https://github.com/grafana/grafana/releases.atom'),

('loki',                'Loki',                 'grafana/loki',
 'monitoring',  'stacks/monitoring/compose.yml',  'compose', NULL,
 'low', NULL, 'promtail',
 '3.4.2', 'https://github.com/grafana/loki/releases.atom'),

('netdata',             'Netdata',              'netdata/netdata',
 'monitoring',  'stacks/monitoring/compose.yml',  'compose', NULL,
 'low', NULL, NULL,
 'v2.3.0', 'https://github.com/netdata/netdata/releases.atom'),

('ntfy',                'ntfy',                 'binwiederhier/ntfy',
 'tools',       'stacks/tools/compose.yml',       'compose', NULL,
 'low', NULL, NULL,
 'v2.11.0', 'https://github.com/binwiederhier/ntfy/releases.atom'),

('cloudflared',         'Cloudflared',          'cloudflare/cloudflared',
 'core',        'stacks/core/compose.yml',        'compose', NULL,
 'stateless', NULL, NULL,
 'latest', 'https://github.com/cloudflare/cloudflared/releases.atom')

ON CONFLICT (service_name) DO NOTHING;
```

---

## 4. Makefile

Aggiungere questi due target al Makefile esistente:

```makefile
versions: ## Lista versioni correnti di tutti i servizi (JSON per n8n)
	@docker compose config --format json | \
	  jq -r '.services | to_entries[] | \
	  "\(.key)\t\(.value.image)"' | sort

gpu-check: ## Verifica presenza GPU NVIDIA (usato da WF-5 prima del deploy)
	@nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
	  && echo "GPU_OK" || echo "GPU_MISSING"
```

`make versions` restituisce una riga per servizio nel formato:

```
homelab-infra-grafana-1    grafana/grafana:11.5.2
homelab-infra-n8n-1        n8nio/n8n:2.15.0
immich_server              ghcr.io/immich-app/immich-server:v2.7.5
...
```

WF-1 usa questo output all'inizio di ogni run per sincronizzare
`current_version` nel DB con lo stato reale del repository — non quello
scritto a mano mesi fa.

---

## 5. I 5 Workflow

### WF-1 — RSS Poller

**Trigger:** Cron `0 */6 * * *`
**Carico:** Minimo

```
[Cron]
  ↓
[SSH: make versions]
  source /etc/environment && cd /opt/homelab-infra && make versions
  ↓
[Code: Parse output make versions]
  Estrai service_name e current_version da ogni riga
  ↓
[Postgres: UPDATE current_version per ogni servizio]
  UPDATE service_versions SET current_version = $1, updated_at = NOW()
  WHERE service_name = $2
  ↓
[Postgres: SELECT tutti i servizi]
  ↓
[SplitInBatches: 1 alla volta]
  ↓
[Wait: 1.5 secondi]  ← throttling GitHub API
  ↓
[HTTP Request: GET {rss_url}]
  Header: Authorization: token {GitHub PAT}
  ↓
[Code: ParseRSS + Semver]  ← logica completa in Sezione 7
  ↓
[IF: nessun aggiornamento o già pending]
  → skip
  ↓
[IF: is_major_bump E criticality = 'critical']
  → Postgres UPDATE status = 'blocked'
  → ntfy IMMEDIATO: "⛔ Major version: {service} {current} → {latest}"
  → skip WF-2
  ↓
[IF: criticality = 'stateless']
  → Postgres UPDATE status = 'pr_merged'  ← va direttamente al deploy notturno
  → skip WF-2
  ↓
[ELSE: pending normale]
  → Postgres UPDATE:
      latest_version = X
      bump_type = Y
      is_major_bump = Z
      status = 'pending'
      detected_at = NOW()
  → Trigger WF-2
```

---

### WF-2 — LLM Agent + PR Creator

**Trigger:** Da WF-1 (su ogni nuovo pending non bloccato)
**Dipendenze:** Credential `GitHub API Token`, LLM (Ollama o Anthropic)

> Il repository `homelab-infra` è su **GitHub**. Tutte le API calls usano
> `api.github.com`. Il token GitHub usato qui è diverso da quello RSS
> (read-only) — serve scope di scrittura (vedi Sezione 12).

```
[Input da WF-1]
  { service_name, latest_version, bump_type, compose_file, special_protocol, linked_services }
  ↓
[SSH: leggi compose file corrente]
  source /etc/environment && cat /opt/homelab-infra/{compose_file}
  ↓
[SSH: leggi sezione versioni del README]
  source /etc/environment && cat /opt/homelab-infra/README.md
  ↓
[LLM Agent]  ← vedi Sezione 6 per il prompt completo
  Input: compose attuale + README + dettagli aggiornamento
  Output JSON: { compose_updated, readme_table_updated, commit_message }
  ↓
[Code: Valida output LLM]
  Verifica che la nuova versione sia presente nel compose aggiornato
  Verifica che il numero di righe non sia cambiato drasticamente
  Verifica che la vecchia versione non sia ancora presente nei tag image:
  Se validazione fallisce → ntfy alert + STOP
  ↓
[GitHub API: Recupera SHA del branch main]
  GET https://api.github.com/repos/{owner}/{repo}/git/ref/heads/main
  → estrai object.sha  (serve per creare il branch)
  ↓
[GitHub API: Crea branch]
  POST https://api.github.com/repos/{owner}/{repo}/git/refs
  Body: {
    "ref": "refs/heads/update/{service}-{version}",
    "sha": "{sha_main}"
  }
  ↓
[GitHub API: Recupera SHA attuale del compose file]
  GET https://api.github.com/repos/{owner}/{repo}/contents/{compose_file}
      ?ref=update/{service}-{version}
  → estrai sha  (obbligatorio per l'update)
  ↓
[GitHub API: Aggiorna compose file]
  PUT https://api.github.com/repos/{owner}/{repo}/contents/{compose_file}
  Body: {
    "message": "{commit_message}",
    "content": "{base64(compose_updated)}",
    "branch": "update/{service}-{version}",
    "sha": "{sha_compose}"
  }
  ↓
[GitHub API: Recupera SHA attuale del README]
  GET https://api.github.com/repos/{owner}/{repo}/contents/README.md
      ?ref=update/{service}-{version}
  ↓
[GitHub API: Aggiorna README]
  PUT https://api.github.com/repos/{owner}/{repo}/contents/README.md
  Body: {
    "message": "docs: update versions table for {service} {version}",
    "content": "{base64(readme_updated)}",
    "branch": "update/{service}-{version}",
    "sha": "{sha_readme}"
  }
  ↓
[GitHub API: Apri Pull Request]
  POST https://api.github.com/repos/{owner}/{repo}/pulls
  Body: {
    "title": "chore(deps): update {service} to {version}",
    "body": "{PR_BODY_TEMPLATE}",
    "head": "update/{service}-{version}",
    "base": "main"
  }
  → risposta: { number, html_url }
  ↓
[Postgres: UPDATE]
  SET status = 'pr_open',
      pr_number = {number},
      pr_url = {html_url},
      pr_branch = "update/{service}-{version}",
      pr_created_at = NOW()
  ↓
[ntfy]
  Topic: homelab-updates
  Priority: default
  "📬 PR aperta: {service} {current} → {latest} [{bump_type}]
   🔗 {html_url}"
  Action button: "Apri PR" → link diretto a GitHub
```

> **Nota sui due token GitHub:** il PAT per il RSS (read-only, già pianificato)
> e questo per le API write sono separati per il principio del minimo privilegio.
> In alternativa si può usare lo stesso PAT con scope esteso — vedi Sezione 12.

**Template corpo PR:**

```markdown
## Aggiornamento automatico — {service}

| Campo               | Valore               |
| ------------------- | -------------------- |
| Versione attuale    | `{current_version}`  |
| Nuova versione      | `{latest_version}`   |
| Tipo bump           | `{bump_type}`        |
| Criticità           | `{criticality}`      |
| Protocollo speciale | `{special_protocol}` |

### File modificati

- `{compose_file}` — tag immagine aggiornato
- `README.md` — tabella versioni aggiornata

### Changelog

{link_alle_release_notes}

### Note

Generato automaticamente da n8n. Verificare il diff prima di mergiare.
```

---

### WF-3 — PR Merge Handler

**Trigger:** Webhook Forgejo (evento: `pull_request` con action `closed` + `merged: true`)
**Sicurezza:** I nodi HMAC + Timestamp + Payload già costruiti vengono riutilizzati qui

#### Configurazione Webhook su Forgejo

In Forgejo: Repository → Settings → Webhooks → Add Webhook → Gitea

```
URL:         https://n8n.keruhomelab.com/webhook/pr-merged
Secret:      {N8N_WEBHOOK_HMAC_SECRET}  ← stesso valore nel .env
Content Type: application/json
Events:       Pull Requests
```

#### Flusso

```
[Webhook Trigger: POST /pr-merged]
  ↓
[Code: HMAC Validation]  ← nodo già costruito, adatta header a 'X-Gitea-Signature'
  ↓
[Code: Filtra solo PR mergiate su main]
  IF payload.action != 'closed' OR payload.pull_request.merged != true → stop
  IF payload.pull_request.base.ref != 'main' → stop
  ↓
[Code: Estrai service_name dal branch]
  branch = payload.pull_request.head.label  → es. "update/n8n-v2.16.0"
  service_name = branch.replace('update/', '').split('-v')[0]  → "n8n"
  merged_by = payload.pull_request.merged_by.login
  ↓
[SSH: make versions]
  source /etc/environment && cd /opt/homelab-infra && make versions
  ↓
[Code: Parse output + estrai versione aggiornata del servizio]
  ↓
[Postgres: UPDATE]
  SET status = 'pr_merged',
      current_version = {versione_da_make_versions},
      previous_version = {vecchia current_version},
      pr_merged_at = NOW(),
      pr_merged_by = {merged_by},
      updated_at = NOW()
  WHERE service_name = {service_name}
  ↓
[ntfy]
  "✅ PR mergiata: {service} → {version}
   Deploy programmato per stanotte alle 03:00"
```

---

### WF-4 — Weekly Digest

**Trigger:** Cron `0 8 * * 0` (domenica ore 08:00)
**Scopo:** Riepilogo settimanale dello stato — anti notification fatigue

```
[Cron: domenica 08:00]
  ↓
[Postgres: Query stato]
  SELECT * FROM service_versions
  WHERE status IN ('pending','pr_open','pr_merged','blocked','failed')
  ORDER BY criticality, service_name
  ↓
[IF: nessun record]
  → ntfy: "✅ Nexus è aggiornato — nessun pending"
  → STOP
  ↓
[Code: Costruisci messaggio raggruppato per status]

  ⛔ BLOCCATI (major version — intervento manuale):
  • postgres-*: 16 → 17 [MAJOR]

  📬 PR APERTE (in attesa della tua review):
  • vaultwarden: 1.33.2 → 1.34.0 [link PR]
  • immich: v2.7.5 → v2.8.0 [link PR]

  ✅ PR MERGIATE (deploy stanotte):
  • n8n: 2.15.0 → 2.16.0

  ⏳ IN ANALISI (LLM non ancora avviato):
  • open-webui: v0.8.12 → v0.9.0

  ❌ FALLITI (richiede attenzione):
  • grafana: deploy fallito il {data}
  ↓
[ntfy]
  Topic: homelab-updates
  Priority: default
  Action buttons: link diretto a ogni PR aperta
```

---

### WF-5 — Nightly Deploy

**Trigger:** Cron `0 3 * * *`
**Durata attesa:** 10-20 minuti (COMPOSE_PARALLEL_LIMIT=1, 30+ container)

```
[Cron: 03:00]
  ↓
[Postgres: Query]
  SELECT service_name, latest_version FROM service_versions
  WHERE status = 'pr_merged'
  ↓
[IF: nessun record]
  → STOP silente — nessuna notifica
  ↓
[Salva lista servizi da aggiornare per il report finale]
  ↓
[SSH: make gpu-check]
  source /etc/environment && cd /opt/homelab-infra && make gpu-check
  ↓
[IF: output = 'GPU_MISSING']
  → ntfy URGENTE: "🚨 GPU non rilevata — deploy annullato. nvidia-smi fallito."
  → Postgres: UPDATE status = 'failed' WHERE status = 'pr_merged'
  → STOP
  ↓
[Postgres: UPDATE status = 'deploying', deploy_started_at = NOW()]
  ↓
[SSH: make pull]
  source /etc/environment && cd /opt/homelab-infra && make pull
  Timeout: 15 minuti
  ↓
[IF: make pull fallisce]
  → ntfy URGENTE: "🚨 make pull fallito"
  → STOP
  ↓
[SSH: make down]
  source /etc/environment && cd /opt/homelab-infra && make down
  ↓
[SSH: make up-gpu]
  source /etc/environment && cd /opt/homelab-infra && make up-gpu
  Timeout: 10 minuti
  ↓
[Polling Health — loop ogni 30s, max 10 tentativi]
  SSH: docker compose ps --format json | \
       jq '[.[] | select(.State == "restarting" or .Health == "unhealthy")] | length'
  IF output = 0 → tutti healthy, procedi
  IF tentativi esauriti → gestione errore
  ↓
[SSH: make health]
  ↓
[IF: container unhealthy]
  → ntfy priority:urgent:
    "🚨 DEPLOY PARZIALE — Container unhealthy: {lista}
     Intervento manuale richiesto. NON ritentare automaticamente."
  → Postgres: UPDATE status = 'failed', deploy_log = {output make health}
  → STOP
  ↓
[Postgres: UPDATE]
  SET status = 'deployed',
      deployed_at = NOW(),
      deploy_duration_sec = (NOW() - deploy_started_at),
      previous_version = current_version,
      current_version = latest_version
  WHERE status = 'deploying'
  ↓
[ntfy]
  Topic: homelab-deploy
  Priority: default
  "✅ Deploy completato — {timestamp}
   {lista: service vOLD → vNEW}
   Tutti i container healthy."
```

---

## 6. LLM Agent

### Scelta del Modello

Per il task specifico (editing preciso di file YAML e Markdown), le opzioni
in ordine di qualità:

| Opzione | Modello                           | Pro                                            | Contro                                                 |
| ------- | --------------------------------- | ---------------------------------------------- | ------------------------------------------------------ |
| A       | Ollama interno (qwen2.5-coder:7b) | Privato, zero costo, zero latenza rete         | Qualità inferiore sui casi limite CUDA/linked services |
| B       | Anthropic API (claude-haiku-4-5)  | Qualità superiore, gestisce bene i casi limite | Chiamata esterna, costo minimo                         |

**Raccomandazione:** Inizia con Ollama. Se si verificano errori di editing
(versione inserita nel posto sbagliato, formattazione rotta), passa ad
Anthropic API. Il costo per questo task è trascurabile (pochi centesimi al mese).

### Configurazione in n8n

**Opzione A — Ollama:**
Nodo: `Ollama` oppure `HTTP Request` a `http://homelab-infra-ollama-gpu-1:11434/api/generate`

**Opzione B — Anthropic:**
Nodo: `HTTP Request`

```
URL: https://api.anthropic.com/v1/messages
Headers:
  x-api-key: {Anthropic API Key}
  anthropic-version: 2023-06-01
  content-type: application/json
```

### Il Prompt

```
Sei un assistente specializzato nell'aggiornamento di file Docker Compose
e README di progetti homelab.

Ricevi in input:
1. Il contenuto attuale del file compose dello stack da modificare
2. La sezione "Versioni immagini" del README
3. I dettagli dell'aggiornamento da applicare

Il tuo output deve essere ESCLUSIVAMENTE un oggetto JSON valido, senza
testo prima o dopo, senza backtick markdown, senza spiegazioni.

---
FILE COMPOSE ATTUALE:
{compose_content}

---
SEZIONE README ATTUALE (solo la tabella versioni):
{readme_versions_table}

---
AGGIORNAMENTO DA APPLICARE:
- Servizio: {service_name}
- Immagine: {image_name}
- Versione corrente: {current_version}
- Nuova versione: {latest_version}
- Tipo bump: {bump_type}
- Protocollo speciale: {special_protocol}
- Servizi collegati: {linked_services}

---
REGOLE OBBLIGATORIE:
1. Modifica SOLO il tag versione dell'immagine specificata
2. Se special_protocol = 'immich-cuda':
   - Aggiorna il tag di immich-server a {latest_version}
   - Aggiorna il tag di immich-machine-learning a {latest_version}-cuda
3. Se linked_services non è vuoto, aggiorna anche quei servizi alla stessa versione
4. Non modificare nulla oltre ai tag versione (niente commenti, niente spazi)
5. Mantieni esattamente la formattazione e l'indentazione originale
6. Nella tabella README aggiorna solo la riga del servizio interessato

---
STRUTTURA OUTPUT JSON RICHIESTA:
{
  "compose_updated": "intero contenuto del compose aggiornato",
  "readme_table_updated": "intera tabella markdown aggiornata",
  "commit_message": "chore(deps): update SERVICE to vVERSION",
  "changes_summary": "descrizione in una riga di cosa è stato modificato"
}
```

### Validazione Post-LLM

Dopo che l'LLM risponde, il nodo Code di validazione controlla:

```javascript
const output = JSON.parse($input.first().json.response);

// 1. La nuova versione è presente nel compose aggiornato?
if (!output.compose_updated.includes(item.latest_version)) {
  throw new Error(
    `Versione ${item.latest_version} non trovata nel compose aggiornato`,
  );
}

// 2. Il numero di righe non è cambiato drasticamente (±5 righe tollerance)?
const originalLines = item.compose_content.split("\n").length;
const updatedLines = output.compose_updated.split("\n").length;
if (Math.abs(originalLines - updatedLines) > 5) {
  throw new Error(
    `Modifica sospetta: ${originalLines} → ${updatedLines} righe`,
  );
}

// 3. La vecchia versione NON è più presente (salvo nei commenti)
const nonCommentLines = output.compose_updated
  .split("\n")
  .filter((l) => !l.trim().startsWith("#"));
const oldVersionStillPresent = nonCommentLines.some(
  (l) => l.includes(item.current_version) && l.includes("image:"),
);
if (oldVersionStillPresent) {
  throw new Error(`Vecchia versione ${item.current_version} ancora presente`);
}

return [{ json: output }];
```

---

## 7. Logica Semver

Da inserire nel nodo Code di WF-1, dopo il fetch RSS:

```javascript
function parseAndCompare(current, latest) {
  function normalize(v) {
    return v
      .replace(/^v/i, "")
      .replace(/-cuda.*$/i, "")
      .replace(/-apache.*$/i, "")
      .replace(/-alpine.*$/i, "");
  }

  function isPreRelease(v) {
    return /alpha|beta|rc\d*|dev|nightly|preview/i.test(v);
  }

  function extractParts(v) {
    const parts = v.split(".").map((p) => parseInt(p, 10) || 0);
    return { major: parts[0] || 0, minor: parts[1] || 0, patch: parts[2] || 0 };
  }

  const c = extractParts(normalize(current));
  const l = extractParts(normalize(latest));

  let bumpType = "none";
  let isMajorBump = false;

  if (l.major > c.major) {
    bumpType = "major";
    isMajorBump = true;
  } else if (l.major === c.major && l.minor > c.minor) {
    bumpType = "minor";
  } else if (l.major === c.major && l.minor === c.minor && l.patch > c.patch) {
    bumpType = "patch";
  }

  return { bumpType, isMajorBump, isPreRelease: isPreRelease(latest) };
}

function extractLatestVersion(rssXml) {
  const entryMatch = rssXml.match(/<entry>([\s\S]*?)<\/entry>/);
  if (!entryMatch) return null;
  const titleMatch = entryMatch[1].match(/<title[^>]*>([^<]+)<\/title>/);
  if (!titleMatch) return null;
  return titleMatch[1].trim().replace(/^Release\s+/i, "");
}
```

**Casi speciali da gestire:**

| Versione                    | Comportamento                                                 |
| --------------------------- | ------------------------------------------------------------- |
| `v2.7.5-cuda`               | Suffix rimosso per confronto, riaggiunto nell'output LLM      |
| `16-alpine`                 | Il "16" è il Major — bump a `17-alpine` = major bump bloccato |
| `2025.01.20` (headscale-ui) | Confronto date: stringa > stringa                             |
| `1.0-rc1`                   | Filtrato come pre-release — ignorato                          |

---

## 8. Rate Limiting GitHub

**Budget:** 16 servizi × 4 check/giorno = **64 richieste/giorno**
Con PAT: limite 5.000/ora — nessun problema reale.
Senza PAT: limite condiviso da tutto l'IP — rischio.

**Regola:** usare sempre il PAT. Throttling fisso di **1.5 secondi** tra
ogni richiesta nel loop SplitInBatches di WF-1.

**Gestione 429:**

```javascript
if ($input.first().statusCode === 429) {
  const reset = parseInt($input.first().headers["x-ratelimit-reset"]) * 1000;
  const waitMs = Math.max(reset - Date.now() + 60000, 60000);
  // Connetti a nodo Wait dinamico con valore waitMs/1000 secondi
}
```

---

## 9. Protocolli Speciali di Aggiornamento

### Vaultwarden

WF-2 deve aggiungere nel corpo della PR un avviso:

```markdown
⚠️ PROTOCOLLO VAULTWARDEN RICHIESTO
Prima di mergiare, eseguire manualmente sul server:

1. Backup database:
   docker exec homelab-infra-vaultwarden-db-1 \
    pg_dump -U ${VAULTWARDEN_DB_USER} ${VAULTWARDEN_DB_NAME} \

   > /opt/homelab-backup/vaultwarden-$(date +%Y%m%d).sql

2. Backup file (attachments + chiavi RSA):
   docker run --rm \
    -v vaultwarden_data:/source:ro \
    -v /opt/homelab-backup:/backup \
    alpine tar czf /backup/vaultwarden-files-$(date +%Y%m%d).tar.gz \
    -C /source attachments rsa_key.pem rsa_key.pub.pem

Solo dopo aver verificato i backup, procedere con il merge.
```

### Immich CUDA

Il prompt LLM include la regola esplicita per il protocollo `immich-cuda`:
aggiornare simultaneamente `immich-server` (tag `vX.Y.Z`) e
`immich-machine-learning` (tag `vX.Y.Z-cuda`) nello stesso commit.

### Postgres Major Version

WF-1 imposta automaticamente `status = 'blocked'` e non avvia WF-2.
La notifica ntfy contiene le istruzioni operative:

```
⛔ BLOCCO MANUALE: {service}
{current} → {latest} [MAJOR VERSION]

Procedura richiesta:
1. pg_dump di tutti i database dello stack
2. make down per lo stack interessato
3. Aggiorna tag nel compose manualmente
4. pg_upgrade o restore da dump
5. make up per lo stack
6. Verifica integrità
7. UPDATE service_versions SET status='current' WHERE service_name='{service}'
```

---

## 10. Deployment Timing

| Operazione      | Stima          | Note                                |
| --------------- | -------------- | ----------------------------------- |
| `make pull`     | 2-15 min       | Dipende dalle immagini da scaricare |
| `make down`     | ~30 sec        | Stop sequenziale                    |
| `make up-gpu`   | 3-5 min        | COMPOSE_PARALLEL_LIMIT=1            |
| Stabilizzazione | 1-3 min        | Postgres e Immich DB più lenti      |
| `make health`   | <10 sec        | Solo lettura                        |
| **Totale WF-5** | **~10-20 min** | Alle 03:00 — nessun impatto utenti  |

**Polling loop** nel WF-5 invece di sleep fisso:
ogni 30 secondi per massimo 10 iterazioni (5 minuti totali).
Se i container non sono tutti healthy dopo 5 minuti → errore con ntfy urgente.

---

## 11. Notifiche ntfy

| Evento                    | Topic             | Priorità | Quando         |
| ------------------------- | ----------------- | -------- | -------------- |
| PR aperta                 | `homelab-updates` | default  | Immediato      |
| PR mergiata               | `homelab-updates` | default  | Immediato      |
| Major version bloccata    | `homelab-alerts`  | urgent   | Immediato      |
| Deploy completato         | `homelab-deploy`  | default  | Post deploy    |
| Container unhealthy       | `homelab-alerts`  | urgent   | Post deploy    |
| GPU non rilevata          | `homelab-alerts`  | urgent   | Pre deploy     |
| make pull fallito         | `homelab-alerts`  | high     | Durante deploy |
| Digest domenicale         | `homelab-updates` | default  | Dom 08:00      |
| Tutto aggiornato (digest) | `homelab-updates` | min      | Dom 08:00      |

**Regole anti-fatigue:**

- Digest domenicale è l'unica notifica ricorrente per i pending normali
- Deploy senza aggiornamenti → silenzio totale
- Errori ripetuti → max 1 notifica per tipo ogni 24 ore
- Le PR aperte hanno già il link diretto a Forgejo come action button

---

## 12. Credenziali da Configurare in n8n

| Nome                          | Tipo n8n         | Contenuto                                         |
| ----------------------------- | ---------------- | ------------------------------------------------- |
| `GitHub RSS Token`            | HTTP Header Auth | `Authorization: token ghp_...`                    |
| `n8n-runner SSH`              | SSH              | ✅ Già configurata                                |
| `n8n Postgres`                | Postgres         | Host: `n8n-db`, porta 5432, db/user/pass dal .env |
| `Forgejo API`                 | HTTP Header Auth | `Authorization: token {forgejo_token}`            |
| `ntfy Homelab`                | HTTP Header Auth | Token ntfy se auth abilitata                      |
| `Anthropic API` _(opzionale)_ | HTTP Header Auth | `x-api-key: sk-ant-...`                           |

**Generare token Forgejo:**
Forgejo UI → Settings → Applications → Generate Token
Scope richiesti: `repo` (read + write), `issue` (write per le PR)

---

## 13. Roadmap

### Fase A — Fondamenta DB e Makefile _(da fare ora)_

- [ ] Aggiungere target `versions` e `gpu-check` al Makefile
- [ ] Testare `make versions` sul server — verificare output parsabile
- [ ] Creare workflow di init in n8n (Manual Trigger → Postgres CREATE TABLE → Postgres INSERT)
- [ ] Eseguire workflow di init — verificare 16 righe nella tabella
- [ ] Creare credential `Forgejo API` in n8n
- [ ] Creare credential `n8n Postgres` in n8n
- [ ] Creare credential `GitHub RSS Token` in n8n

**Stima: 2-3 ore**

---

### Fase B — WF-1 RSS Poller _(fondamenta dati)_

- [ ] Costruire WF-1 completo con sync `make versions` iniziale
- [ ] Implementare parser RSS + semver (Sezione 7)
- [ ] Attivare e osservare per 24 ore — verificare zero falsi positivi
- [ ] Calibrare il parser per eventuali formati non previsti

**Stima: 3-4 ore + 24h osservazione**

---

### Fase C — WF-2 LLM Agent _(il pezzo più complesso)_

- [ ] Scegliere LLM: Ollama interno vs Anthropic API
- [ ] Costruire il nodo LLM con il prompt della Sezione 6
- [ ] Costruire il nodo di validazione post-LLM
- [ ] Costruire la sequenza Forgejo API (branch → commit → PR)
- [ ] Test su un servizio LOW (es. `ntfy`) con aggiornamento simulato
- [ ] Verificare che il diff nella PR sia corretto
- [ ] Aggiungere protocollo Vaultwarden nel corpo PR
- [ ] Estendere a tutti i tier

**Stima: 5-8 ore**

---

### Fase D — WF-3 PR Merge Handler _(chiusura del loop)_

- [ ] Configurare webhook su Forgejo (URL + secret)
- [ ] Adattare i nodi HMAC/Timestamp già costruiti per `X-Gitea-Signature`
- [ ] Costruire il parser del payload Forgejo
- [ ] Collegare a `make versions` per sync DB post-merge
- [ ] Test end-to-end: PR → merge → DB aggiornato → ntfy

**Stima: 2-3 ore**

---

### Fase E — WF-4 e WF-5 _(completamento)_

- [ ] WF-4: Weekly Digest — costruire e testare con dati reali
- [ ] WF-5: Nightly Deploy con GPU check + polling loop
- [ ] Test WF-5 in orario diurno su aggiornamento LOW
- [ ] Calibrare timeout su tempi reali del Nexus
- [ ] Attivare cron 03:00
- [ ] Osservare per 2 settimane su tier LOW prima di abilitare MEDIUM e CRITICAL

**Stima: 4-5 ore + 2 settimane osservazione**

---

### Fase F — Raffinamento _(ongoing)_

- [ ] Widget Homepage con stato aggiornamenti (API n8n)
- [ ] Backup tabella `service_versions` in Kopia
- [ ] Aggiungere `start_period: 60s` ai compose dei database
- [ ] Valutare Netdata alert su spike risorse durante deploy

---

## Appendice — Comandi Rapidi

```bash
# Stato versioni nel DB
docker exec homelab-infra-n8n-db-1 \
  psql -U n8n -c \
  "SELECT service_name, current_version, latest_version, status, last_checked_at
   FROM service_versions ORDER BY criticality, service_name;"

# Versioni live dai compose
cd /opt/homelab-infra && make versions

# Check GPU
cd /opt/homelab-infra && make gpu-check

# Forzare run WF-1 manuale
# → n8n UI → WF-1 → Execute Workflow

# Container non-healthy
docker compose ps --format json | \
  jq -r '.[] | select(.Health == "unhealthy" or .State == "restarting") | .Name'

# Verificare connessione SSH n8n-runner
ssh -i /home/n8n-runner/.ssh/id_ed25519 \
  n8n-runner@172.20.0.1 "source /etc/environment && whoami && groups"
```
