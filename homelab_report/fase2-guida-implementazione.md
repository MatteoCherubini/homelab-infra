# Homelab — Fase 2: Roadmap Completa Post-Migrazione VLAN
*Generato: 13 Aprile 2026 · Basato su config.xml reale + compose modulare + decisioni sessione corrente*

---

## Stato di partenza

La Fase 1 è completata e verificata. La rete è segmentata in VLAN, i 27 container Docker girano su Nexus, le regole firewall sono attive e corrette. Questo documento copre **tutto ciò che resta da fare**, organizzato in fasi sequenziali con dipendenze esplicite.

### Decisioni già prese

| Decisione | Scelta | Motivazione |
|---|---|---|
| DMZ | Opzione A — parcheggiata (block all) | Semplicità, ZimaBoard 2GB |
| Tailscale su ZimaBoard | Rimuovere plugin, Nexus come jump host | Meno carico sulla ZimaBoard |
| Dominio | Da acquistare su Cloudflare (.com o .it) | API DDNS nativa in OPNsense, proxy CDN gratuito |
| WAN watchdog | Monit condizionale, rimuovere cron brutale | Interviene solo se rete veramente giù |
| UPS | NUT su Nexus via USB, shutdown ordinato | Green Cell PowerProof 2000VA — compatibile NUT |
| Docker compose | Migrazione a struttura modulare (già pronta) | Stack separati, .env centralizzato, versioni fissate |

---

## Panoramica fasi

```
FASE 2A — Pulizia OPNsense (nessun downtime)
    ↓
FASE 2B — SSH hardening (breve finestra rischio)
    ↓
FASE 2C — Migrazione Docker a struttura modulare (downtime ~10 min)
    ↓
FASE 2D — Setup iniziale servizi (nessun downtime)
    ↓
FASE 2E — Dominio + DDNS + SSL (richiede acquisto dominio)
    ↓
FASE 2F — Headscale VPN (dopo dominio)
    ↓
FASE 2G — UPS + NUT (indipendente, quando hai l'UPS)
    ↓
FASE 2H — Monitoring avanzato (Grafana + Loki)
    ↓
FASE 2I — Backup automatici (Kopia + Garage)
    ↓
FASE 3  — Torre Intel: VM AI/DEV/AUDIT (lungo termine)
```

---

## FASE 2A — Pulizia OPNsense

**Prerequisiti:** nessuno
**Downtime:** zero
**Rischio:** basso

### 2A.1 — Rimuovere plugin os-tailscale

Il plugin Tailscale è installato ma disabilitato. Non serve: useremo Nexus come jump host per raggiungere OPNsense da fuori casa.

```
SSH su OPNsense:
  pkg remove os-tailscale

Oppure GUI:
  System → Firmware → Plugins → os-tailscale → Rimuovi
```

**Verifica:** `pkg info | grep tailscale` non deve restituire nulla.

### 2A.2 — Rimuovere cron WAN watchdog brutale

Il cron attuale forza `interface reconfigure` ogni 5 minuti, anche quando la connessione funziona.

```
GUI:
  System → Settings → Cron
  → Trova "WAN DHCP renewal watchdog" (ogni 5 min, interface reconfigure)
  → Elimina

SSH (alternativa):
  configctl cron delete [uuid-del-job]
```

**UUID del job nel config.xml:** `e976c0dd-07ef-4f92-b472-5e76d752b55a`

### 2A.3 — Configurare Monit WAN watchdog intelligente

Monit è già attivo sulla ZimaBoard (intervallo 120 secondi). Il test `wan-watchdog` esiste già nel config.xml ma non è associato a un service. Dobbiamo:

1. Creare un service Monit che monitora la connettività WAN
2. Associare il test wan-watchdog esistente
3. Configurare l'azione di recovery

```
GUI: Services → Monit → Settings → Services

Clicca + per creare un nuovo service:

  Name:        wan_connectivity
  Type:        Custom
  Path:        /usr/local/opnsense/scripts/monit/gateway_alert.php
  Tests:       wan-watchdog (seleziona dal dropdown)
  Start:       /usr/local/sbin/configctl interface reconfigure re0
  Stop:        (vuoto)
  Enabled:     ✓

→ Save → Apply
```

Il test `wan-watchdog` è già configurato nel config.xml con questa logica:

```
Condizione: failed ping count 3 with timeout 5 address 8.8.8.8
Azione: restart
```

Questo significa: se 3 ping consecutivi a 8.8.8.8 falliscono (con timeout di 5 secondi ciascuno), Monit esegue il comando "Start" (che rinegozia il DHCP WAN). L'intervallo di check è quello globale di Monit: 120 secondi.

**Per aggiungere un secondo target di conferma** (evita falsi positivi se Google è down):

```
GUI: Services → Monit → Settings → Tests

Clicca + per creare un nuovo test:

  Name:        wan-watchdog-cloudflare
  Type:        NetworkPing
  Condition:   failed ping count 3 with timeout 5 address 1.1.1.1
  Action:      alert
```

Poi torna al service `wan_connectivity` e aggiungi entrambi i test: `wan-watchdog` + `wan-watchdog-cloudflare`.

**Verifica:**

```bash
# Controlla che Monit sia attivo e monitori il service
ssh root@10.0.10.1
configctl monit summary

# Dovresti vedere wan_connectivity nello stato "Running" o "Accessible"
```

### 2A.4 — Rimuovere range DHCP dalla DMZ

La DMZ è parcheggiata (block all) ma ha un range DHCP attivo (10.0.30.100-200). Rumore inutile.

```
GUI:
  Services → Dnsmasq DNS → DHCP Ranges
  → Trova il range per opt3 (DMZ, 10.0.30.100-200)
  → Elimina

→ Apply
```

### 2A.5 — Pulire utente admin legacy (opzionale)

L'utente `admin` con commento "Laptop LENOVO (vecchio ufficio)" ha una chiave SSH caricata. Se non lo usi più, eliminalo o aggiorna il commento.

```
GUI:
  System → Access → Users → admin
  → Se lo usi: aggiorna il commento in "Laptop Dell Latitude 7430"
  → Se non lo usi: elimina l'utente

ATTENZIONE: se elimini admin, assicurati di avere un altro utente con
accesso alla GUI (gruppo admins). root non è sufficiente se poi
disabiliti il root login.
```

### Checklist 2A

```
□ Plugin os-tailscale rimosso
□ Cron WAN watchdog eliminato
□ Monit wan_connectivity configurato e funzionante
□ Range DHCP DMZ eliminato
□ Utente admin pulito/aggiornato
□ Backup config.xml post-pulizia
```

---

## FASE 2B — SSH Hardening

**Prerequisiti:** 2A completata
**Downtime:** zero (ma finestra di rischio: se sbagli ti chiudi fuori)
**Rischio:** MEDIO — seguire l'ordine esatto

### Strategia anti-lockout

L'ordine è critico. Se disabiliti password auth prima di verificare la chiave, perdi l'accesso. Per sicurezza, **tieni aperta una sessione SSH attiva** durante tutta la procedura — una connessione già stabilita sopravvive al cambio di configurazione.

### 2B.1 — Generare chiave SSH sul laptop

```bash
# Sul laptop Dell (Ubuntu Studio)
ssh-keygen -t ed25519 -C "homelab-laptop-dell" -f ~/.ssh/homelab_key

# Inserisci una passphrase forte quando richiesto

# Risultato:
# ~/.ssh/homelab_key       ← privata (MAI condividere)
# ~/.ssh/homelab_key.pub   ← pubblica (da caricare)
```

### 2B.2 — Caricare la chiave su OPNsense (utente root)

**Importante:** nel config.xml attuale, `root` ha `<authorizedkeys/>` vuoto. La chiave va caricata su root.

```
GUI:
  System → Access → Users → root → Edit
  → Campo "Authorized keys"
  → Incolla il contenuto di ~/.ssh/homelab_key.pub
  → Save
```

**Alternativa SSH:**

```bash
# Dal laptop, copia la chiave
ssh-copy-id -i ~/.ssh/homelab_key.pub root@10.0.10.1
```

### 2B.3 — Caricare la stessa chiave su Nexus e Torre

```bash
# Nexus (utente homelab, o il tuo utente)
ssh-copy-id -i ~/.ssh/homelab_key.pub homelab@10.0.10.20

# Torre (utente root di Proxmox)
ssh-copy-id -i ~/.ssh/homelab_key.pub root@10.0.10.10
```

### 2B.4 — Configurare ~/.ssh/config sul laptop

```bash
nano ~/.ssh/config
```

Contenuto:

```
Host opnsense
    HostName 10.0.10.1
    User root
    IdentityFile ~/.ssh/homelab_key
    Port 22

Host nexus
    HostName 10.0.10.20
    User homelab
    IdentityFile ~/.ssh/homelab_key
    Port 22

Host torre
    HostName 10.0.10.10
    User root
    IdentityFile ~/.ssh/homelab_key
    Port 22
```

### 2B.5 — Verificare accesso con chiave (PRIMA di chiudere password)

```bash
# Apri un NUOVO terminale (tieni quello vecchio aperto come backup)
ssh opnsense    # deve connettersi senza chiedere password utente
                # (chiederà la passphrase della chiave)
ssh nexus
ssh torre
```

**Se anche solo uno fallisce: NON procedere.** Risolvi prima il problema.

### 2B.6 — Disabilitare password auth e root login su OPNsense

Solo dopo che 2B.5 funziona al 100%:

```
GUI (dalla sessione TRUSTED, non dalla sessione SSH):
  System → Settings → Administration → Secure Shell
  → "Permit root user login": OFF
  → "Permit password login": OFF
  → Save
```

**Nota:** dopo aver disabilitato il root login, dovrai usare l'utente `admin` per SSH su OPNsense (l'utente admin ha già una chiave caricata nel config.xml). Oppure crea un utente dedicato nel gruppo `admins` e carica la chiave su quello.

**Alternativa:** se vuoi mantenere root login ma solo con chiave (più semplice), disabilita solo "Permit password login" e lascia "Permit root user login" attivo.

### 2B.7 — Disabilitare password auth su Nexus e Torre

```bash
# Su Nexus
ssh nexus
sudo nano /etc/ssh/sshd_config
# Cambia: PasswordAuthentication no
# Cambia: PermitRootLogin no (o prohibit-password)
sudo systemctl restart sshd

# Su Torre (Proxmox)
ssh torre
nano /etc/ssh/sshd_config
# Cambia: PasswordAuthentication no
systemctl restart sshd
```

### 2B.8 — Test finale di sicurezza

```bash
# Da un altro terminale (o dal telefono in hotspot, simulando un estraneo)
ssh root@10.0.10.1                    # deve rifiutare
ssh -o PubkeyAuthentication=no root@10.0.10.1   # deve rifiutare
ssh homelab@10.0.10.20 -o PubkeyAuthentication=no  # deve rifiutare
```

### Checklist 2B

```
□ Chiave Ed25519 generata sul laptop
□ Chiave caricata su OPNsense (root o admin)
□ Chiave caricata su Nexus
□ Chiave caricata su Torre
□ ~/.ssh/config configurato
□ Accesso con chiave verificato su tutte e 3 le macchine
□ Password auth disabilitato su OPNsense
□ Password auth disabilitato su Nexus
□ Password auth disabilitato su Torre
□ Test di rifiuto superato
□ Backup config.xml post-hardening
```

---

## FASE 2C — Migrazione Docker a Struttura Modulare

**Prerequisiti:** 2B completata (accesso SSH sicuro)
**Downtime:** ~10-15 minuti (tutti i servizi Docker)
**Rischio:** medio — ha rollback facile

### Situazione attuale vs obiettivo

| Aspetto | Adesso | Dopo |
|---|---|---|
| Struttura | Un compose monolitico (presumo) in /opt/homelab | Struttura modulare con include |
| Path config | /opt/homelab/* | ${DATA_ROOT}/* (configurabile) |
| Path media | /mnt/md0/homelab_data/* | ${MEDIA_ROOT}/* (configurabile) |
| Password | Hardcoded nei compose | In .env (gitignored) |
| Versioni immagini | `:latest` su quasi tutto | Tag fissati su servizi critici |
| Repo Git | Non versionato | Repo Forgejo (dopo setup) |

### Analisi della struttura modulare fornita

La struttura modulare che hai generato è solida. Ecco cosa ho verificato:

**Punti di forza:**
- 11 stack ben separati per funzione
- Rete bridge condivisa `homelab` (tutti i container si vedono)
- Healthcheck su tutti i database PostgreSQL e Redis
- Versioni fissate su tutti i servizi critici (postgres:16-alpine, nextcloud:30.0.6, ecc.)
- Excalidraw è l'unico rimasto su `:latest` (scelta corretta: è stateless)
- Profilo GPU opzionale per Ollama
- Script init.sh che crea tutte le directory necessarie
- Makefile con comandi pratici

**Cose da adattare prima del deploy:**
- `.env.example` ha `DATA_ROOT=./data` e `MEDIA_ROOT=./media` — vanno mappati ai tuoi path reali
- Password tutte a `CHANGE_ME_*` — da generare
- `NEXTCLOUD_TRUSTED_DOMAINS=localhost` — da aggiornare
- Grafana ha `admin/admin` hardcoded — va messo nel .env
- Manca il DHCP rule per porta 67 su TRUSTED nel compose (non serve, è a livello firewall)

### 2C.1 — Preparazione (senza downtime)

```bash
# SSH su Nexus
ssh nexus

# Clona la struttura modulare (o copia da USB/scp)
# Mettiamola temporaneamente in /opt/homelab-new
mkdir -p /opt/homelab-new
cd /opt/homelab-new

# Copia la struttura (usa scp dal laptop o git clone se hai Forgejo)
# Poi...

# Crea il .env reale dal template
cp .env.example .env
```

### 2C.2 — Compilare il .env con valori reali

Edita `/opt/homelab-new/.env`:

```bash
nano /opt/homelab-new/.env
```

Valori da impostare:

```env
# ── PATH DATI ─────────────────────────────────────────────────
DATA_ROOT=/opt/homelab-new/data
MEDIA_ROOT=/mnt/md0/homelab_data

# ── TIMEZONE ──────────────────────────────────────────────────
TZ=Europe/Rome

# ── UID/GID ───────────────────────────────────────────────────
PUID=1000
PGID=1000

# ── PASSWORD DATABASE ─────────────────────────────────────────
# Genera password sicure con:  openssl rand -base64 24
NEXTCLOUD_DB_PASSWORD=<genera>
PAPERLESS_DB_PASSWORD=<genera>
PAPERLESS_SECRET_KEY=<genera con: openssl rand -hex 32>
N8N_DB_PASSWORD=<genera>
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=<genera>
IMMICH_DB_PASSWORD=<genera>

# ── DOMINI / TRUSTED HOSTS ────────────────────────────────────
NEXTCLOUD_TRUSTED_DOMAINS=10.0.10.20 cloud.TUODOMINIO.com localhost
HOMEPAGE_ALLOWED_HOSTS=10.0.10.20:3000

# ── GPU ───────────────────────────────────────────────────────
OLLAMA_GPU_ENABLED=false
# Su Nexus la GPU è una GTX 1660 Super — se vuoi usarla per Ollama:
# 1. Installa nvidia-container-toolkit su Ubuntu
# 2. Metti OLLAMA_GPU_ENABLED=true
# 3. Usa: make up-gpu
```

### 2C.3 — Creare le directory e migrare i dati

```bash
cd /opt/homelab-new

# Crea tutte le directory
./scripts/init.sh

# ── MIGRAZIONE DATI ──
# I dati dei container attuali sono in /opt/homelab/[servizio]/data (o simile)
# e i media su /mnt/md0/homelab_data/
#
# I media NON vanno copiati — basta puntare MEDIA_ROOT allo stesso path.
# I dati config/db VANNO copiati o linkati.
#
# Per ogni servizio, la mappatura è:
#   VECCHIO                              → NUOVO
#   /opt/homelab/nginx/*                 → /opt/homelab-new/data/nginx/*
#   /opt/homelab/headscale/*             → /opt/homelab-new/data/headscale/*
#   /opt/homelab/portainer/*             → /opt/homelab-new/data/portainer/*
#   ... e così via per ogni servizio
#
# ATTENZIONE: i database PostgreSQL (nextcloud-db, paperless-db, n8n-db, immich-db)
# DEVONO essere copiati con i container FERMI, altrimenti rischi corruzione.
```

**Nota importante sulle password dei database:**
Se i database esistenti hanno password vecchie (es. `nextcloud_secret`), hai due opzioni:

- **Opzione A (consigliata per ora):** usa le STESSE password vecchie nel nuovo .env. Funziona subito. Cambierai le password dopo, quando tutto è stabile.
- **Opzione B:** cambia le password, ma poi devi anche fare ALTER USER nel PostgreSQL di ogni database.

### 2C.4 — Cutover (downtime ~10 min)

```bash
# 1. Ferma il compose vecchio
cd /opt/homelab
docker compose down

# 2. Copia i dati config/db (se non già fatto)
#    Esempio per nginx:
cp -a /opt/homelab/nginx/data/* /opt/homelab-new/data/nginx/data/
cp -a /opt/homelab/nginx/letsencrypt/* /opt/homelab-new/data/nginx/letsencrypt/
#    ... ripeti per ogni servizio che ha dati da preservare

# 3. Verifica il nuovo compose
cd /opt/homelab-new
make check

# 4. Avvia
make up

# 5. Verifica
make ps
docker compose logs --tail=20
```

### 2C.5 — Verifica post-migrazione

```bash
# Tutti i container devono essere UP
make ps

# Test rapido dei servizi principali (dal laptop)
curl -s http://10.0.10.20:3000 | head -5    # Homepage
curl -s http://10.0.10.20:8087 | head -5    # Vaultwarden
curl -s http://10.0.10.20:9000 | head -5    # Portainer

# Se tutto OK, rinomina le directory
cd /opt
mv homelab homelab-old-$(date +%Y%m%d)
mv homelab-new homelab
```

### 2C.6 — Rollback (se qualcosa va storto)

```bash
cd /opt/homelab-new
docker compose down

cd /opt/homelab
docker compose up -d
# Sei tornato allo stato precedente
```

### Checklist 2C

```
□ Struttura modulare copiata su Nexus
□ .env compilato con path e password reali
□ Directory create con init.sh
□ Compose vecchio fermato
□ Dati config/db copiati
□ Nuovo compose avviato
□ Tutti i container UP
□ Servizi raggiungibili da VLAN trusted
□ Directory rinominate
□ Backup del vecchio compose conservato
```

---

## FASE 2D — Setup Iniziale Servizi

**Prerequisiti:** 2C completata (compose modulare in produzione)
**Downtime:** zero (setup via browser)
**Rischio:** basso

Questi servizi sono in esecuzione ma mai configurati (primo accesso).

### 2D.1 — Forgejo (Git)

```
Browser: http://10.0.10.20:3001

Primo accesso → Installation wizard:
  Database Type: SQLite3 (semplice, sufficiente per uso personale)
  Site Title: Homelab Git
  Administrator Account:
    Username: admin (o il tuo)
    Password: <forte, salva in Vaultwarden dopo>
    Email: tuo@email.com
  → Install Forgejo

Dopo il setup:
  1. Crea repo "homelab" (per versionare i compose)
  2. Dal laptop:
     cd /opt/homelab  (via SSH su Nexus)
     git init
     git remote add origin http://10.0.10.20:3001/admin/homelab.git
     git add .
     git commit -m "Initial commit: struttura modulare"
     git push -u origin main
```

### 2D.2 — Vaultwarden (Password Manager)

```
Browser: http://10.0.10.20:8087

1. Registra il primo account (le registrazioni sono disabilitate dopo
   nel .env con VAULTWARDEN_SIGNUPS_ALLOWED=false — cambialo
   temporaneamente a true per creare il tuo account)

2. Dopo la registrazione:
   - Abilita il pannello admin: aggiungi ADMIN_TOKEN nel .env
     ADMIN_TOKEN=<genera con: openssl rand -base64 48>
   - Accedi a /admin per gestire utenti
   - Ri-disabilita le registrazioni

3. Importa le password dal tuo password manager attuale
   (Bitwarden, KeePass, Chrome → Export CSV → Import in Vaultwarden)

4. Installa l'estensione Bitwarden nel browser e il client mobile
   URL server: http://10.0.10.20:8087
   (dopo il dominio: https://vault.TUODOMINIO.com)
```

### 2D.3 — Nextcloud (Cloud Storage)

```
Browser: http://10.0.10.20:8088

Primo accesso → Setup wizard:
  Admin username: admin
  Admin password: <forte>
  Storage & database: già configurato via env
  → Install

Dopo il setup:
  1. Settings → Basic settings → Background jobs → Cron
  2. Settings → Overview → verificare che non ci siano warning
  3. La cartella dati è su /mnt/md0/homelab_data/nextcloud/data (RAID 1)
```

### 2D.4 — Paperless-ngx (Documenti)

```
Browser: http://10.0.10.20:8089

Primo accesso — crea il superuser via CLI:
  ssh nexus
  cd /opt/homelab
  docker compose exec paperless python3 manage.py createsuperuser
  → Username, email, password

Accedi con le credenziali create.

Configurazione:
  - OCR già impostato su ita+eng nel .env
  - La cartella "consume" è /mnt/md0/homelab_data/paperless/consume
    Qualsiasi PDF messo qui viene processato automaticamente
```

### 2D.5 — Immich (Foto)

```
Browser: http://10.0.10.20:2283

Primo accesso → Registrazione:
  - Crea il primo utente (diventa admin)
  - Le foto vanno in /mnt/md0/homelab_data/immich/upload (RAID 1)

Setup mobile:
  - Installa app Immich su telefono
  - Server URL: http://10.0.10.20:2283
    (dopo il dominio: https://photos.TUODOMINIO.com)
  - Abilita backup automatico foto
```

### 2D.6 — Kopia (Backup)

```
Browser: http://10.0.10.20:51515

Il compose avvia Kopia in modalità server.
Al primo accesso chiederà di configurare il repository:

  1. Repository type: Filesystem (per backup locale)
     Path: /media_data (che nel container mappa /mnt/md0/homelab_data)
     Oppure: dopo aver configurato Garage S3, usa S3-compatible

  2. Imposta password del repository (la password cifra i backup)

  3. Configura le policy:
     - Snapshot dei volumi Docker (/data nel container, che è DATA_ROOT)
     - Retention: 7 daily, 4 weekly, 6 monthly
     - Schedule: 02:00 ogni notte
```

### 2D.7 — Homepage Dashboard

```
ssh nexus
nano /opt/homelab/data/homepage/config/services.yaml
```

Il file services.yaml va aggiornato con i nuovi IP (10.0.10.x). Esempio di struttura:

```yaml
---
- Infrastructure:
    - OPNsense:
        icon: opnsense.png
        href: https://10.0.10.1
        description: Firewall
    - Proxmox:
        icon: proxmox.png
        href: https://10.0.10.10:8006
        description: Hypervisor
    - Portainer:
        icon: portainer.png
        href: http://10.0.10.20:9000
        description: Container management
    - Netdata:
        icon: netdata.png
        href: http://10.0.10.20:19999
        description: System monitoring

- Services:
    - Nextcloud:
        icon: nextcloud.png
        href: http://10.0.10.20:8088
        description: Cloud storage
    - Vaultwarden:
        icon: bitwarden.png
        href: http://10.0.10.20:8087
        description: Password manager
    - Immich:
        icon: immich.png
        href: http://10.0.10.20:2283
        description: Photo backup
    - Paperless:
        icon: paperless-ngx.png
        href: http://10.0.10.20:8089
        description: Document management

- Tools:
    - Forgejo:
        icon: forgejo.png
        href: http://10.0.10.20:3001
        description: Git repos
    - n8n:
        icon: n8n.png
        href: http://10.0.10.20:5678
        description: Automation
    - Open WebUI:
        icon: open-webui.png
        href: http://10.0.10.20:8090
        description: AI chat
    - Excalidraw:
        icon: excalidraw.png
        href: http://10.0.10.20:8092
        description: Whiteboard

- Networking:
    - Headscale:
        icon: tailscale.png
        href: http://10.0.10.20:8086
        description: VPN mesh
    - Nginx Proxy Manager:
        icon: nginx-proxy-manager.png
        href: http://10.0.10.20:81
        description: Reverse proxy
    - Pingvin Share:
        icon: pingvin-share.png
        href: http://10.0.10.20:3002
        description: File sharing
    - ntfy:
        icon: ntfy.png
        href: http://10.0.10.20:8091
        description: Push notifications
```

### Checklist 2D

```
□ Forgejo: admin creato, repo homelab inizializzato
□ Vaultwarden: account creato, registrazioni chiuse, estensione installata
□ Nextcloud: wizard completato, background jobs su Cron
□ Paperless: superuser creato, OCR ita+eng attivo
□ Immich: utente creato, app mobile configurata
□ Kopia: repository inizializzato, policy backup configurate
□ Homepage: services.yaml aggiornato con IP corretti
```

---

## FASE 2E — Dominio + DDNS + SSL + Split DNS

**Prerequisiti:** 2D completata + dominio acquistato su Cloudflare
**Downtime:** zero
**Rischio:** basso

### 2E.1 — Acquistare e configurare il dominio

```
1. Registrati su Cloudflare (account gratuito)
2. Cloudflare Registrar → Register Domain
   Scegli: tuocognome.com o tuocognome.it (~10€/anno)
3. Dopo la registrazione, vai nella dashboard del dominio
```

### 2E.2 — Creare i record DNS su Cloudflare

```
Cloudflare Dashboard → DNS → Records

Tipo    Nome        Contenuto           Proxy   TTL
A       @           TUO_IP_PUBBLICO     Proxied Auto
A       cloud       TUO_IP_PUBBLICO     Proxied Auto
A       vault       TUO_IP_PUBBLICO     Proxied Auto
A       photos      TUO_IP_PUBBLICO     Proxied Auto
A       ntfy        TUO_IP_PUBBLICO     Proxied Auto
A       git         TUO_IP_PUBBLICO     Proxied Auto
```

**Nota:** il tuo IP pubblico Tiscali è dinamico. Lo configuriamo nel passo successivo con DDNS.

### 2E.3 — Configurare DDNS su OPNsense

```
GUI OPNsense:
  Services → Dynamic DNS → Accounts → +

  Service:       Cloudflare
  Username:      email@cloudflare (o API token)
  Password:      Global API Key (o API Token con zone DNS edit)
  Hostname:      tuodominio.com
  Zone:          tuodominio.com
  Check IP:      Interface - WAN
  Interface:     WAN
  Description:   Cloudflare DDNS

  → Save → Test (deve mostrare "Updated")
```

OPNsense aggiornerà automaticamente l'IP su Cloudflare quando cambia.

### 2E.4 — Configurare Nginx Proxy Manager

```
Browser: http://10.0.10.20:81

Primo accesso:
  Email:    admin@example.com
  Password: changeme
  → Cambialo subito!

Per ogni sottodominio, crea un Proxy Host:

  1. cloud.tuodominio.com → http://nextcloud:80
     (usa il nome container, non l'IP — sono sulla stessa rete Docker)
     SSL: Request a new SSL certificate (Let's Encrypt)
     Force SSL: ✓
     HTTP/2: ✓

  2. vault.tuodominio.com → http://vaultwarden:80
     SSL + Force SSL + HTTP/2

  3. photos.tuodominio.com → http://immich-server:2283
     SSL + Force SSL + HTTP/2
     Websockets: ✓

  4. ntfy.tuodominio.com → http://ntfy:80
     SSL + Force SSL + HTTP/2

  5. git.tuodominio.com → http://forgejo:3000
     SSL + Force SSL + HTTP/2
     (opzionale)
```

**Nota su Cloudflare Proxy + Let's Encrypt:**
Se usi Cloudflare Proxy (arancione), devi configurare SSL su Cloudflare come "Full (Strict)" per funzionare con i certificati Let's Encrypt di Nginx. Vai su Cloudflare → SSL/TLS → Overview → Full (Strict).

### 2E.5 — Configurare Split DNS (per accesso locale con dominio)

NAT Reflection è disabilitata nel tuo config.xml. Questo significa che dall'interno della rete, `cloud.tuodominio.com` non funzionerà (il DNS risolve all'IP pubblico, ma il router non fa hairpin NAT).

La soluzione pulita è **Split DNS** con Unbound:

```
GUI OPNsense:
  Services → Unbound DNS → Overrides → Host Overrides

  Per ogni sottodominio:

  Host:      cloud
  Domain:    tuodominio.com
  IP:        10.0.10.20
  Description: Nextcloud (local override)

  Host:      vault
  Domain:    tuodominio.com
  IP:        10.0.10.20

  Host:      photos
  Domain:    tuodominio.com
  IP:        10.0.10.20

  Host:      ntfy
  Domain:    tuodominio.com
  IP:        10.0.10.20

  Host:      git
  Domain:    tuodominio.com
  IP:        10.0.10.20

  → Apply
```

Così, dalla VLAN trusted, `cloud.tuodominio.com` risolve a 10.0.10.20 (diretto), mentre da Internet risolve all'IP pubblico (passa per Cloudflare → port forward → Nginx).

### 2E.6 — Aggiornare NEXTCLOUD_TRUSTED_DOMAINS

```bash
ssh nexus
nano /opt/homelab/.env

# Aggiorna:
NEXTCLOUD_TRUSTED_DOMAINS=10.0.10.20 cloud.tuodominio.com localhost

# Restart Nextcloud:
cd /opt/homelab
docker compose restart nextcloud
```

### Checklist 2E

```
□ Dominio registrato su Cloudflare
□ Record DNS A creati (@ + sottodomini)
□ Cloudflare SSL impostato su Full (Strict)
□ DDNS configurato su OPNsense e funzionante
□ Nginx Proxy Manager: admin password cambiata
□ Proxy host creati per tutti i sottodomini (5)
□ SSL Let's Encrypt attivo su tutti i proxy host
□ Split DNS configurato in Unbound (5 override)
□ NEXTCLOUD_TRUSTED_DOMAINS aggiornato
□ Test da interno: curl https://cloud.tuodominio.com → funziona
□ Test da esterno (hotspot mobile): https://cloud.tuodominio.com → funziona
```

---

## FASE 2F — Headscale VPN

**Prerequisiti:** 2E completata (dominio + DDNS attivi)
**Downtime:** zero
**Rischio:** basso

### 2F.1 — Configurare Headscale

```bash
ssh nexus

# Crea la configurazione Headscale
nano /opt/homelab/data/headscale/config/config.yaml
```

Configurazione minima:

```yaml
server_url: https://hs.tuodominio.com:8085
# oppure se non vuoi un sottodominio dedicato:
# server_url: http://10.0.10.20:8085

listen_addr: 0.0.0.0:8080
private_key_path: /var/lib/headscale/private.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key
database:
  type: sqlite3
  sqlite:
    path: /var/lib/headscale/db.sqlite
ip_prefixes:
  - 100.64.0.0/10
dns:
  magic_dns: true
  base_domain: headscale.tuodominio.com
  nameservers:
    global:
      - 10.0.10.1
```

```bash
# Restart Headscale
docker compose restart headscale

# Crea un utente
docker compose exec headscale headscale users create homelab

# Genera una pre-auth key (per registrare i client)
docker compose exec headscale headscale preauthkeys create \
  --user homelab --reusable --expiration 24h
# Copia la key generata
```

### 2F.2 — Installare Tailscale client sul laptop

```bash
# Sul laptop Dell
curl -fsSL https://tailscale.com/install.sh | sh

# Connetti a Headscale
sudo tailscale up --login-server http://10.0.10.20:8085 \
  --authkey <la-key-generata>

# Verifica
tailscale status
# Deve mostrare il laptop connesso alla rete 100.64.x.x
```

### 2F.3 — Installare Tailscale client sul telefono

```
1. Installa l'app Tailscale da Play Store / App Store
2. Impostazioni → Use custom coordination server
   URL: https://hs.tuodominio.com:8085
   (o http://IP-PUBBLICO:8085 se non hai ancora il sottodominio)
3. Genera una nuova authkey e usala per registrare il telefono
```

### 2F.4 — Test accesso VPN

```bash
# Dal laptop, disconnettiti dalla VLAN (usa hotspot mobile)
# Poi testa l'accesso via VPN:

ping 10.0.10.20         # Nexus via VPN
ssh nexus               # SSH via VPN
curl http://10.0.10.20:3000   # Homepage via VPN

# Per accedere a OPNsense da fuori (Nexus come jump host):
ssh nexus
ssh root@10.0.10.1      # OPNsense dal jump host
```

### Checklist 2F

```
□ Headscale config.yaml creato
□ Utente Headscale creato
□ Laptop Tailscale registrato e connesso
□ Mobile Tailscale registrato e connesso
□ Test accesso SSH via VPN funzionante
□ Test accesso servizi Docker via VPN funzionante
□ Test jump host verso OPNsense funzionante
```

---

## FASE 2G — UPS + NUT

**Prerequisiti:** UPS fisicamente collegato e alimentato
**Downtime:** zero (aggiunge un container)
**Rischio:** basso

### Hardware

**Modello:** Green Cell PowerProof 2000VA 1400W (UPS09)
**Connessione:** USB (cavo incluso) — nessuna porta ethernet
**Compatibilità NUT:** confermata, driver `nutdrv_qx` con protocollo `q1` (o `megatec`)
**Batteria:** 2× 12V 9Ah AGM, tensione nominale 24V
**Uscite:** 2× Schuko + 3× IEC C13

### Collegamento fisico

```
Corrente muro → UPS (ingresso AC)
UPS uscite Schuko → Ciabatte con:
  - ZimaBoard
  - Nexus
  - Switch TP-Link
  - (opzionale) Torre Intel

UPS porta USB → Nexus (porta USB libera)
```

La Torre Intel consuma troppo per il battery time dell'UPS (soprattutto con GPU). Valuta se includerla o no. ZimaBoard + Nexus + Switch stanno bene dentro i 1400W.

### 2G.1 — Verificare che Nexus veda l'UPS via USB

```bash
ssh nexus

# Collega il cavo USB dall'UPS a Nexus
# Poi verifica:
lsusb
# Deve mostrare qualcosa come:
# Bus 001 Device 00X: ID 0001:0000 Fry's Electronics MEC0003
# (il vendor/product ID può variare)

# Per dettagli:
lsusb -v 2>/dev/null | grep -A5 -i "ups\|MEC\|Fry"
```

### 2G.2 — Creare lo stack Docker NUT

Aggiungi un nuovo stack `stacks/ups/compose.yml`:

```yaml
# ── UPS: NUT (Network UPS Tools) ──

services:

  nut-server:
    image: instantlinux/nut-upsd:latest
    restart: unless-stopped
    ports:
      - "3493:3493"
    volumes:
      - ${DATA_ROOT}/nut/etc:/etc/nut
    devices:
      - /dev/bus/usb:/dev/bus/usb
    privileged: true
    environment:
      API_USER: upsmon
      API_PASSWORD: ${NUT_API_PASSWORD}
    networks:
      - homelab
```

**Nota:** `privileged: true` è necessario per accedere al device USB. In alternativa, puoi mappare solo il device specifico con `devices: - /dev/bus/usb/001/00X:/dev/bus/usb/001/00X` (meno permissivo ma devi trovare il path esatto).

### 2G.3 — Configurare NUT

```bash
# Crea la directory config
mkdir -p /opt/homelab/data/nut/etc
```

**File `/opt/homelab/data/nut/etc/ups.conf`:**

```ini
maxretry = 3
pollinterval = 5

[greencell]
    driver = nutdrv_qx
    protocol = q1
    port = auto
    desc = "Green Cell PowerProof 2000VA UPS05"
    vendorid = 0001
    productid = 0000

    # Parametri batteria
    default.battery.voltage.nominal = 24
    default.battery.voltage.low = 21.00
    default.battery.voltage.high = 25.00
    default.battery.packs = 2
    default.battery.type = PbAcid
    default.battery.capacity.nominal = 18.0

    # Soglie
    default.battery.charge.low = 15
    default.battery.charge.warning = 50

    # Runtime stimato (secondi a pieno carico, secondi a mezzo carico)
    runtimecal = 2340,8,4740,4

    # Info UPS
    default.ups.mfr = "Green Cell"
    default.ups.model = "PowerProof 2000VA"
    default.ups.power.nominal = 2000
    default.ups.realpower.nominal = 1400
```

**File `/opt/homelab/data/nut/etc/upsd.conf`:**

```ini
LISTEN 0.0.0.0 3493
```

**File `/opt/homelab/data/nut/etc/upsd.users`:**

```ini
[upsmon]
    password = LA_PASSWORD_DAL_ENV
    upsmon primary
    actions = SET
    instcmds = ALL
```

**File `/opt/homelab/data/nut/etc/upsmon.conf`:**

```ini
MONITOR greencell@localhost 1 upsmon LA_PASSWORD_DAL_ENV primary
SHUTDOWNCMD "/sbin/shutdown -h now"
POWERDOWNFLAG /etc/killpower
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 5
POLLFREQALERT 2
HOSTSYNC 15
DEADTIME 15
FINALDELAY 5

NOTIFYFLAG ONLINE     SYSLOG+EXEC
NOTIFYFLAG ONBATT     SYSLOG+EXEC
NOTIFYFLAG LOWBATT    SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN   SYSLOG+EXEC
```

### 2G.4 — Aggiungere al compose root e al .env

```bash
# Nel docker-compose.yml root, aggiungi:
#   - stacks/ups/compose.yml

# Nel .env, aggiungi:
# NUT_API_PASSWORD=<genera con: openssl rand -base64 24>
```

### 2G.5 — Script di shutdown ordinato

Crea `/opt/homelab/scripts/ups-shutdown.sh`:

```bash
#!/bin/bash
# Shutdown ordinato in caso di batteria bassa
# Chiamato da NUT quando raggiunge la soglia critica

LOG="/var/log/ups-shutdown.log"
echo "$(date) - UPS LOW BATTERY - Inizio shutdown ordinato" >> $LOG

# 1. Notifica via ntfy (se raggiungibile)
curl -s -d "UPS batteria bassa! Shutdown automatico in corso." \
  http://localhost:8091/homelab 2>/dev/null || true

# 2. Shutdown ordinato dei container Docker
cd /opt/homelab
docker compose down >> $LOG 2>&1

# 3. Se la Torre è accesa, spegnila (opzionale)
# ssh -o ConnectTimeout=5 root@10.0.10.10 "qm shutdown 100; shutdown -h now" 2>/dev/null

# 4. Shutdown Nexus
echo "$(date) - Shutdown Nexus" >> $LOG
shutdown -h now
```

```bash
chmod +x /opt/homelab/scripts/ups-shutdown.sh
```

### 2G.6 — Integrazione con Homepage (widget UPS)

Homepage supporta NUT come widget. Aggiungi in `services.yaml`:

```yaml
- Power:
    - UPS:
        icon: ups.png
        href: ""
        widget:
          type: nut
          url: http://nut-server:3493
          ups: greencell
```

### Checklist 2G

```
□ UPS fisicamente collegato (elettrico + USB)
□ lsusb vede l'UPS
□ Stack ups/compose.yml creato
□ File config NUT creati (ups.conf, upsd.conf, upsd.users, upsmon.conf)
□ Container NUT avviato e funzionante
□ upsc greencell@localhost mostra i dati UPS
□ Script ups-shutdown.sh creato e testato
□ Widget Homepage configurato
□ Test: scollega UPS dalla corrente → verifica che NUT rilevi "on battery"
□ Test: verifica che la notifica ntfy arrivi
```

---

## FASE 2H — Monitoring Avanzato (Grafana + Loki + Promtail)

**Prerequisiti:** 2C completata
**Downtime:** zero (nuovi container)
**Rischio:** basso

I container Grafana, Loki e Promtail sono già definiti nel compose modulare (`stacks/monitoring/compose.yml`) ma non ancora configurati.

### 2H.1 — Configurare Promtail

```bash
mkdir -p /opt/homelab/data/promtail/config
nano /opt/homelab/data/promtail/config/config.yml
```

```yaml
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        target_label: container
      - source_labels: ['__meta_docker_container_log_stream']
        target_label: stream

  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          __path__: /var/log/syslog
```

### 2H.2 — Configurare Grafana

```
Browser: http://10.0.10.20:3003

Login: admin / admin (cambiare subito!)

1. Settings → Data Sources → Add data source
   Type: Loki
   URL: http://loki:3100
   → Save & Test

2. Import dashboard per Docker logs:
   Dashboard → Import → ID 13639 (Docker monitoring)

3. Import dashboard per NUT (se configurato):
   Dashboard → Import → cerca "NUT UPS"
```

### 2H.3 — Aggiungere password Grafana al .env

```bash
# Nel .env aggiungi:
GRAFANA_ADMIN_PASSWORD=<genera>

# Nel compose monitoring, modifica:
# GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
```

### Checklist 2H

```
□ Promtail config.yml creato
□ Loki avviato e riceve log
□ Grafana: password admin cambiata
□ Data source Loki configurato in Grafana
□ Dashboard Docker logs importata
□ Dashboard UPS importata (se 2G completata)
```

---

## FASE 2I — Backup Automatici (Kopia + Garage S3)

**Prerequisiti:** 2D.6 (Kopia configurato) + 2C completata
**Downtime:** zero
**Rischio:** basso

### 2I.1 — Configurare Garage S3

```bash
# Crea la configurazione Garage
nano /opt/homelab/data/garage/meta/garage.toml
```

```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"

replication_factor = 1

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[s3_web]
bind_addr = "[::]:3902"
root_domain = ".web.garage.localhost"

[admin]
api_bind_addr = "[::]:3903"
```

```bash
# Restart Garage
docker compose restart garage

# Inizializza il nodo
docker compose exec garage /garage status
docker compose exec garage /garage layout assign -z dc1 -c 3.5T <node-id>
docker compose exec garage /garage layout apply --version 1

# Crea bucket per backup
docker compose exec garage /garage bucket create backups
docker compose exec garage /garage key create kopia-key
docker compose exec garage /garage bucket allow backups --read --write --key kopia-key
```

### 2I.2 — Configurare Kopia verso Garage S3

```
Browser: http://10.0.10.20:51515

Repository → Connect → S3 Compatible:
  Endpoint: garage:3900
  Bucket: backups
  Access Key: <dalla key creata sopra>
  Secret Key: <dalla key creata sopra>
  Region: garage
  → Connect
```

### 2I.3 — Configurare le policy di backup

```
In Kopia Web UI:
  Policies → New Policy

  Sorgente: /data (che nel container è DATA_ROOT — config e database)
  Schedule: 02:00 ogni giorno
  Retention: 7 daily, 4 weekly, 12 monthly, 2 yearly
  Compression: zstd

  Seconda policy:
  Sorgente: /media_data (che è MEDIA_ROOT — foto, documenti)
  Schedule: 03:00 ogni giorno
  Retention: 7 daily, 4 weekly, 6 monthly
  Compression: zstd (o none per foto/video già compressi)
```

### Checklist 2I

```
□ Garage garage.toml configurato
□ Nodo Garage inizializzato e layout applicato
□ Bucket "backups" creato
□ Key per Kopia creata con permessi read/write
□ Kopia connesso a Garage S3
□ Policy backup DATA_ROOT configurata (02:00)
□ Policy backup MEDIA_ROOT configurata (03:00)
□ Test: snapshot manuale → verifica che sia visibile in Kopia
□ Test: restore di un file dal backup
```

---

## FASE 3 — Torre Intel: VM (Lungo Termine)

**Prerequisiti:** tutto il resto completato
**Downtime:** nessuno su Nexus
**Rischio:** isolato a Torre

### 3.1 — VM 101: AI (Ollama modelli grandi)

```
Proxmox → Create VM:
  Name: ai
  OS: Ubuntu Server 24.04 LTS
  CPU: 8 cores
  RAM: 32GB
  Disk: 100GB (SSD)
  GPU: RTX 5060 Ti passthrough
  Network: vmbr0 (VLAN 10)
  IP: 10.0.10.11 (statico)

Post-install:
  - Installa nvidia-driver + nvidia-container-toolkit
  - Installa Docker
  - Sposta Ollama da Nexus a questa VM (modelli grandi)
  - Open WebUI su Nexus punta a 10.0.10.11:11434
```

### 3.2 — VM 102: DEV (Sviluppo)

```
Proxmox → Create VM:
  Name: dev
  OS: Ubuntu Server 24.04 LTS
  CPU: 4 cores
  RAM: 16GB
  Disk: 80GB (SSD)
  Network: vmbr0 (VLAN 10)
  IP: 10.0.10.12 (statico)

Post-install:
  - Ambiente sviluppo con Docker, Node, Python
  - Accesso via SSH dal laptop
```

### 3.3 — VM 103: AUDIT (Parrot OS)

```
Proxmox → Create VM:
  Name: audit
  OS: Parrot OS Security Edition
  CPU: 4 cores
  RAM: 8GB
  Disk: 60GB (SSD)
  Network: vmbr0 (VLAN 10)
  IP: DHCP o 10.0.10.13 (statico)

Post-install:
  - Parrot OS con strumenti di audit preinstallati
  - Accesso VNC/SPICE da Proxmox GUI
```

### 3.4 — Aggiornare firewall per nuove VM

Quando crei le VM, aggiungi le regole in OPNsense:

```
Alias aggiuntivi:
  SERVER_AI    → 10.0.10.11
  SERVER_DEV   → 10.0.10.12

Regole TRUSTED aggiuntive:
  PASS TCP TRUSTED → SERVER_AI porta 11434 (Ollama API)
  PASS TCP TRUSTED → SERVER_AI porta 22 (SSH)
  PASS TCP TRUSTED → SERVER_DEV porta 22 (SSH)

DHCP statico:
  Aggiungi i MAC delle VM nel Dnsmasq di OPNsense
```

---

## Riepilogo porte firewall — Aggiornamenti necessari

### Porte da aggiungere all'alias NEXUS_WEB (se aggiungi servizi)

| Porta | Servizio | Quando |
|---|---|---|
| 3003 | Grafana | Fase 2H |
| 3493 | NUT | Fase 2G (opzionale, solo se vuoi accederci dalla LAN) |

### Porte da aggiungere alle regole TRUSTED

Attualmente le regole TRUSTED coprono già tutto il necessario per i servizi attuali. Le porte 3003 (Grafana) e 3100 (Loki) sono già nell'alias NEXUS_WEB o comunque raggiungibili dalla regola "Internet libero" (che catcha tutto ciò che non è IoT/DMZ).

**Attenzione:** la regola 12 su TRUSTED ("Pass any → any" per Internet) è molto permissiva e catcha anche il traffico verso Nexus su porte non esplicitamente elencate. Questo semplifica la gestione (non devi aggiungere ogni porta) ma è meno granulare. È una scelta consapevole — per un homelab personale va bene.

---

## Registro decisioni aperte

| # | Questione | Opzioni | Stato |
|---|---|---|---|
| 1 | Dominio esatto | .com / .it / quale nome | In attesa di acquisto |
| 2 | GPU Ollama su Nexus | Abilitare GTX 1660S con nvidia-container-toolkit | Da decidere |
| 3 | Includere Torre nell'UPS | 1400W potrebbe non bastare con GPU sotto carico | Da valutare col wattmetro |
| 4 | Console menu OPNsense | Attualmente disabilitato — recovery difficile | Consiglio: riabilitare |
| 5 | Backup offsite | Backblaze B2 (10GB gratis) o solo locale | Da decidere |
| 6 | Nextcloud storage esterno | Usare il RAID come external storage o come data dir | Da decidere al setup |

---

## Quick Reference — Comandi frequenti

```bash
# ── Docker (su Nexus) ──────────────────────────────
ssh nexus
cd /opt/homelab
make up                    # Avvia tutto
make down                  # Ferma tutto
make ps                    # Stato
make logs                  # Log live
make pull                  # Aggiorna immagini (non riavvia)
docker compose up -d nginx # Riavvia solo un servizio

# ── OPNsense ──────────────────────────────────────
ssh opnsense               # (o ssh root@10.0.10.1)
pfctl -sr                  # Regole firewall attive
pfctl -sT                  # Tabelle/alias PF
configctl interface reload # Ricarica interfacce
configctl unbound reconfigure # Ricarica DNS

# ── Backup config OPNsense ────────────────────────
ssh opnsense
cp /conf/config.xml /root/config_backup_$(date +%Y%m%d_%H%M).xml
scp root@10.0.10.1:/conf/config.xml ~/backup_opnsense/

# ── Proxmox ────────────────────────────────────────
ssh torre
qm list                   # Lista VM
qm start 100              # Avvia VM
qm shutdown 100            # Shutdown graceful
```

---

*Questo documento è il piano di lavoro per tutte le fasi successive alla migrazione VLAN. Ogni fase è indipendente (tranne dove segnato) e reversibile. Aggiornare il documento dopo ogni fase completata.*