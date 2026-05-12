# Piano Operativo — n8n Come Cervello del Nexus
### Versione 2.0 — Definitiva | Maggio 2026

> **Decisioni architetturali confermate:**
> - Accesso host via **SSH con utente dedicato `n8n-runner`** (no Docker socket)
> - Notifiche via **ntfy esclusivamente** (mail solo per Major Version su servizi Critici)

---

## Indice

1. [Contesto Infrastrutturale](#1-contesto-infrastrutturale)
2. [Pre-requisiti e Pre-flight Checklist](#2-pre-requisiti-e-pre-flight-checklist)
3. [Architettura di Sicurezza](#3-architettura-di-sicurezza)
4. [Inventario Servizi e Classificazione](#4-inventario-servizi-e-classificazione)
5. [Database delle Versioni](#5-database-delle-versioni)
6. [I 5 Workflow n8n — Specifica Completa](#6-i-5-workflow-n8n--specifica-completa)
7. [Logica Semver e Parsing Versioni](#7-logica-semver-e-parsing-versioni)
8. [Gestione Rate Limiting GitHub](#8-gestione-rate-limiting-github)
9. [Deployment Timing e Health Check](#9-deployment-timing-e-health-check)
10. [Protocolli Speciali di Aggiornamento](#10-protocolli-speciali-di-aggiornamento)
11. [Configurazione Ambiente n8n](#11-configurazione-ambiente-n8n)
12. [Strategia Notifiche ntfy](#12-strategia-notifiche-ntfy)
13. [Roadmap di Implementazione](#13-roadmap-di-implementazione)

---

## 1. Contesto Infrastrutturale

### Hardware Nexus
| Parametro | Dettaglio | Implicazione Operativa |
|---|---|---|
| CPU | AMD Ryzen 5 3600 | Nessun parallelismo aggressivo — COMPOSE_PARALLEL_LIMIT=1 obbligatorio |
| RAM | 16 GB DDR4 | Sufficiente ma non abbondante con 30+ container |
| Storage | RAID 1 — 2× 4TB HDD | **Latenza I/O critica.** Avvii simultanei di Postgres multipli = rischio timeout e corruzione |
| Rete | VLAN 10 (Trusted) | Isolamento servizi critici già presente |
| Accesso Esterno | Cloudflare Tunnel | Bypass CGNAT, protezione DDoS — webhook n8n esposti in modo sicuro |
| Docker | v29.3.1 | API moderne, nessun problema di compatibilità |
| GPU | NVIDIA GTX 1660 Super | Rilevante per Immich ML e Ollama — aggiornamenti CUDA-dependent |
| OS | Ubuntu Server 24.04 LTS | Supporto LTS stabile fino al 2029 |

### Architettura Software Attuale
Il repository usa il pattern `include:` di Docker Compose per separare i servizi in **11 stack funzionali** (core, cloud, photos, docs, ai, automation, git, security, storage, monitoring, tools). Questo design modulare è fondamentale per l'automazione: permette di isolare gli aggiornamenti per stack senza toccare il resto dell'infrastruttura.

**Il `COMPOSE_PARALLEL_LIMIT=1` nel Makefile non è una limitazione casuale.** Con RAID 1 su HDD e Postgres multipli, l'avvio sequenziale elimina la race condition che si crea quando database e applicazione tentano di inizializzarsi contemporaneamente. Il costo è il tempo (stima: **3-5 minuti** per un `make up` completo con 30+ container), ma la stabilità ne vale la pena.

---

## 2. Pre-requisiti e Pre-flight Checklist

Questi punti devono essere risolti **prima di scrivere il primo workflow**. Sono prerequisiti bloccanti.

### 2.1 — Servizi da Stabilizzare

- [ ] **`garage` (S3) — stato `restarting`**: Un'infrastruttura con un servizio in crash loop non è una base affidabile per l'automazione. Diagnosticare e risolvere prima di procedere. Possibili cause: configurazione `garage.toml` errata, permessi sui volumi, porta occupata.
- [ ] **Forgejo — assente dal `docker compose ps`**: Tutto il layer di tracciabilità Git del piano dipende da Forgejo. Verificare se lo stack `git/` è commentato nel `docker-compose.yml` root o se il servizio è in errore silenzioso. **Senza Forgejo, WF-4 non può esistere.**

### 2.2 — Setup SSH `n8n-runner`

Eseguire questi comandi sull'**host Nexus** (non nel container):

```bash
# 1. Crea utente dedicato con home isolata
sudo useradd -m -s /bin/bash n8n-runner

# 2. Aggiungi al gruppo docker (necessario per make up/pull/health)
sudo usermod -aG docker n8n-runner

# 3. Genera coppia di chiavi Ed25519 (non RSA — più sicuro e più veloce)
sudo -u n8n-runner ssh-keygen -t ed25519 -C "n8n-runner@nexus" \
  -f /home/n8n-runner/.ssh/id_ed25519 -N ""

# 4. Autorizza la chiave per il login
sudo -u n8n-runner cp /home/n8n-runner/.ssh/id_ed25519.pub \
  /home/n8n-runner/.ssh/authorized_keys
sudo chmod 600 /home/n8n-runner/.ssh/authorized_keys

# 5. Salva la chiave privata in un percorso accessibile a n8n
sudo cat /home/n8n-runner/.ssh/id_ed25519
# → Copiare l'output e incollarlo come credenziale SSH in n8n

# 6. Pre-popola known_hosts DENTRO il container n8n
# (evita il blocco interattivo alla prima connessione)
docker exec -it homelab-infra-n8n-1 bash -c \
  "ssh-keyscan -H 172.20.0.1 >> /home/node/.ssh/known_hosts 2>/dev/null"
# Nota: 172.20.0.1 è il gateway del bridge homelab — IP host visto dal container
```

> **Perché non `StrictHostKeyChecking=no`**: con questa opzione disabilitata, un attaccante sulla rete potrebbe impersonare l'host senza che n8n se ne accorga. Anche in homelab, pre-popolare i known_hosts è la pratica corretta.

### 2.3 — `sudoers` per `n8n-runner` (opzionale, più sicuro)

Se si vuole evitare di dare a `n8n-runner` l'accesso completo al gruppo docker, è possibile limitare i comandi eseguibili via sudo:

```bash
# Aggiungi in /etc/sudoers.d/n8n-runner
n8n-runner ALL=(ALL) NOPASSWD: \
  /usr/bin/make -C /opt/homelab-infra up, \
  /usr/bin/make -C /opt/homelab-infra pull, \
  /usr/bin/make -C /opt/homelab-infra health, \
  /usr/bin/make -C /opt/homelab-infra check, \
  /usr/bin/sed -i * /opt/homelab-infra/.env, \
  /usr/bin/git -C /opt/homelab-infra *
```

### 2.4 — Token GitHub (PAT)

Creare un **Personal Access Token** su GitHub con scope `public_repo` (read-only):
- GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained
- Scopo: solo lettura dei feed RSS/releases pubblici
- Nessun accesso a repo privati necessario

Salvare il token come **credenziale Header Auth in n8n** (nome: `GitHub RSS Token`), non hardcodato nei workflow.

### 2.5 — Variabili d'Ambiente n8n

Aggiungere al file `.env` del homelab, nella sezione dello stack `automation/`:

```env
# n8n Security
N8N_SSRF_PROTECTION_ENABLED=true
N8N_SSRF_BLOCKED_IP_RANGES=default,169.254.169.254/32
N8N_SSRF_ALLOWED_HOSTNAMES=forgejo.homelab,npm.homelab,ntfy.homelab,nextcloud.homelab
N8N_ENCRYPTION_KEY=<generare con: openssl rand -hex 32>

# n8n Webhook
N8N_WEBHOOK_HMAC_SECRET=<generare con: openssl rand -hex 32>
# Usare questo valore nei workflow come segreto condiviso per la firma HMAC
```

> **`N8N_ENCRYPTION_KEY`**: deve essere **persistente**. Se cambia, n8n non può più decriptare le credenziali salvate (API key, SSH key, token). Salvarlo in Vaultwarden immediatamente.

---

## 3. Architettura di Sicurezza

### 3.1 — Protezione SSRF

n8n dalla v2.12.0 include un firewall applicativo interno. Con `N8N_SSRF_PROTECTION_ENABLED=true`, ogni nodo HTTP Request che tenta di raggiungere un IP privato (RFC 1918) viene bloccato automaticamente. La gerarchia di precedenza è:

```
N8N_SSRF_ALLOWED_HOSTNAMES  →  override esplicito (DNS interni trusted)
      ↓
N8N_SSRF_BLOCKED_IP_RANGES  →  blocco IP privati e metadata endpoints
```

Questo significa che i nodi che chiamano `forgejo.homelab` funzioneranno (whitelisted), mentre un potenziale attacco via payload iniettato che tenta di raggiungere `192.168.1.1` verrà bloccato.

> **Nota importante**: n8n v2.15.0 (la versione attualmente in esecuzione) ha una vulnerabilità SSRF aperta via CVE-2025-62718 legata a axios. Questo è un motivo aggiuntivo per abilitare la protezione SSRF e per includere n8n nel piano di aggiornamento 🟠 MEDIO.

### 3.2 — Sicurezza Webhook (HMAC + Timestamp)

Il WF-2 (Approval Webhook) è l'unico endpoint esposto pubblicamente tramite Cloudflare Tunnel. Deve implementare tre livelli di protezione:

**Livello 1 — Firma HMAC del body:**
```javascript
// Nodo Code nel WF-2, prima di qualsiasi altra logica
const crypto = require('crypto');

const secret = process.env.N8N_WEBHOOK_HMAC_SECRET;
const receivedSig = $input.first().headers['x-signature-256'];
const rawBody = $input.first().body; // Configurare il nodo Webhook su "Raw Body"

const expectedSig = 'sha256=' + crypto
  .createHmac('sha256', secret)
  .update(JSON.stringify(rawBody))
  .digest('hex');

// Confronto a tempo costante — previene timing attacks
const sigBuffer = Buffer.from(receivedSig || '', 'utf8');
const expBuffer = Buffer.from(expectedSig, 'utf8');

if (sigBuffer.length !== expBuffer.length || 
    !crypto.timingSafeEqual(sigBuffer, expBuffer)) {
  throw new Error('HMAC validation failed — request rejected');
}
```

**Livello 2 — Replay Window (5 minuti):**
```javascript
const requestTimestamp = parseInt($input.first().body.timestamp);
const now = Math.floor(Date.now() / 1000);
const WINDOW = 300; // 5 minuti

if (Math.abs(now - requestTimestamp) > WINDOW) {
  throw new Error('Request expired — possible replay attack');
}
```

**Livello 3 — Validazione del payload:**
```javascript
const { service, version, action } = $input.first().body;
const validActions = ['approve', 'skip'];

if (!service || !version || !validActions.includes(action)) {
  throw new Error('Invalid payload structure');
}
```

Il link di approvazione generato nel WF-3 deve includere la firma nel body della richiesta (POST), non come query parameter in chiaro.

### 3.3 — Shell Non-Interattiva SSH

n8n esegue comandi SSH in ambiente **non-interattivo**: `.bashrc` e `.profile` non vengono caricati. Il gruppo `docker` potrebbe non essere riconosciuto. Soluzione: caricare esplicitamente l'ambiente nel comando.

```bash
# Forma corretta per ogni comando SSH dal nodo n8n
source /etc/environment && cd /opt/homelab-infra && make pull
```

Usare sempre `-o BatchMode=yes` nella configurazione SSH di n8n: se l'autenticazione fallisce, il nodo fallisce immediatamente con un errore chiaro invece di bloccarsi in attesa di input.

---

## 4. Inventario Servizi e Classificazione

Basato sull'output reale del `docker compose ps` del Nexus.

### 🔴 CRITICO — Approvazione manuale + Protocollo speciale

| Servizio | Immagine Attuale | Versione | Note Speciali |
|---|---|---|---|
| nextcloud | `nextcloud:apache` | 33.0.2 | Major version: stop completo, analisi changelog obbligatoria |
| immich-server | `immich-app/immich-server` | v2.7.5 | **Accoppiato con immich-ml — aggiornare sempre insieme** |
| immich-machine-learning | `immich-app/immich-machine-learning` | v2.7.5-cuda | **Dipende da driver CUDA host** — verificare compatibilità |
| paperless-ngx | `paperless-ngx/paperless-ngx` | 2.20.13 | Backup db prima dell'update |
| vaultwarden | `vaultwarden/server` | 1.33.2 | **Protocollo backup obbligatorio** (pg_dump + attachments + rsa_key) |
| kopia | `kopia/kopia` | 0.19 | Backup system — aggiornare solo con infrastruttura stabile |
| postgres (nextcloud-db) | `postgres:16-alpine` | 16 | **Major version = mai automatizzare. Richiede pg_upgrade** |
| postgres (paperless-db) | `postgres:16-alpine` | 16 | Idem |
| immich-db | `immich-app/postgres` | 16-vectorchord0.5.3 | Versione custom con pgvector — seguire release Immich |

### 🟠 MEDIO — Report domenicale + Link di approvazione

| Servizio | Immagine Attuale | Versione | Note |
|---|---|---|---|
| n8n | `n8nio/n8n` | 2.15.0 | CVE-2025-62718 aperto — priorità alta nel tier medio |
| n8n-worker | `n8nio/n8n` | 2.15.0 | Aggiornare sempre insieme a n8n |
| ollama-gpu | `ollama/ollama` | 0.21.0 | Verificare compatibilità con modelli scaricati |
| open-webui | `open-webui/open-webui` | v0.8.12 | — |
| headscale | `headscale/headscale` | 0.25 | Aggiornamento tocca VPN — impatto sulla connettività |
| headscale-ui | `gurucomputing/headscale-ui` | 2025.01.20 | Separato da headscale, meno critico |
| nginx-proxy-manager | `jc21/nginx-proxy-manager` | 2.14.0 | Tocca il reverse proxy globale — finestra di manutenzione |
| portainer | `portainer/portainer-ce` | 2.25.1 | — |
| homepage | `gethomepage/homepage` | v0.10.9 | — |
| postgres (n8n-db) | `postgres:18-alpine` | **18** ⚠️ | Versione diversa dagli altri stack — monitorare attentamente |

### 🟡 BASSO — Auto-update notturno + notifica post-deploy

| Servizio | Immagine Attuale | Versione |
|---|---|---|
| grafana | `grafana/grafana` | 11.5.2 |
| loki | `grafana/loki` | 3.4.2 |
| promtail | `grafana/promtail` | 3.4.2 |
| netdata | `netdata/netdata` | v2.3.0 |
| ntfy | `binwiederhier/ntfy` | v2.11.0 |

> Nota: loki e promtail sono nello stesso stack Grafana — aggiornarli nella stessa finestra notturna per mantenere la compatibilità dei protocolli.

### 🟢 STATELESS — Auto-update immediato silente

| Servizio | Immagine Attuale |
|---|---|
| cloudflared | `cloudflare/cloudflared:latest` |
| excalidraw | `excalidraw/excalidraw:latest` |

### ⚙️ INFRASTRUTTURA — Esclusi dall'automazione versioni

| Servizio | Motivo dell'esclusione |
|---|---|
| redis (nextcloud, paperless) | Dipendenza dello stack padre — aggiornare solo con l'app |
| immich-redis (valkey:9) | Idem — gestito dalle release di Immich |
| redis (n8n) | Infra interna n8n — non toccare separatamente |
| garage | In stato `restarting` — da stabilizzare manualmente prima |

---

## 5. Database delle Versioni

Il cuore del sistema è una tabella nel Postgres di n8n. **Non usare un file JSON** — il database permette query atomiche, storico delle modifiche e nessun problema di race condition tra workflow concorrenti.

### Schema SQL

```sql
-- Eseguire nel database n8n tramite nodo Postgres in un workflow di init
CREATE TABLE IF NOT EXISTS service_versions (
  id                SERIAL PRIMARY KEY,
  service_name      VARCHAR(64) UNIQUE NOT NULL,
  criticality       VARCHAR(16) NOT NULL CHECK (criticality IN ('critical','medium','low','stateless')),
  current_version   VARCHAR(64) NOT NULL,
  latest_version    VARCHAR(64),
  rss_url           VARCHAR(256) NOT NULL,
  env_var_name      VARCHAR(64),         -- es. NEXTCLOUD_VERSION nel .env
  linked_services   VARCHAR(256),        -- es. 'immich-ml' per immich-server
  special_protocol  VARCHAR(32),         -- es. 'vaultwarden', 'immich-cuda', 'postgres-major'
  status            VARCHAR(16) DEFAULT 'current'
                    CHECK (status IN ('current','pending','approved','committed','deployed','blocked')),
  is_major_bump     BOOLEAN DEFAULT FALSE,
  detected_at       TIMESTAMPTZ,
  approved_at       TIMESTAMPTZ,
  committed_at      TIMESTAMPTZ,
  deployed_at       TIMESTAMPTZ,
  notes             TEXT
);
```

### Popolamento Iniziale (stato reale Nexus)

```sql
INSERT INTO service_versions (service_name, criticality, current_version, rss_url, env_var_name, special_protocol) VALUES
('nextcloud',            'critical',  '33.0.2',                'https://github.com/nextcloud/server/releases.atom',            'NEXTCLOUD_VERSION',  NULL),
('immich',               'critical',  'v2.7.5',                'https://github.com/immich-app/immich/releases.atom',           'IMMICH_VERSION',     'immich-cuda'),
('paperless-ngx',        'critical',  '2.20.13',               'https://github.com/paperless-ngx/paperless-ngx/releases.atom', 'PAPERLESS_VERSION',  NULL),
('vaultwarden',          'critical',  '1.33.2',                'https://github.com/dani-garcia/vaultwarden/releases.atom',     'VAULTWARDEN_VERSION','vaultwarden'),
('kopia',                'critical',  '0.19',                  'https://github.com/kopia/kopia/releases.atom',                 'KOPIA_VERSION',      NULL),
('n8n',                  'medium',    '2.15.0',                'https://github.com/n8n-io/n8n/releases.atom',                  'N8N_VERSION',        NULL),
('ollama',               'medium',    '0.21.0',                'https://github.com/ollama/ollama/releases.atom',               'OLLAMA_VERSION',     NULL),
('open-webui',           'medium',    'v0.8.12',               'https://github.com/open-webui/open-webui/releases.atom',       'OPEN_WEBUI_VERSION', NULL),
('headscale',            'medium',    '0.25',                  'https://github.com/juanfont/headscale/releases.atom',          'HEADSCALE_VERSION',  NULL),
('nginx-proxy-manager',  'medium',    '2.14.0',                'https://github.com/NginxProxyManager/nginx-proxy-manager/releases.atom', 'NPM_VERSION', NULL),
('portainer',            'medium',    '2.25.1',                'https://github.com/portainer/portainer/releases.atom',         'PORTAINER_VERSION',  NULL),
('grafana',              'low',       '11.5.2',                'https://github.com/grafana/grafana/releases.atom',             'GRAFANA_VERSION',    NULL),
('loki',                 'low',       '3.4.2',                 'https://github.com/grafana/loki/releases.atom',                'LOKI_VERSION',       NULL),
('netdata',              'low',       'v2.3.0',                'https://github.com/netdata/netdata/releases.atom',             'NETDATA_VERSION',    NULL),
('ntfy',                 'low',       'v2.11.0',               'https://github.com/binwiederhier/ntfy/releases.atom',          'NTFY_VERSION',       NULL),
('cloudflared',          'stateless', 'latest',                'https://github.com/cloudflare/cloudflared/releases.atom',      NULL,                 NULL);
```

---

## 6. I 5 Workflow n8n — Specifica Completa

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        POSTGRES n8n-db                                  │
│                    Tabella: service_versions                             │
└────┬────────────────┬───────────────────┬──────────────────────────────┘
     │                │                   │
     ▼                ▼                   ▼
[WF-1]           [WF-3]             [WF-2]
RSS Poller       Weekly Digest      Approval Webhook
ogni 6h          dom 08:00          on-demand (link ntfy)
     │                │                   │
     │                │                   ▼
     │                └──────────────► [WF-4]
     │   (stateless)                  Git + .env Update
     └──────────────────────────────► (SSH → host)
                                          │
                                          ▼
                                      [WF-5]
                                      Nightly Deploy
                                      ogni notte 03:00
                                      (SSH → make pull/up/health)
```

---

### WF-1 — RSS Version Poller

**Trigger:** Cron `0 */6 * * *` (ogni 6 ore: 00:00, 06:00, 12:00, 18:00)  
**Carico CPU:** Minimo  
**Dipendenze:** Credenziale `GitHub RSS Token`, connessione Postgres n8n-db

#### Flusso Dettagliato

```
[Cron Trigger]
     ↓
[Postgres: Query]
  SELECT * FROM service_versions ORDER BY criticality
     ↓
[SplitInBatches: 1 item alla volta]
     ↓
[Wait: 1.5 secondi]  ← throttling GitHub — evita secondary rate limit
     ↓
[HTTP Request: GET {rss_url}]
  Headers: Authorization: token {GitHub PAT}
  Timeout: 10 secondi
     ↓
[IF: status 429?]
  SÌ → [Code: leggi X-RateLimit-Reset header]
        [Wait: (reset_timestamp - now + 60) secondi]
        [Retry HTTP Request]
  NO  → continua
     ↓
[Code: ParseRSS + ExtractVersion]
  ← vedi Sezione 7 per la logica semver completa
     ↓
[IF: latest == current?]
  SÌ → [skip — nessuna azione]
  NO  → continua
     ↓
[IF: già in status 'pending' o 'approved' nel db?]
  SÌ → [skip — già notificato, non duplicare]
  NO  → continua
     ↓
[Code: ClassificaAggiornamento]
  - Estrai Major/Minor/Patch da current e latest
  - Se Major diverso → is_major_bump = TRUE
  - Se special_protocol = 'postgres-major' e is_major_bump → status = 'blocked'
  - Se criticality = 'stateless' → status = 'auto-approved'
     ↓
[Postgres: UPDATE]
  SET latest_version = X, status = Y, detected_at = NOW(), is_major_bump = Z
     ↓
[IF: criticality = 'stateless']
  → [Trigger WF-4 direttamente]
[IF: is_major_bump = TRUE e criticality = 'critical']
  → [ntfy: notifica URGENTE immediata]
     "⛔ Major version rilevata: {service} {current} → {latest}
      Richiede intervento manuale. Non sarà aggiornato automaticamente."
[ELSE]
  → [nessuna notifica — WF-3 domenicale si occuperà del digest]
```

---

### WF-2 — Approval Webhook

**Trigger:** HTTP POST su `/webhook/approve`  
**Esposto:** Sì, tramite Cloudflare Tunnel a `https://n8n.tuodominio.com/webhook/approve`  
**Sicurezza:** HMAC-SHA256 + Timestamp replay window (vedi Sezione 3.2)

#### Flusso Dettagliato

```
[Webhook Trigger: POST /webhook/approve]
  Body atteso: { service, version, action, timestamp, signature }
     ↓
[Code: Validazione HMAC + Timestamp]
  ← 3 livelli di controllo (vedi Sezione 3.2)
  Se fallisce → HTTP 401 + log su Loki
     ↓
[Postgres: Query]
  SELECT * FROM service_versions
  WHERE service_name = {service} AND latest_version = {version}
     ↓
[IF: record trovato?]
  NO → HTTP 404 "Service/version not found"
     ↓
[IF: is_major_bump = TRUE e criticality = 'critical']
  → HTTP 409 "Major version — manual intervention required on server"
  → ntfy: "⚠️ Tentativo approvazione bloccato: {service} è un major bump"
     ↓
[IF: action = 'skip']
  → UPDATE status = 'current', latest_version = current_version
  → HTTP 200 "Version skipped"
     ↓
[IF: action = 'approve']
  → UPDATE status = 'approved', approved_at = NOW()
  → Trigger WF-4
  → HTTP 200 con pagina HTML di conferma (NO redirect esterni)
  → ntfy: "✅ Approvato: {service} → {version}. Deploy stanotte alle 03:00"
```

---

### WF-3 — Weekly Digest

**Trigger:** Cron `0 8 * * 0` (domenica ore 08:00)  
**Output:** Messaggio ntfy strutturato

#### Flusso Dettagliato

```
[Cron Trigger: domenica 08:00]
     ↓
[Postgres: Query]
  SELECT * FROM service_versions
  WHERE status IN ('pending', 'approved', 'committed', 'blocked')
  ORDER BY criticality, service_name
     ↓
[IF: nessun record trovato]
  → ntfy: "✅ Nexus è aggiornato — nessun pending questa settimana"
  → STOP
     ↓
[Code: Costruisci Payload ntfy]
  Raggruppa per status e criticality:
  
  Sezione 1: ⛔ BLOCCATI (major version, intervento manuale)
  Sezione 2: 🔴 CRITICI — In attesa della tua approvazione
  Sezione 3: 🟠 MEDI — In attesa della tua approvazione
  Sezione 4: 🟡 BASSI — Saranno aggiornati automaticamente stanotte
  Sezione 5: ✅ Già approvati — in coda per stanotte
     ↓
[ntfy: Invia messaggio con Actions]
  Topic: homelab-updates
  Priority: default (non urgente — è un digest settimanale)
  Actions: link per ogni servizio pending che richiedono approvazione
  Formato azioni:
    "Approva immich v2.8.0" → POST https://n8n.../webhook/approve
    "Approva vaultwarden 1.34.0" → POST https://n8n.../webhook/approve
```

#### Formato Messaggio ntfy (esempio)

```
📋 Nexus Weekly Update — Dom 18 Mag

⛔ BLOCCATI (richiede intervento manuale):
• postgres (n8n-db): 18-alpine → 19-alpine [MAJOR]

🔴 DA APPROVARE (Critici):
• vaultwarden: 1.33.2 → 1.34.0 [minor]
• immich: v2.7.5 → v2.8.0 [minor]

🟠 DA APPROVARE (Medi):
• n8n: 2.15.0 → 2.16.0 [minor]
• open-webui: v0.8.12 → v0.9.0 [minor]

🟡 AUTO (stanotte 03:00):
• grafana: 11.5.2 → 11.6.0
• ntfy: v2.11.0 → v2.12.0

[Approva tutto il tier Critico] ← Action button
[Approva tutto il tier Medio]   ← Action button
[Apri n8n per dettagli]         ← Link
```

---

### WF-4 — Git + .env Updater

**Trigger:** Da WF-1 (stateless) o WF-2 (approved)  
**Dipendenze:** Credenziale SSH `n8n-runner`, Forgejo attivo

#### Flusso Dettagliato

```
[Trigger (da WF-1 o WF-2)]
  Input: { service_name, new_version, env_var_name, special_protocol, linked_services }
     ↓
[IF: special_protocol = 'vaultwarden']
  → Esegui Protocollo Vaultwarden (vedi Sezione 10.1) prima di continuare
     ↓
[IF: special_protocol = 'immich-cuda']
  → Calcola tag CUDA corretto: {new_version}-cuda
  → Includi immich-server E immich-ml nell'aggiornamento
     ↓
[SSH: source /etc/environment && cd /opt/homelab-infra]
[SSH: Comando sed per aggiornare .env]
  source /etc/environment && \
  cd /opt/homelab-infra && \
  sed -i "s/^{env_var_name}=.*/{env_var_name}={new_version}/" .env
     ↓
[SSH: make check]
  source /etc/environment && cd /opt/homelab-infra && make check
     ↓
[IF: make check fallisce]
  → SSH: git checkout .env  (rollback)
  → Postgres: UPDATE status = 'pending'  (torna allo stato precedente)
  → ntfy URGENTE: "🚨 Rollback: make check fallito per {service}. .env ripristinato."
  → STOP
     ↓
[SSH: git operations]
  source /etc/environment && \
  cd /opt/homelab-infra && \
  git add .env && \
  git commit -m "chore(deps): update {service} to {new_version} [n8n-auto]" && \
  git push origin main
     ↓
[IF: git push fallisce]
  → ntfy: "⚠️ Commit fallito per {service} — verificare Forgejo"
  → Postgres: UPDATE status = 'pending'
  → STOP
     ↓
[Postgres: UPDATE status = 'committed', committed_at = NOW()]
     ↓
[IF: criticality = 'stateless']
  → ntfy silente: nessuna notifica
[ELSE]
  → ntfy: "📝 Committed: {service} {new_version} — deploy stanotte alle 03:00"
```

---

### WF-5 — Nightly Deploy

**Trigger:** Cron `0 3 * * *` (ogni notte alle 03:00)  
**Durata attesa:** 5-8 minuti (COMPOSE_PARALLEL_LIMIT=1 con 30+ container)  
**Dipendenze:** Credenziale SSH `n8n-runner`, tutti i container stabili

#### Flusso Dettagliato

```
[Cron Trigger: 03:00]
     ↓
[SSH: Verifica commit pendenti]
  source /etc/environment && \
  cd /opt/homelab-infra && \
  git log --oneline --since="yesterday" --grep="\[n8n-auto\]" | wc -l
     ↓
[IF: output = 0]
  → STOP silente — nessun aggiornamento, nessuna notifica
     ↓
[Postgres: Query]
  SELECT service_name, latest_version FROM service_versions
  WHERE status = 'committed'
  → Salva lista per il report finale
     ↓
[SSH: make pull]
  source /etc/environment && cd /opt/homelab-infra && make pull
  (Timeout: 15 minuti — le immagini grandi come Immich ML possono impiegare tempo)
     ↓
[IF: make pull fallisce]
  → ntfy URGENTE: "🚨 make pull fallito — nessun container aggiornato"
  → STOP
     ↓
[SSH: make up]
  source /etc/environment && cd /opt/homelab-infra && make up
  (Timeout: 10 minuti — COMPOSE_PARALLEL_LIMIT=1 = ~5 min per 30+ container)
     ↓
[Wait Loop: Polling Health Status]
  Ogni 30 secondi, per massimo 10 tentativi (5 minuti):
  
  SSH: docker compose ps --format json | \
       jq '[.[] | select(.State == "restarting" or .Health == "unhealthy")] | length'
  
  IF output = 0 → tutti healthy, procedi
  IF tentativi esauriti → passa a gestione errore
     ↓
[SSH: make health]
  source /etc/environment && cd /opt/homelab-infra && make health
     ↓
[Postgres: UPDATE]
  SET status = 'deployed', deployed_at = NOW()
  WHERE status = 'committed'
     ↓
[IF: make health ha trovato container unhealthy]
  → ntfy URGENTE priority:urgent:
    "🚨 DEPLOY PARZIALE — Container unhealthy: {lista}
     NON tentare rollback automatico.
     Accedi al server per diagnosticare."
  → STOP (non modificare status a 'deployed' per i servizi unhealthy)
[ELSE (tutto healthy)]
  → ntfy:
    "✅ Deploy completato — {data ora}
     Aggiornati: {lista servizi con versione}
     Tutti i container sono healthy."
```

> **Perché non rollback automatico**: il rollback di un database (Postgres, Vaultwarden) non è mai sicuro senza un processo di migrazione controllato. Un container `unhealthy` dopo l'aggiornamento richiede diagnosi umana. Il sistema notifica con priorità massima e si ferma.

---

## 7. Logica Semver e Parsing Versioni

Da implementare nel **nodo Code** di WF-1, dopo il fetch RSS.

```javascript
// Funzione principale — incolla nel nodo Code di WF-1
function parseAndCompareVersions(current, latest) {
  
  // Normalizzazione: rimuovi prefisso 'v', gestisci suffissi come -cuda, -apache, -alpine
  function normalize(v) {
    return v
      .replace(/^v/i, '')           // rimuovi 'v' iniziale
      .replace(/-cuda.*$/i, '')      // rimuovi -cuda e varianti
      .replace(/-apache.*$/i, '')    // rimuovi -apache
      .replace(/-alpine.*$/i, '');   // rimuovi -alpine
  }
  
  // Filtra versioni pre-release: alpha, beta, rc, dev, nightly
  function isPreRelease(v) {
    return /alpha|beta|rc\d*|dev|nightly|preview/i.test(v);
  }
  
  const normalCurrent = normalize(current);
  const normalLatest = normalize(latest);
  
  // Estrai componenti numerici
  function extractParts(v) {
    const parts = v.split('.').map(p => parseInt(p, 10) || 0);
    return {
      major: parts[0] || 0,
      minor: parts[1] || 0,
      patch: parts[2] || 0
    };
  }
  
  const c = extractParts(normalCurrent);
  const l = extractParts(normalLatest);
  
  // Confronto
  let bumpType = 'none';
  let isMajorBump = false;
  
  if (l.major > c.major) {
    bumpType = 'major';
    isMajorBump = true;
  } else if (l.major === c.major && l.minor > c.minor) {
    bumpType = 'minor';
  } else if (l.major === c.major && l.minor === c.minor && l.patch > c.patch) {
    bumpType = 'patch';
  } else if (l.major < c.major || (l.major === c.major && l.minor < c.minor)) {
    bumpType = 'downgrade'; // Non dovrebbe succedere — segnalare
  }
  
  return { bumpType, isMajorBump, normalCurrent, normalLatest, isPreRelease: isPreRelease(latest) };
}

// Parsing RSS Atom per estrarre l'ultimo tag di release
function extractLatestVersion(rssXml) {
  // Trova il primo <entry> (release più recente)
  const entryMatch = rssXml.match(/<entry>([\s\S]*?)<\/entry>/);
  if (!entryMatch) return null;
  
  // Estrai il tag dal link o dal title
  const titleMatch = entryMatch[1].match(/<title[^>]*>([^<]+)<\/title>/);
  if (!titleMatch) return null;
  
  // GitHub format: "Release v2.8.0" o direttamente "v2.8.0"
  const version = titleMatch[1].trim().replace(/^Release\s+/i, '');
  return version;
}

// Uso nel nodo Code
const service = $input.first().json;
const rssContent = $input.first().json.rssBody; // da HTTP Request precedente

const latestVersion = extractLatestVersion(rssContent);
if (!latestVersion) return [{ json: { skip: true, reason: 'parse_failed' } }];

const result = parseAndCompareVersions(service.current_version, latestVersion);

// Blocca le pre-release
if (result.isPreRelease) return [{ json: { skip: true, reason: 'pre_release' } }];

// Nessun aggiornamento
if (result.bumpType === 'none') return [{ json: { skip: true, reason: 'up_to_date' } }];

return [{ json: {
  ...service,
  latest_version: latestVersion,
  bump_type: result.bumpType,
  is_major_bump: result.isMajorBump,
  should_process: true
}}];
```

### Casi Speciali

| Pattern Versione | Comportamento |
|---|---|
| `v2.7.5-cuda` | Suffix rimosso per confronto, riaggiunto nel sed del .env |
| `v33.0.2-apache` | Suffix rimosso per confronto |
| `16-alpine` | Il "16" è il Major — un update a `17-alpine` è un major bump |
| `2025.01.20` (headscale-ui) | Usa confronto date invece di semver |
| `1.0-rc1` | Filtrato come pre-release — ignorato |

---

## 8. Gestione Rate Limiting GitHub

### Budget Richieste

Con 16 servizi monitorati e polling ogni 6 ore:
- **16 richieste × 4 volte/giorno = 64 richieste/giorno**
- Senza PAT: limite 60/ora → **budget abbondante** ma esposto al rate limit condiviso dell'IP
- Con PAT: limite 5.000/ora → **margine enorme**, praticamente impossibile superarlo

**Usare sempre il PAT.** È l'unica variabile che garantisce l'isolamento del budget dell'homelab da altri servizi sulla stessa rete.

### Throttling Obbligatorio

Il WF-1 deve inserire un **nodo Wait di 1.5 secondi** tra ogni richiesta HTTP. Anche con PAT, GitHub applica secondary rate limit su picchi di richieste ravvicinate.

### Gestione 429

```javascript
// Nodo Code dopo ogni HTTP Request in WF-1
const response = $input.first();

if (response.statusCode === 429) {
  const resetHeader = response.headers['x-ratelimit-reset'];
  const resetTime = parseInt(resetHeader) * 1000; // converti a ms
  const now = Date.now();
  const waitMs = Math.max(resetTime - now + 60000, 60000); // minimo 1 minuto
  
  // Informa il workflow di aspettare
  return [{ json: { 
    rateLimited: true, 
    waitSeconds: Math.ceil(waitMs / 1000),
    remaining: response.headers['x-ratelimit-remaining']
  }}];
}
```

Connettere l'output "rateLimited = true" a un nodo **Wait** dinamico che usa il valore `waitSeconds`, poi ritorna al nodo HTTP Request tramite un nodo **Loop**.

---

## 9. Deployment Timing e Health Check

### Tempi Attesi con COMPOSE_PARALLEL_LIMIT=1

| Operazione | Stima Tempo | Note |
|---|---|---|
| `make pull` | 2-15 minuti | Dipende dalla dimensione delle immagini e dalla velocità della connessione |
| `make up` | 3-5 minuti | ~5-10 secondi per container × 30+ container sequenziali |
| Stabilizzazione container | 1-3 minuti | Database pesanti (Postgres, Immich DB) hanno periodi di recovery |
| `make health` | < 10 secondi | Solo lettura stato |
| **Totale WF-5** | **~10-20 minuti** | Alle 03:00 il server è libero — nessun problema |

### Strategia di Polling (invece di sleep fisso)

Non usare `Wait: 300 secondi` con valore fisso. Usare un loop di polling:

```javascript
// Nodo Code per parsing output health check
const healthOutput = $input.first().json.stdout;

// make health restituisce i container non-healthy
// Se l'output contiene solo "✅ Tutti i container sono healthy" → OK
const allHealthy = healthOutput.includes('✅ Tutti i container sono healthy');
const unhealthyList = healthOutput
  .split('\n')
  .filter(line => line.includes('unhealthy') || line.includes('restarting'))
  .map(line => line.split('\t')[0].trim());

return [{ json: { 
  allHealthy, 
  unhealthyList,
  checkAgain: !allHealthy && unhealthyList.length === 0 // container ancora in 'starting'
}}];
```

### `start_period` nei Compose File

Per i database pesanti, assicurarsi che i file compose degli stack abbiano `start_period` configurato:

```yaml
# Esempio per postgres in qualsiasi stack
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 60s  # ← fondamentale: non contare i fallimenti nei primi 60s
```

Questo evita che `make health` segnali un container come `unhealthy` solo perché Postgres sta ancora inizializzando il cluster.

---

## 10. Protocolli Speciali di Aggiornamento

### 10.1 — Protocollo Vaultwarden

**Da eseguire PRIMA del sed su .env**, all'interno di WF-4:

```bash
# Step 1: Backup database Postgres
docker exec homelab-infra-vaultwarden-db-1 \
  pg_dump -U ${VAULTWARDEN_DB_USER} ${VAULTWARDEN_DB_NAME} \
  > /opt/homelab-infra/backups/vaultwarden-$(date +%Y%m%d-%H%M).sql

# Step 2: Backup file essenziali (attachments + chiavi RSA)
# Questi file NON sono nel database — sono nel volume Docker
docker run --rm \
  -v vaultwarden_data:/source:ro \
  -v /opt/homelab-infra/backups:/backup \
  alpine tar czf /backup/vaultwarden-files-$(date +%Y%m%d-%H%M).tar.gz \
  -C /source attachments rsa_key.pem rsa_key.pub.pem

# Step 3: Copia backup su Garage S3 (quando stabile) o su path Kopia
```

**Dopo l'update** (WF-4, al termine):
```bash
# Verifica che Vaultwarden risponda con HTTP 200
curl -sf https://vault.tuodominio.com/api/config | jq '.version'
# Se fallisce → notifica urgente su ntfy
```

### 10.2 — Protocollo Immich (CUDA + Accoppiamento)

Immich richiede che `immich-server` e `immich-machine-learning` siano **sempre alla stessa versione**. Il WF-4 deve gestirli come un'unità atomica.

```javascript
// Nel nodo Code del WF-4, quando service = 'immich'
const newVersion = item.latest_version; // es. "v2.8.0"
const cudaVersion = newVersion + '-cuda'; // "v2.8.0-cuda"

// Due variabili .env da aggiornare nella stessa operazione sed
const sedCommands = [
  `sed -i "s/^IMMICH_VERSION=.*/IMMICH_VERSION=${newVersion}/" .env`,
  `sed -i "s/^IMMICH_ML_VERSION=.*/IMMICH_ML_VERSION=${cudaVersion}/" .env`
].join(' && ');
```

**Verifica compatibilità CUDA**: prima dell'aggiornamento, WF-4 deve controllare le release notes di Immich per verificare se la nuova versione richiede una versione CUDA diversa da quella installata sull'host. Questo controllo è manuale per ora — aggiungere nel messaggio di approvazione del WF-3 un link diretto alle release notes della versione.

### 10.3 — Postgres Major Version (BLOCCATO)

Per Postgres, qualsiasi bump Major (es. 16 → 17, 18 → 19) viene automaticamente impostato a `status = 'blocked'` dal WF-1.

Il messaggio ntfy include istruzioni operative:
```
⛔ BLOCCO MANUALE: postgres (n8n-db)
18-alpine → 19-alpine [MAJOR VERSION]

Procedura richiesta:
1. Backup: pg_dump di tutti i database
2. Stop stack automation
3. Aggiorna immagine nel .env
4. Esegui pg_upgrade o restore da dump
5. Verifica integrità dati
6. Riabilita stack

NON verrà mai eseguito automaticamente.
```

---

## 11. Configurazione Ambiente n8n

### Stack `automation/compose.yml` — Variabili n8n da Aggiungere

```yaml
environment:
  # Sicurezza
  - N8N_SSRF_PROTECTION_ENABLED=true
  - N8N_SSRF_BLOCKED_IP_RANGES=default,169.254.169.254/32
  - N8N_SSRF_ALLOWED_HOSTNAMES=forgejo.homelab,npm.homelab,ntfy.homelab
  - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
  
  # Webhook
  - N8N_WEBHOOK_HMAC_SECRET=${N8N_WEBHOOK_HMAC_SECRET}
  
  # Performance (già configurato — verificare)
  - EXECUTIONS_DATA_PRUNE=true
  - EXECUTIONS_DATA_MAX_AGE=168  # 7 giorni di log esecuzioni
  
  # SSH: assicurarsi che il volume chiave sia montato
volumes:
  - /home/n8n-runner/.ssh/id_ed25519:/home/node/.ssh/id_ed25519:ro
  - n8n_known_hosts:/home/node/.ssh/known_hosts  # persistente tra restart
```

### Credenziali da Configurare in n8n UI

| Nome Credenziale | Tipo | Contenuto |
|---|---|---|
| `GitHub RSS Token` | HTTP Header Auth | `Authorization: token ghp_...` |
| `n8n-runner SSH` | SSH | Chiave Ed25519 privata, host: 172.20.0.1, user: n8n-runner |
| `n8n Postgres` | Postgres | Connessione al db interno n8n-db |
| `ntfy Homelab` | HTTP Header Auth | Topic e token ntfy se configurato con auth |

---

## 12. Strategia Notifiche ntfy

### Mappa Priorità e Topic

| Evento | Topic | Priorità ntfy | Notifica |
|---|---|---|---|
| Deploy completato con successo | `homelab-deploy` | default (3) | Sì |
| Nuova versione rilevata (low) | — | — | No (solo digest) |
| Nuova versione rilevata (medium/critical) | — | — | No (solo digest) |
| Major version rilevata su critico | `homelab-alerts` | urgent (5) | Sì — immediata |
| Digest domenicale | `homelab-updates` | default (3) | Sì |
| make check fallito / rollback | `homelab-alerts` | high (4) | Sì — immediata |
| Container unhealthy post-deploy | `homelab-alerts` | urgent (5) | Sì — immediata |
| Approvazione ricevuta | `homelab-deploy` | low (2) | Sì |
| Rate limit GitHub raggiunto | `homelab-alerts` | default (3) | Sì (max 1/giorno) |

### Regole Anti-Notification Fatigue

1. **Un solo digest settimanale** per aggiornamenti pending non urgenti — mai più di uno a settimana
2. **Nessuna notifica per deploy senza aggiornamenti** — se WF-5 non trova commit, silenzio totale
3. **Deduplicazione nel db** — una versione pending notificata non viene rinotificata fino al domenicale
4. **Rate limit sulle notifiche di errore** — massimo 1 notifica per tipo di errore ogni 24 ore (evita spam se un container resta unhealthy per ore)
5. **ntfy Actions** per l'approvazione — click diretto dal telefono, zero attrito

---

## 13. Roadmap di Implementazione

### Fase 0 — Stabilizzazione (Prima di tutto il resto)

- [ ] Diagnosticare e risolvere `garage` in stato `restarting`
- [ ] Verificare e avviare lo stack `git/` (Forgejo)
- [ ] Fare `git push` del repository su Forgejo (se non già fatto)
- [ ] Aggiornare la tabella versioni nel README — è obsoleta (Nextcloud mostra 30.0.6 ma gira 33.0.2)

**Stima tempo: 1-2 ore**

---

### Fase 1 — Security Foundation (Non negoziabile)

- [ ] Creare utente `n8n-runner` con script della Sezione 2.2
- [ ] Aggiungere variabili `N8N_SSRF_*` e `N8N_ENCRYPTION_KEY` al `.env`
- [ ] Generare `N8N_WEBHOOK_HMAC_SECRET` e salvarlo in Vaultwarden
- [ ] Configurare `known_hosts` nel container n8n
- [ ] Creare token GitHub PAT (scope: public_repo read-only)
- [ ] Aggiungere tutte le credenziali in n8n UI
- [ ] Riavviare lo stack automation per caricare le nuove variabili: `docker compose up -d n8n n8n-worker`

**Stima tempo: 1-2 ore**

---

### Fase 2 — Database e WF-1 (Fondamenta dei dati)

- [ ] Creare tabella `service_versions` nel Postgres n8n-db
- [ ] Popolare con i valori iniziali dalla Sezione 5
- [ ] Costruire WF-1 (RSS Poller) — **solo scrittura db, nessuna notifica ancora**
- [ ] Attivare WF-1 e lasciarlo girare per 24 ore
- [ ] Verificare che non ci siano falsi positivi o errori di parsing
- [ ] Aggiustare il parser per eventuali formati di versione non previsti

**Stima tempo: 3-4 ore + 24h di osservazione**

---

### Fase 3 — Notifiche e Approvazioni

- [ ] Costruire WF-3 (Weekly Digest) — prima senza action buttons, solo testo
- [ ] Test manuale: triggera WF-3 e verifica il messaggio ntfy
- [ ] Aggiungere la logica HMAC (Sezione 3.2) al WF-2
- [ ] Costruire WF-2 (Approval Webhook) con tutti e 3 i livelli di sicurezza
- [ ] Test end-to-end: WF-3 genera link → click → WF-2 approva → db aggiornato
- [ ] Aggiungere ntfy Actions al WF-3 per i link di approvazione

**Stima tempo: 4-6 ore**

---

### Fase 4 — Git Automation (Il cuore della tracciabilità)

- [ ] Costruire WF-4 base (senza protocolli speciali) su un servizio BASSO come test (es. `grafana`)
- [ ] Test: simulare un'approvazione per grafana → verificare commit su Forgejo
- [ ] Verificare che `make check` funzioni come gate (testare con una .env corrotta)
- [ ] Aggiungere protocollo Vaultwarden (Sezione 10.1)
- [ ] Aggiungere protocollo Immich CUDA (Sezione 10.2)
- [ ] Estendere WF-4 a tutti i tier

**Stima tempo: 4-6 ore**

---

### Fase 5 — Nightly Deploy

- [ ] Costruire WF-5 con polling loop (non sleep fisso)
- [ ] Primo test in orario diurno su un aggiornamento BASSO
- [ ] Monitorare tempi reali di `make pull` e `make up` sul Nexus
- [ ] Calibrare i timeout in base ai tempi osservati
- [ ] Attivare il cron delle 03:00
- [ ] Monitor per 2 settimane su tier BASSO prima di espandere ai tier MEDIO e CRITICO

**Stima tempo: 3-4 ore + 2 settimane di osservazione**

---

### Fase 6 — Raffinamento (Ongoing)

- [ ] Aggiungere widget su Homepage con stato aggiornamenti (via API n8n)
- [ ] Configurare backup della tabella `service_versions` in Kopia
- [ ] Aggiungere `start_period` ai compose file dei database (Sezione 9)
- [ ] Automatizzare la notifica per il check compatibilità CUDA di Immich
- [ ] Valutare integrazione con Netdata per alert di risorse durante il deploy

---

## Appendice — Comandi di Riferimento Rapido

```bash
# Verificare le versioni correnti nel db
docker exec homelab-infra-n8n-db-1 \
  psql -U n8n -c "SELECT service_name, current_version, latest_version, status FROM service_versions ORDER BY criticality;"

# Forzare un run manuale di WF-1 (da n8n UI: Execute Workflow)

# Verificare la connessione SSH n8n-runner
ssh -o BatchMode=yes -i /home/n8n-runner/.ssh/id_ed25519 \
  n8n-runner@localhost "cd /opt/homelab-infra && make check"

# Controllare i container non-healthy manualmente
docker compose ps --format json | jq -r \
  '.[] | select(.Health == "unhealthy" or .State == "restarting") | .Name'

# Vedere le ultime esecuzioni dei workflow n8n
# → n8n UI → Executions → filtra per workflow
```
