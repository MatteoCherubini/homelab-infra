# Piano di Lavoro — n8n Come Cervello Operativo del Nexus

> Versione 1.0 — Maggio 2026  
> Basato su: stato reale dei container, Makefile, README e docker-compose.yml

---

## Analisi di Fattibilità

### Verdict: ✅ Alta Fattibilità — con 3 caveat critici

L'infrastruttura è già pronta nella misura del **~80%**:

| Componente | Stato | Note |
|---|---|---|
| n8n engine | ✅ Running v2.15.0 | Worker + Redis + Postgres già up |
| ntfy | ✅ Running v2.11.0 | Canale notifiche pronto |
| Makefile | ✅ Completo | `pull`, `up`, `health`, `check` disponibili |
| Forgejo (Git) | ⚠️ Non trovato nel `ps` | Serve verifica — stack git potrebbe essere down |
| Garage S3 | 🔴 Stato `restarting` | Da risolvere prima — non blocca il piano ma segnale di instabilità |
| SSH host access | ❓ Da configurare | n8n deve poter eseguire comandi sull'host |

### Caveat Critici

**1. Forgejo non è visibile nel `docker compose ps`**  
Il piano dipende da Git per la tracciabilità. Se lo stack `git/` è disabilitato o non funzionante, la parte di audit trail non può partire. Da verificare come prima cosa.

**2. `make up` usa `COMPOSE_PARALLEL_LIMIT=1`**  
Il Makefile avvia i container **in sequenza**, non in parallelo. Questo è intenzionale (evita spike di RAM/CPU al boot) ma significa che un `make up` completo può richiedere diversi minuti. n8n deve aspettare il completamento prima di lanciare `make health`.

**3. Accesso Host da n8n**  
n8n gira in container. Per eseguire comandi sul host (make, git, sed) ci sono due approcci — scegliere prima dell'implementazione (vedi Sezione 4).

---

## Inventario Servizi e Classificazione Rischio

Basato sull'output reale del `docker compose ps`:

### 🔴 CRITICO — Approvazione manuale obbligatoria

| Servizio | Immagine | Versione Attuale |
|---|---|---|
| nextcloud | `nextcloud:apache` | 33.0.2 |
| immich-server | `immich-app/immich-server` | v2.7.5 |
| immich-machine-learning | `immich-app/immich-machine-learning` | v2.7.5-cuda |
| paperless | `paperless-ngx/paperless-ngx` | 2.20.13 |
| vaultwarden | `vaultwarden/server` | 1.33.2 |
| kopia | `kopia/kopia` | 0.19 |
| postgres (nextcloud-db) | `postgres:16-alpine` | 16 |
| postgres (paperless-db) | `postgres:16-alpine` | 16 |
| postgres (n8n-db) | `postgres:18-alpine` | 18 ⚠️ |
| immich-db | `immich-app/postgres` | 16-vectorchord |

> ⚠️ **Nota:** n8n-db usa Postgres 18-alpine, mentre gli altri stack usano 16. Inconsistenza da tenere monitorata.

### 🟠 MEDIO — Report settimanale + link di approvazione

| Servizio | Immagine | Versione Attuale |
|---|---|---|
| n8n | `n8nio/n8n` | 2.15.0 |
| ollama-gpu | `ollama/ollama` | 0.21.0 |
| open-webui | `open-webui/open-webui` | v0.8.12 |
| headscale | `headscale/headscale` | 0.25 |
| headscale-ui | `gurucomputing/headscale-ui` | 2025.01.20 |
| nginx-proxy-manager | `jc21/nginx-proxy-manager` | 2.14.0 |
| portainer | `portainer/portainer-ce` | 2.25.1 |
| homepage | `gethomepage/homepage` | v0.10.9 |

### 🟡 BASSO — Auto-update notturno con notifica post-commit

| Servizio | Immagine | Versione Attuale |
|---|---|---|
| grafana | `grafana/grafana` | 11.5.2 |
| loki | `grafana/loki` | 3.4.2 |
| promtail | `grafana/promtail` | 3.4.2 |
| netdata | `netdata/netdata` | v2.3.0 |
| ntfy | `binwiederhier/ntfy` | v2.11.0 |

### 🟢 STATELESS — Auto-update immediato silente

| Servizio | Immagine | Versione Attuale |
|---|---|---|
| cloudflared | `cloudflare/cloudflared` | latest |
| excalidraw | `excalidraw/excalidraw` | latest |

### ⚙️ INFRASTRUTTURA — Esclusi dall'automazione versioni

| Servizio | Motivo |
|---|---|
| redis (tutti) | Dipendenze infra, aggiornamento legato allo stack padre |
| immich-redis (valkey) | Idem |
| garage | Attualmente `restarting` — da stabilizzare prima |

---

## Architettura dei Workflow n8n

Il sistema si divide in **5 workflow indipendenti**, collegati da una tabella condivisa nel Postgres di n8n.

```
┌─────────────────────────────────────────────────────────────────┐
│                     POSTGRES n8n-db                             │
│  Tabella: service_versions                                      │
│  (service, current_version, latest_version, criticality,        │
│   status, detected_at, approved_at, deployed_at)               │
└────────────────┬────────────────────────────────────────────────┘
                 │
    ┌────────────┴────────────┐
    │                         │
    ▼                         ▼
[WF-1: RSS Poller]    [WF-2: Approval Webhook]
  ogni 6 ore            on-demand (link da mail)
    │                         │
    ▼                         ▼
[WF-3: Notifica]      [WF-4: Git + .env Update]
  domenica 08:00              │
  (digest settimanale)        ▼
                        [WF-5: Nightly Deploy]
                          ogni notte 03:00
```

---

## Dettaglio dei 5 Workflow

### WF-1 — RSS Version Poller
**Trigger:** Cron ogni 6 ore  
**Carico CPU:** Minimo (solo HTTP GET + query SQL)

```
1. Per ogni servizio nel db:
   a. Fetch RSS da GitHub/GHCR/Codeberg releases
   b. Estrai latest tag
   c. Confronta con current_version
   d. Se diversa:
      - Rileva se Major/Minor/Patch (semver compare)
      - Aggiorna latest_version e status = 'pending'
      - Se 🟢 STATELESS → trigger diretto WF-4
      - Se Major e servizio CRITICO → flag manual_major = true
      - Altrimenti → lascia in coda per WF-3
```

**Feed RSS da usare per ogni servizio:**
- GitHub: `https://github.com/OWNER/REPO/releases.atom`
- GHCR non ha RSS nativo → usare GitHub releases del repo upstream
- Esempio Immich: `https://github.com/immich-app/immich/releases.atom`

### WF-2 — Approval Webhook
**Trigger:** HTTP GET/POST su `/webhook/approve`  
**Parametri:** `service`, `version`, `token` (HMAC per sicurezza)

```
1. Valida token HMAC (previene approvazioni non autorizzate)
2. Verifica che version corrisponda a latest_version nel db
3. Se Major e servizio CRITICO → blocca, risponde con warning
4. Imposta status = 'approved' e approved_at = now()
5. Risponde con pagina HTML di conferma (no redirect esterno)
```

### WF-3 — Weekly Digest
**Trigger:** Domenica ore 08:00  
**Output:** Notifica ntfy + (opzionale) email HTML

```
1. Query: tutti i record con status = 'pending' o 'approved'
2. Raggruppa per criticità
3. Genera messaggio ntfy con sezioni:
   - 🔴 Critici in attesa di approvazione (con link webhook)
   - 🟠 Medi in attesa di approvazione (con link webhook)
   - 🟡 Bassi: saranno aggiornati automaticamente questa notte
   - ✅ Già approvati e in coda per deploy
4. Invia su ntfy (topic: homelab-updates)
```

> **Perché ntfy e non mail?** Evita il rischio di saturazione inbox. La mail è opzionale come canale secondario solo per le approvazioni critiche, non per i digest. 

**Formato link approvazione (nel messaggio ntfy — click action):**
```
https://n8n.tuodominio.com/webhook/approve?service=immich&version=v2.8.0&token=HMAC
```

### WF-4 — Git + .env Updater
**Trigger:** Da WF-1 (stateless) o WF-2 (approved)  
**Dipendenza:** SSH key configurata per Forgejo

```
1. Legge .env corrente via SSH
2. Sostituisce la variabile di versione (sed)
3. Esegue make check → se fallisce, rollback e notifica su ntfy
4. Se check OK:
   git add .env
   git commit -m "chore(deps): update SERVICE to vX.Y.Z [n8n-auto]"
   git push origin main
5. Aggiorna db: status = 'committed', deployed_at = pending
6. Non esegue make up — ci pensa WF-5 di notte
```

**Eccezione Major Version:**
Se semver major change rilevato per servizi CRITICI (es. postgres 16→17), WF-4 si ferma e notifica:
```
⛔ BLOCCO MANUALE RICHIESTO
Service: postgres (nextcloud-db)
Current: 16-alpine → Latest: 17-alpine
Azione: richiede dump/restore manuale sul server
```

### WF-5 — Nightly Deploy
**Trigger:** Ogni notte ore 03:00 (solo se ci sono commit pendenti)  
**Carico sistema:** Alto — ma alle 3AM è accettabile

```
1. Controlla git log: ci sono commit fatti da n8n dopo l'ultimo deploy?
2. Se NO → sleep, nessuna azione
3. Se SÌ:
   a. make pull     (scarica immagini nuove)
   b. make up       (COMPOSE_PARALLEL_LIMIT=1 — attendi ~3-5 min)
   c. sleep 30s     (lascia ai container il tempo di diventare healthy)
   d. make health   (verifica container non healthy)
   e. Se health OK:
      - Aggiorna db: status = 'deployed'
      - ntfy: "✅ Deploy completato: [lista servizi]"
   f. Se health FAIL:
      - ntfy URGENTE: "🚨 Deploy fallito — intervento richiesto"
      - NON tentare rollback automatico (troppo rischioso)
      - Logga su Loki per debug
```

---

## Sezione 4 — Accesso Host da n8n (Scelta Architetturale)

Questa è la decisione più delicata. Ci sono due approcci:

### Opzione A: SSH verso localhost (Consigliata)

n8n esegue comandi tramite SSH sul host stesso. Più sicuro perché:
- La chiave SSH ha permessi limitati (solo l'utente homelab, non root)
- Il docker socket non è esposto al container n8n
- Facile da auditare

**Setup richiesto:**
```bash
# Sull'host: crea utente dedicato con permessi limitati
useradd -m n8n-runner
# Aggiungi al gruppo docker (necessario per make up)
usermod -aG docker n8n-runner
# Genera chiave SSH
ssh-keygen -t ed25519 -f /opt/n8n-ssh-key
# Copia pubkey in authorized_keys dell'utente
cat /opt/n8n-ssh-key.pub >> /home/n8n-runner/.ssh/authorized_keys
# Monta la chiave privata nel container n8n via volume
```

**In n8n:** nodo "Execute Command" con SSH verso `172.20.0.1` (gateway bridge) o IP host.

### Opzione B: Docker Socket (Più semplice, meno sicuro)

Montare `/var/run/docker.sock` nel container n8n. Già comune in homelab, ma:
- Il container n8n ottiene accesso root effettivo all'host
- Sconsigliato dal README stesso (`:ro` dove possibile)

**Verdict:** Usa **Opzione A** — è coerente con la filosofia di sicurezza già nel README.

---

## Sezione 5 — Gestione Rumore e Saturazione

Il problema principale di questi sistemi è finire per essere ignorati perché mandano troppi messaggi. Regole da implementare:

### Regola 1 — Un solo canale primario: ntfy
- Niente mail per i digest settimanali
- Mail solo per approvazioni critiche (Critico + Major version)
- ntfy supporta priorità: usa `priority: urgent` solo per 🔴 CRITICO

### Regola 2 — Deduplicazione
- Se una versione è già `pending` nel db, WF-1 non invia notifiche aggiuntive
- Notifica solo al primo rilevamento e al reminder domenicale

### Regola 3 — Silenzio Notturno
- WF-5 manda notifica di successo solo se qualcosa è stato effettivamente aggiornato
- Deploy senza modifiche → nessuna notifica

### Regola 4 — Rate Limit RSS
- 30 servizi × ogni 6h = 120 richieste/giorno a GitHub API
- GitHub ha un rate limit di 60 req/h non autenticato → **usa un token GitHub**
- Con token: 5000 req/h — ampiamente sufficiente

---

## Sezione 6 — versions.json (Stato Iniziale)

Prima di attivare WF-1, popolare il database con le versioni **attualmente in esecuzione** per evitare falsi positivi al primo run.

```json
{
  "services": [
    { "name": "nextcloud", "current": "33.0.2", "criticality": "critical", "rss": "https://github.com/nextcloud/server/releases.atom" },
    { "name": "immich", "current": "v2.7.5", "criticality": "critical", "rss": "https://github.com/immich-app/immich/releases.atom" },
    { "name": "paperless-ngx", "current": "2.20.13", "criticality": "critical", "rss": "https://github.com/paperless-ngx/paperless-ngx/releases.atom" },
    { "name": "vaultwarden", "current": "1.33.2", "criticality": "critical", "rss": "https://github.com/dani-garcia/vaultwarden/releases.atom" },
    { "name": "kopia", "current": "0.19", "criticality": "critical", "rss": "https://github.com/kopia/kopia/releases.atom" },
    { "name": "n8n", "current": "2.15.0", "criticality": "medium", "rss": "https://github.com/n8n-io/n8n/releases.atom" },
    { "name": "ollama", "current": "0.21.0", "criticality": "medium", "rss": "https://github.com/ollama/ollama/releases.atom" },
    { "name": "open-webui", "current": "v0.8.12", "criticality": "medium", "rss": "https://github.com/open-webui/open-webui/releases.atom" },
    { "name": "headscale", "current": "0.25", "criticality": "medium", "rss": "https://github.com/juanfont/headscale/releases.atom" },
    { "name": "nginx-proxy-manager", "current": "2.14.0", "criticality": "medium", "rss": "https://github.com/NginxProxyManager/nginx-proxy-manager/releases.atom" },
    { "name": "portainer", "current": "2.25.1", "criticality": "medium", "rss": "https://github.com/portainer/portainer/releases.atom" },
    { "name": "grafana", "current": "11.5.2", "criticality": "low", "rss": "https://github.com/grafana/grafana/releases.atom" },
    { "name": "loki", "current": "3.4.2", "criticality": "low", "rss": "https://github.com/grafana/loki/releases.atom" },
    { "name": "netdata", "current": "v2.3.0", "criticality": "low", "rss": "https://github.com/netdata/netdata/releases.atom" },
    { "name": "ntfy", "current": "v2.11.0", "criticality": "low", "rss": "https://github.com/binwiederhier/ntfy/releases.atom" },
    { "name": "cloudflared", "current": "latest", "criticality": "stateless", "rss": "https://github.com/cloudflare/cloudflared/releases.atom" }
  ]
}
```

---

## Roadmap di Implementazione

### Fase 0 — Pre-requisiti (prima di scrivere un workflow)
- [ ] Verificare stato stack `git/` (Forgejo up?)
- [ ] Risolvere `garage` in stato `restarting`
- [ ] Configurare token GitHub per API RSS
- [ ] Creare utente `n8n-runner` con SSH key
- [ ] Montare chiave SSH nel container n8n

### Fase 1 — Foundation (settimana 1)
- [ ] Creare tabella `service_versions` nel Postgres n8n
- [ ] Importare `versions.json` come stato iniziale
- [ ] WF-1: RSS Poller (solo lettura e scrittua db, NO notifiche ancora)
- [ ] Test: far girare WF-1 e verificare che non rilevi falsi positivi

### Fase 2 — Notifiche (settimana 2)
- [ ] WF-3: Weekly Digest su ntfy (domenica mattina)
- [ ] WF-2: Approval Webhook (con validazione HMAC)
- [ ] Test end-to-end: rilevamento → digest → approvazione via link

### Fase 3 — Automazione Git (settimana 3)
- [ ] WF-4: Git + .env Updater (prima su un servizio BASSO come test)
- [ ] Verifica che `make check` funzioni come gate di sicurezza
- [ ] Estendi a tutti i tier

### Fase 4 — Nightly Deploy (settimana 4)
- [ ] WF-5: Nightly Deploy con gate su health check
- [ ] Test completo su servizio non critico
- [ ] Monitor per 2 settimane prima di abilitare servizi CRITICI

### Fase 5 — Raffinamento (ongoing)
- [ ] Aggiungere gestione Major Version con blocco esplicito
- [ ] Dashboard Homepage con stato aggiornamenti
- [ ] Backup del db `service_versions` in Kopia

---

## Punti da Verificare con Deep Search

1. **Sicurezza webhook n8n**: best practice per HMAC token nei webhook, protezione da SSRF
2. **RSS GitHub rate limiting**: comportamento con token vs senza, gestione 429
3. **n8n Execute Command via SSH**: configurazione sicura del nodo SSH in n8n v2
4. **Semver parsing in n8n**: librerie JavaScript disponibili nel nodo Code per confronto versioni
5. **`COMPOSE_PARALLEL_LIMIT=1`**: impatto reale sui tempi di `make up` con 30+ container — quanto aspettare prima di lanciare `make health`?
6. **Vaultwarden update safety**: esiste una procedura consigliata per aggiornamenti sicuri senza perdere dati?
7. **Immich CUDA container**: gli aggiornamenti di immich-machine-learning richiedono allineamento con la versione di immich-server?
