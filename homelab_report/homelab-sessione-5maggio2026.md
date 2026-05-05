# Homelab keruhomelab.com — Resoconto Sessione
*Data: 5 Maggio 2026 · Punto di partenza: fase2-punto-zero.md*

---

## Indice

1. [Stato di partenza della sessione](#1-stato-di-partenza)
2. [Analisi firewall OPNsense](#2-analisi-firewall-opnsense)
3. [Analisi stack Docker Nexus](#3-analisi-stack-docker-nexus)
4. [Deploy Cloudflare Tunnel](#4-deploy-cloudflare-tunnel)
5. [Fix Forgejo — ROOT_URL, rete Docker, alias](#5-fix-forgejo)
6. [Fix NPM — SSL, headers, Force SSL vs tunnel](#6-fix-npm)
7. [Split DNS Unbound OPNsense](#7-split-dns-unbound)
8. [Il bug che bloccava tutto — CNAME tunnel ID sbagliato](#8-il-bug-cname-tunnel-id-sbagliato)
9. [Configurazione finale funzionante](#9-configurazione-finale-funzionante)
10. [Roadmap prossima sessione](#10-roadmap-prossima-sessione)
11. [Lezioni apprese](#11-lezioni-apprese)
12. [Riferimento rapido](#12-riferimento-rapido)

---

## 1. Stato di partenza

### Cosa era già fatto (dal punto zero del 4 Maggio)

| Componente | Stato |
|---|---|
| RAID /dev/md0 | ✅ Montato su `/mnt/md0`, dati migrati |
| Docker stack (29 container) | ✅ Tutti up e stabili |
| Cloudflare Tunnel (cloudflared) | ❌ Container mai avviato |
| Split DNS Unbound | ❌ Nessun host override |
| Record DNS Cloudflare | ❌ Eliminati manualmente nella sessione precedente |
| Forgejo ROOT_URL | ❌ Puntava a `http://10.0.10.20:3001/` |
| Certificati SSL | ✅ Solo `git.keruhomelab.com`, gli altri HTTP Only |

### Obiettivi della sessione

1. Avviare il Cloudflare Tunnel e renderlo funzionante da WAN
2. Fixare Forgejo ROOT_URL senza toccare `app.ini`
3. Configurare Split DNS su OPNsense
4. Definire la strategia corretta SSL (tunnel vs LAN)

---

## 2. Analisi firewall OPNsense

### Regole NAT trovate all'inizio

```
rdr on re0 proto tcp from any to (re0) port = https -> <SERVER_NEXUS> port 443
rdr on re0 proto udp from any to (re0) port = 8085  -> <SERVER_NEXUS> port 8085
```

### Anomalie rilevate

**Suricata 8.0.4 installato ma non in esecuzione:**
```bash
pkg info | grep suricata   # → suricata-8.0.4 presente
service suricata status    # → not running
```
ZimaBoard ha 2GB RAM — insufficienti per Suricata in produzione. Lo stato attuale (installato ma spento) è corretto. Da non avviare.

**Gap UDP su VLAN Trusted:**
La regola `pass in quick on vlan0.10 inet proto udp all` con flag `quick` matcha tutto l'UDP dalla VLAN Trusted prima dei blocchi verso IoT/DMZ. TCP è correttamente bloccato, UDP no. Accettabile in un homelab trusted, ma da tenere presente.

### Cosa rimuovere (con tunnel attivo)

| Regola | Dove | Azione |
|---|---|---|
| `rdr tcp 443 → SERVER_NEXUS:443` | Firewall → NAT → Destination NAT | ❌ Da eliminare |
| `pass in tcp → SERVER_NEXUS port 443` | Firewall → Rules → WAN | ❌ Da eliminare |
| `rdr udp 8085 → SERVER_NEXUS:8085` | Firewall → NAT → Destination NAT | ✅ Tieni — Headscale |
| `pass in udp → SERVER_NEXUS port 8085` | Firewall → Rules → WAN | ✅ Tieni — Headscale |

**Motivazione:** il tunnel usa connessioni uscenti. Nessuna porta in ingresso necessaria per i servizi web. Headscale WireGuard richiede ancora il forward UDP 8085 per i client esterni. **Questa pulizia non è ancora stata eseguita — da fare nella prossima sessione.**

---

## 3. Analisi stack Docker Nexus

### Problemi trovati

#### Garage in crash loop
```
homelab-infra-garage-1   Restarting (1) 21 seconds ago
```
**Causa:** `garage.toml` conteneva solo il commento `# Garage S3 — Configurazione base` senza campi obbligatori (`rpc_bind_addr` mancante).

**Fix applicato:**
```bash
docker stop homelab-infra-garage-1
```
Garage è stato fermato. Va configurato correttamente con un `garage.toml` completo prima di riavviarlo (roadmap futura).

#### Homepage su rete Docker sbagliata (falso allarme)
`docker network ls` mostrava una rete `homepage_default` separata. Verificando gli IP, Homepage era correttamente su `homelab-infra_homelab` (NetworkID `516c54bb`). La `homepage_default` era un residuo vecchio.

#### Immich naming con underscore
I container Immich usano `immich_server`, `immich_db`, `immich_ml` (underscore). Tutti gli altri container usano trattino. In NPM il forward hostname deve essere `immich_server` (non `immich-server`).

#### RAID non montato (già fixato nella sessione precedente)
```bash
df -h /mnt/md0   # rispondeva con /dev/sdc2 (SSD root) invece di md0
```
Il RAID era attivo `[2/2] [UU]` ma non montato. Fix già applicato via fstab con UUID. Confermato funzionante in questa sessione.

---

## 4. Deploy Cloudflare Tunnel

### Situazione iniziale

Il `stacks/core/compose.yml` aveva già il servizio `cloudflared` configurato con token valido nel `.env`, ma il container **non era mai stato avviato**.

```yaml
# Già presente — solo da avviare
cloudflared:
  image: cloudflare/cloudflared:latest
  container_name: cloudflared
  restart: unless-stopped
  command: tunnel --no-autoupdate run
  environment:
    - TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
  networks:
    - homelab
```

### Avvio

```bash
cd /opt/homelab-infra
docker compose -f stacks/core/compose.yml up -d cloudflared
sleep 5
docker logs cloudflared --tail=10 2>&1 | grep "Registered"
```

**Output atteso (4 connessioni verso edge Cloudflare Italia):**
```
Registered tunnel connection connIndex=0 ... location=fco01 protocol=quic
Registered tunnel connection connIndex=1 ... location=mxp03 protocol=quic
Registered tunnel connection connIndex=2 ... location=mxp05 protocol=quic
Registered tunnel connection connIndex=3 ... location=fco01 protocol=quic
```

### Configurazione Public Hostnames su Cloudflare

**Percorso:** Zero Trust → Networks → Tunnels → homelab-nexus → Routes

Tutti e 5 i sottodomini configurati su `http://nginx:80`:

| Hostname | Service |
|---|---|
| cloud.keruhomelab.com | http://nginx:80 |
| git.keruhomelab.com | http://nginx:80 |
| photos.keruhomelab.com | http://nginx:80 |
| ntfy.keruhomelab.com | http://nginx:80 |
| vault.keruhomelab.com | http://nginx:80 |

### Record DNS Cloudflare

Dopo configurazione delle Public Hostnames, Cloudflare crea automaticamente i CNAME. Se eliminati manualmente, ricrearli come:

| Type | Name | Content | Proxy |
|---|---|---|---|
| CNAME | git | `<TUNNEL_ID>.cfargotunnel.com` | ✅ Proxied |
| CNAME | cloud | `<TUNNEL_ID>.cfargotunnel.com` | ✅ Proxied |
| CNAME | vault | `<TUNNEL_ID>.cfargotunnel.com` | ✅ Proxied |
| CNAME | photos | `<TUNNEL_ID>.cfargotunnel.com` | ✅ Proxied |
| CNAME | ntfy | `<TUNNEL_ID>.cfargotunnel.com` | ✅ Proxied |

**⚠️ CRITICO:** il `TUNNEL_ID` nei CNAME deve corrispondere esattamente al tunnel in esecuzione su Nexus. Vedi sezione 8 per il bug che ha causato ore di debug.

### Modalità SSL Cloudflare

**Impostazione corretta:** `Flexible`

**Percorso:** keruhomelab.com → SSL/TLS → Overview → Flexible

Con questa modalità:
- Cloudflare gestisce HTTPS tra utente e edge Cloudflare
- Il tunnel porta traffico **HTTP** da Cloudflare a NPM
- NPM non deve terminare SSL per il traffico del tunnel

---

## 5. Fix Forgejo

### Problema

Il container mostrava:
```
AppURL(ROOT_URL): http://10.0.10.20:3001/
```
Causava warning di mismatch, blocco CSRF e link sbagliati in email/webhook.

### Causa (doppia)

1. Le variabili `FORGEJO__server__*` nel compose avevano i valori in **formato markdown** (`[git.keruhomelab.com](http://...)`) invece di testo semplice — introdotto copiando dalla chat che converte automaticamente gli URL.
2. Il compose dichiarava la rete `homelab` senza `external: true` — Docker cercava di crearla invece di usare `homelab-infra_homelab`.
3. Mancava l'**alias esplicito** sulla rete condivisa — NPM non riusciva a trovare Forgejo per hostname.

### Fix — compose scritto via Python (evita la conversione markdown)

```python
python3 - << 'EOF'
domain = "git" + "." + "keruhomelab" + "." + "com"
root_url = "https://" + domain + "/"

lines = [
    "# -- GIT: Forgejo --",
    "services:",
    "  forgejo:",
    "    image: codeberg.org/forgejo/forgejo:10",
    "    restart: unless-stopped",
    "    ports:",
    '      - "${FORGEJO_HTTP_PORT:-3001}:3000"',
    '      - "${FORGEJO_SSH_PORT:-222}:22"',
    "    volumes:",
    "      - ${MEDIA_ROOT}/forgejo/data:/data",
    "    environment:",
    '      USER_UID: "${PUID:-1000}"',
    '      USER_GID: "${PGID:-1000}"',
    f'      FORGEJO__server__ROOT_URL: "{root_url}"',
    f'      FORGEJO__server__DOMAIN: "{domain}"',
    f'      FORGEJO__server__SSH_DOMAIN: "{domain}"',
    '      FORGEJO__server__SSH_PORT: "22"',
    '      FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES: "172.20.0.0/16"',
    '      FORGEJO__security__REVERSE_PROXY_LIMIT: "1"',
    '      FORGEJO__server__REDIRECT_OTHER_PORT: "false"',
    '      FORGEJO__security__COOKIE_SECURE: "true"',
    "    networks:",
    "      homelab:",
    "        aliases:",
    "          - forgejo",
    "",
    "networks:",
    "  homelab:",
    "    external: true",
    "    name: homelab-infra_homelab",
]

with open("/opt/homelab-infra/stacks/git/compose.yml", "w") as f:
    f.write("\n".join(lines) + "\n")
print("OK")
EOF
```

### Avvio

```bash
# Ferma e rimuovi il container vecchio
docker stop homelab-infra-forgejo-1
docker rm homelab-infra-forgejo-1

# Ricrea
docker compose --env-file .env -f stacks/git/compose.yml up -d forgejo

# Verifica
sleep 5 && docker logs git-forgejo-1 --tail=3 | grep "AppURL"
# Output atteso: AppURL(ROOT_URL): https://git.keruhomelab.com/
```

### Regola generale per tutti gli stack separati

Ogni `compose.yml` che partecipa alla rete condivisa deve avere in fondo:

```yaml
networks:
  homelab:
    external: true
    name: homelab-infra_homelab
```

E ogni servizio che deve essere raggiungibile per hostname da NPM:

```yaml
services:
  mioservizio:
    networks:
      homelab:
        aliases:
          - mioservizio
```

**Senza l'alias**, Docker registra il container come `<progetto>-<servizio>-1` ma non come `<servizio>` sulla rete condivisa. NPM non lo trova.

### Il warning ROOT_URL residuo

Accedendo via `http://10.0.10.20:3001` il warning appare ancora — perché bypassa NPM completamente e arriva diretto a Forgejo. **Non è un problema**: nessuno deve usare IP:porta. Il corretto flusso è sempre via dominio:

```
https://git.keruhomelab.com
  → split DNS → 10.0.10.20
  → NPM:443 (con certificato valido)
  → forgejo:3000
  → nessun warning ✅
```

**Fix definitivo:** aggiornare `services.yaml` di Homepage con i domini invece degli IP:porta (da fare nella prossima sessione).

---

## 6. Fix NPM

### Proxy host configurati e funzionanti

| Source | Forward Host | Forward Port | SSL |
|---|---|---|---|
| cloud.keruhomelab.com | nextcloud | 80 | Let's Encrypt |
| git.keruhomelab.com | forgejo | 3000 | Let's Encrypt |
| ntfy.keruhomelab.com | ntfy | 80 | Let's Encrypt |
| photos.keruhomelab.com | immich_server | 2283 | Let's Encrypt |
| vault.keruhomelab.com | vaultwarden | 80 | Let's Encrypt |

**Note:**
- `ntfy` era erroneamente configurato su porta `90` → corretto a `80`
- `immich` deve usare underscore: `immich_server` non `immich-server`

### Headers Advanced — obbligatori su ogni proxy host

In ogni proxy host → Edit → ⚙️ (ingranaggio in alto a destra) → Custom Nginx Configuration:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

Questi header informano Forgejo (e gli altri servizi) che la richiesta originale arrivava via HTTPS anche quando NPM la riceve in HTTP dal tunnel.

### Toggle SSL per ogni proxy host

| Toggle | Stato | Motivazione |
|---|---|---|
| SSL Certificate | Let's Encrypt | Per accesso LAN via split DNS |
| Force SSL | ✅ ON | Il browser da LAN usa HTTPS |
| Trust Upstream Forwarded Proto Headers | ✅ ON | Necessario con Cloudflare Tunnel |
| HTTP/2 Support | ✅ ON | Performance migliori |
| HSTS Enabled | ❌ OFF per ora | Da attivare solo quando tutto è stabile |

### Il loop che ha causato debug prolungato

**Scenario sbagliato 1 — Flexible + Force SSL:**
```
Cloudflare → tunnel HTTP → NPM:80 → 301 HTTPS → Cloudflare edge → 301 loop ❌
```

**Scenario sbagliato 2 — Full + tunnel HTTPS nginx:443:**
```
cloudflared → https://nginx:443 → TLS handshake con SNI "nginx"
NPM non ha cert per "nginx" → tlsv1 unrecognized name → 1033 ❌
```

**Configurazione corretta finale:**
```
Cloudflare SSL:  Flexible
Tunnel service:  http://nginx:80  (HTTP, non HTTPS)
NPM:             Force SSL attivo, certificato Let's Encrypt
```

**Perché funziona:**
- Il tunnel porta HTTP a NPM porta 80 — nessun loop perché NPM non fa redirect quando la richiesta arriva sulla porta 80 da cloudflared (passa direttamente al container)
- Da LAN: split DNS → NPM porta 443 → certificato valido → HTTPS ✅
- Da WAN: Cloudflare gestisce HTTPS → tunnel HTTP → NPM → container ✅

---

## 7. Split DNS Unbound

### Configurazione

**Percorso OPNsense:** Services → Unbound DNS → Overrides → Host Overrides

| Host | Domain | Type | IP |
|---|---|---|---|
| git | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| cloud | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| vault | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| photos | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| ntfy | keruhomelab.com | A (IPv4) | 10.0.10.20 |

Dopo aver salvato → **Apply**.

### Verifica

```bash
nslookup git.keruhomelab.com 10.0.10.1
# Deve rispondere: 10.0.10.20

dig git.keruhomelab.com @1.1.1.1 +short
# Deve rispondere: IP Cloudflare (188.114.x.x)
```

### Flusso traffico con split DNS

```
Da LAN (VLAN Trusted):
  https://git.keruhomelab.com
  → DNS: OPNsense Unbound → 10.0.10.20 (non esce da LAN)
  → NPM:443 con certificato Let's Encrypt valido
  → forgejo:3000 ✅

Da WAN (4G, Internet):
  https://git.keruhomelab.com
  → DNS: Cloudflare → 188.114.96.7 (edge Cloudflare)
  → Cloudflare edge → tunnel QUIC → cloudflared su Nexus
  → NPM:80 → forgejo:3000 ✅
```

---

## 8. Il bug che bloccava tutto — CNAME tunnel ID sbagliato

### Sintomo

Tunnel attivo, NPM funzionante, DNS risolto — ma da 4G errore **1033** persistente e **zero traffico** nei log di cloudflared.

```bash
docker logs cloudflared -f --tail=1
# Nessuna riga nuova quando accedevi dal telefono
```

### Diagnosi

Il Tunnel ID reale estratto dal token nel `.env`:

```python
python3 - << 'EOF'
import base64, json
token = open('/opt/homelab-infra/.env').read()
token = [l.split('=',1)[1].strip() for l in token.split('\n') if 'TUNNEL_TOKEN' in l][0]
decoded = json.loads(base64.b64decode(token + '=='))
print("Tunnel ID:", decoded.get('t'))
EOF
# Output: Tunnel ID: 8d0a...142b2c
```

I CNAME DNS su Cloudflare puntavano a:
```
8e3848b4-f329-4dcf-9e81....cfargotunnel.com
```

**Due UUID diversi.** I CNAME erano stati creati manualmente in precedenza puntando a un tunnel sbagliato (o a una versione precedente del tunnel). Cloudflare riceveva le richieste, le mandava al tunnel `8e3848b4` che non era in esecuzione → 1033.

Il tunnel `8d0a54fa` (quello realmente in esecuzione su Nexus) non riceveva nulla.

### Fix

Su **Cloudflare → keruhomelab.com → DNS → Records**: eliminare i 5 CNAME errati e ricrearli puntando al tunnel corretto:

```
git    CNAME  8d0a...142b2c.cfargotunnel.com  [Proxied]
cloud  CNAME  8d0a...142b2c.cfargotunnel.com  [Proxied]
vault  CNAME  8d0a...142b2c.cfargotunnel.com  [Proxied]
photos CNAME  8d0a...142b2c.cfargotunnel.com  [Proxied]
ntfy   CNAME  8d0a...142b2c.cfargotunnel.com  [Proxied]
```

**Alternativa più sicura:** non creare mai i CNAME manualmente. Configurare le Public Hostnames dal pannello Zero Trust → Tunnels — Cloudflare li crea automaticamente puntando al tunnel corretto.

### Risultato

Dopo la correzione dei CNAME, dal telefono in 4G:
```
https://git.keruhomelab.com → ✅ Forgejo carica correttamente
```

---

## 9. Configurazione finale funzionante

### Stato infrastruttura

| Componente | Stato | Note |
|---|---|---|
| Docker stack (29 container) | ✅ Online | Stabili |
| RAID md0 | ✅ [2/2] UU | 3.6TB disponibili |
| Cloudflare Tunnel | ✅ Attivo | 4 connessioni QUIC verso Italia |
| DNS CNAME Cloudflare | ✅ Corretti | Puntano a `8d0a54fa...cfargotunnel.com` |
| Split DNS Unbound | ✅ 5 host override | Traffic LAN non esce |
| Forgejo ROOT_URL | ✅ Fixato | `https://git.keruhomelab.com/` |
| Forgejo da 4G | ✅ Funzionante | Via tunnel Cloudflare |
| Forgejo da LAN | ✅ Funzionante | Via split DNS + NPM + certificato |
| NPM headers | ✅ Configurati | X-Forwarded-Proto su tutti i proxy host |
| SSL tutti i proxy host | ✅ Let's Encrypt | Force SSL + Trust Upstream attivi |

### Architettura traffico finale

```
┌─────────────────────────────────────────────────────────┐
│  ACCESSO DA WAN (4G / Internet)                         │
│                                                         │
│  Utente → HTTPS → Cloudflare Edge                       │
│                       │                                 │
│                   SSL Flexible                          │
│                       │                                 │
│                   Tunnel QUIC                           │
│                       │                                 │
│              cloudflared (172.20.0.19)                  │
│                       │ HTTP                            │
│              nginx:80 (NPM)                             │
│                       │                                 │
│         ┌─────────────┼─────────────┐                   │
│      forgejo       nextcloud    vaultwarden             │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  ACCESSO DA LAN (VLAN Trusted 10.0.10.0/24)             │
│                                                         │
│  Utente → https://git.keruhomelab.com                   │
│                       │                                 │
│         OPNsense Unbound → 10.0.10.20                   │
│                       │                                 │
│              nginx:443 (NPM)                            │
│              Let's Encrypt cert valido                  │
│                       │                                 │
│         ┌─────────────┼─────────────┐                   │
│      forgejo       nextcloud    vaultwarden             │
└─────────────────────────────────────────────────────────┘
```

---

## 10. Roadmap prossima sessione

### Priorità Alta 🔴

**1 — Aggiornare Homepage services.yaml**

```bash
nano /opt/homelab-infra/data/homepage/config/services.yaml
```

Sostituire tutti gli `href: http://10.0.10.20:PORTA` con i domini pubblici:

```yaml
- Forgejo:
    href: https://git.keruhomelab.com    # era http://10.0.10.20:3001
- Nextcloud:
    href: https://cloud.keruhomelab.com  # era http://10.0.10.20:8088
- Vaultwarden:
    href: https://vault.keruhomelab.com  # era http://10.0.10.20:8087
- Immich:
    href: https://photos.keruhomelab.com # era http://10.0.10.20:2283
- ntfy:
    href: https://ntfy.keruhomelab.com   # era http://10.0.10.20:8091
```

I servizi senza dominio pubblico (Portainer, Netdata, Grafana, ecc.) restano con IP:porta — solo uso interno.

**2 — Rimuovere NAT 443 da OPNsense**

```
Firewall → NAT → Destination NAT → elimina TCP 443 → SERVER_NEXUS
Firewall → Rules → WAN → elimina pass TCP 443
```

Verifica:
```bash
ssh root@10.0.10.1
pfctl -sn | grep rdr
# Deve restare solo: rdr udp 8085 → SERVER_NEXUS
```

### Priorità Media 🟠

**3 — Forgejo compose — variabili reverse proxy**

Il compose attuale funziona ma mancano ancora le variabili `REVERSE_PROXY_TRUSTED_PROXIES` per prevenire il blocco CSRF quando gli AI agent accedono via HTTP interno. Rifare il compose completo con Python (già scritto nella sezione 5).

**4 — Headscale VPN — configurazione client**

```bash
# Su Nexus — crea utente admin
docker exec headscale headscale users create admin

# Genera auth key (scade dopo 1h)
docker exec headscale headscale preauthkeys create --user admin --reusable --expiration 1h

# Su laptop — installa Tailscale e connetti
tailscale up --login-server https://headscale.keruhomelab.com --authkey <key>
```

Headscale è già up e funzionante come container — mancano solo i client.

**5 — Garage S3 — configurazione completa**

```bash
# Genera segreto RPC
RPC_SECRET=$(openssl rand -hex 32)

# Crea garage.toml su RAID
mkdir -p /mnt/md0/homelab_data/garage/{meta,data}
cat > /mnt/md0/homelab_data/garage/garage.toml << TOML
metadata_dir = "/var/lib/garage/meta"
data_dir     = "/var/lib/garage/data"
db_engine    = "lmdb"
replication_factor = 1

[rpc_bind_addr]
rpc_bind_addr = "[::]:3901"
rpc_secret    = "${RPC_SECRET}"

[s3_api]
api_bind_addr = "[::]:3900"
root_domain   = ".s3.keruhomelab.com"
s3_region     = "garage"

[admin]
api_bind_addr = "[::]:3903"
TOML

# Avvia Garage
docker compose --env-file .env -f stacks/storage/compose.yml up -d garage

# Inizializza nodo (dopo avvio)
NODE_ID=$(docker exec homelab-infra-garage-1 garage status | grep "NO ROLE" | awk '{print $1}')
docker exec homelab-infra-garage-1 garage layout assign $NODE_ID -z local -c 500G
docker exec homelab-infra-garage-1 garage layout apply --version 1
```

### Priorità Bassa 🟢

**6 — Kopia backup policy**

Configurare snapshot automatici dei volumi Docker verso Garage S3 (dipende da Garage funzionante).

**7 — Monitoring completo**

Grafana e Loki sono up ma senza dashboard configurate. Importare dashboard Netdata + Docker + OPNsense.

**8 — Pulizia SSD**

```bash
sudo rm -rf /mnt/md0_finto   # residuo della migrazione dati
```

---

## 11. Lezioni apprese

### 1 — CNAME DNS devono puntare al Tunnel ID corretto

Il Tunnel ID da usare nei record CNAME è quello nel token `.env`, non un UUID qualsiasi. Per estrarlo:

```python
python3 - << 'EOF'
import base64, json
token = open('/opt/homelab-infra/.env').read()
token = [l.split('=',1)[1].strip() for l in token.split('\n') if 'TUNNEL_TOKEN' in l][0]
decoded = json.loads(base64.b64decode(token + '=='))
print("Tunnel ID:", decoded.get('t'))
EOF
```

**Regola pratica:** non creare mai i CNAME manualmente. Configurare le Public Hostnames dal pannello Zero Trust → Tunnels — Cloudflare li crea e gestisce automaticamente.

### 2 — Cloudflare Tunnel usa HTTP interno, non HTTPS

Con modalità SSL `Flexible`:
- Cloudflare → edge: HTTPS ✅
- Tunnel interno → NPM: **HTTP** (non HTTPS)
- NPM deve ricevere HTTP da cloudflared su porta 80

Configurare il tunnel su `https://nginx:443` causa un errore TLS SNI perché cloudflared cerca di fare handshake TLS con hostname `nginx` che non ha certificato.

La combinazione corretta:
```
Cloudflare SSL:  Flexible
Tunnel route:    http://nginx:80
NPM porta 80:    riceve dal tunnel, passa al container
NPM porta 443:   riceve dalla LAN (split DNS), risponde con certificato
Force SSL:       ON (il browser da LAN usa HTTPS, non impatta il tunnel)
```

### 3 — Alias Docker espliciti per rete condivisa

Quando uno stack ha nome diverso da `homelab-infra`, i container non vengono registrati con il nome del servizio sulla rete condivisa. NPM non li trova per hostname.

```yaml
# OBBLIGATORIO in ogni stack secondario
services:
  forgejo:
    networks:
      homelab:
        aliases:
          - forgejo  # questo è l'hostname che NPM usa

networks:
  homelab:
    external: true
    name: homelab-infra_homelab
```

### 4 — Scrivere YAML con URL via Python

La chat converte automaticamente gli URL in markdown (`[testo](url)`). Qualsiasi compose YAML con URL nei valori va scritto con Python usando concatenazione di stringhe, non copiando direttamente dalla chat.

```python
domain = "git" + "." + "keruhomelab" + "." + "com"
# mai: domain = "git.keruhomelab.com"  ← la chat lo converte
```

### 5 — `http://IP:PORTA` bypassa NPM completamente

Accedere a `http://10.0.10.20:3001` va diretto a Forgejo, non passa per NPM. Forgejo vede una richiesta HTTP ma si aspetta HTTPS (ROOT_URL è https) → warning di mismatch.

Non è un bug da fixare su Forgejo — è il comportamento corretto. La soluzione è usare sempre il dominio, non IP:porta. Aggiornare Homepage con i domini risolve definitivamente.

### 6 — Ordine di debug per errore 1033

```
1. Il tunnel è healthy in Zero Trust? (Connessioni registrate nei log)
2. cloudflared riceve traffico? (docker logs cloudflared -f mentre accedi)
3. I CNAME DNS puntano al tunnel ID corretto? (verifica con il decoder Python)
4. NPM risponde in HTTP? (curl -H "Host: dominio" http://10.0.10.20:80)
5. Ci sono Access Policy in Zero Trust che bloccano?
```

Se il punto 2 non mostra traffico, il problema è prima del tunnel (DNS o Access Policy). Se lo mostra ma c'è errore, il problema è tra tunnel e NPM.

---

## 12. Riferimento rapido

### Docker — comandi frequenti

```bash
cd /opt/homelab-infra

# Stack completo
make up                          # CPU
make up-gpu                      # GPU
make down                        # Ferma tutto
make ps                          # Stato

# Singolo stack (sempre con --env-file)
docker compose --env-file .env -f stacks/git/compose.yml up -d --force-recreate forgejo

# Logs
docker logs git-forgejo-1 --tail=20
docker logs cloudflared -f --tail=5

# Stato rete container
docker network inspect homelab-infra_homelab | grep -A5 "forgejo\|nginx\|cloud"

# Test raggiungibilità da NPM
docker exec homelab-infra-nginx-1 curl -s -o /dev/null -w "%{http_code}" http://forgejo:3000
```

### Diagnostica tunnel e SSL

```bash
# NPM risponde HTTP puro (per tunnel Cloudflare)
curl -s -o /dev/null -w "%{http_code}" -H "Host: git.keruhomelab.com" http://10.0.10.20:80
# → 200 (non 301)

# NPM risponde HTTPS da LAN (con split DNS)
curl -sk --resolve "git.keruhomelab.com:443:10.0.10.20" https://git.keruhomelab.com -o /dev/null -w "%{http_code}"
# → 200

# DNS locale (split DNS attivo)
dig git.keruhomelab.com @10.0.10.1 +short
# → 10.0.10.20

# DNS esterno (Cloudflare)
dig git.keruhomelab.com @1.1.1.1 +short
# → 188.114.x.x

# Tunnel ID dal token
python3 -c "
import base64, json, re
env = open('.env').read()
t = re.search(r'TUNNEL_TOKEN=(.+)', env).group(1).strip()
print(json.loads(base64.b64decode(t+'=='))['t'])
"
```

### OPNsense

```bash
ssh root@10.0.10.1

pfctl -sn | grep rdr           # NAT attivi
pfctl -sr | grep "on re0"      # Regole WAN
configctl unbound reconfigure  # Ricarica DNS dopo modifica host override
```

### Cloudflare Dashboard — percorsi

```
DNS Records:       keruhomelab.com → DNS → Records
Tunnel Routes:     Zero Trust → Networks → Tunnels → homelab-nexus → Routes
SSL Mode:          keruhomelab.com → SSL/TLS → Overview (impostare Flexible)
WAF Custom Rules:  keruhomelab.com → Security → WAF → Custom Rules
```

---

*Sessione: 5 Maggio 2026*
*Risultato principale: accesso da WAN (4G) funzionante su tutti i sottodomini tramite Cloudflare Tunnel*
*Tunnel ID attivo: `8d0a...142b2c`*
*Stack: ZimaBoard OPNsense 26.1.6 · AMD Nexus Ubuntu 24.04 · Torre Intel Proxmox 9*
