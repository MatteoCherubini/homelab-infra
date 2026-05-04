# Homelab keruhomelab.com — Resoconto Sessione Completa
*Data: 4 Maggio 2026 · Punto di partenza: fase2-punto-zero.md*

---

## Indice

1. [Punto di partenza](#1-punto-di-partenza)
2. [Analisi OPNsense — Firewall](#2-analisi-opnsense--firewall)
3. [Analisi Nexus — Stack Docker](#3-analisi-nexus--stack-docker)
4. [Problema critico — RAID non montato](#4-problema-critico--raid-non-montato)
5. [Cloudflare Tunnel — Deploy](#5-cloudflare-tunnel--deploy)
6. [Fix Forgejo — ROOT_URL e rete Docker](#6-fix-forgejo--root_url-e-rete-docker)
7. [Fix NPM — SSL e routing](#7-fix-npm--ssl-e-routing)
8. [Split DNS — Unbound OPNsense](#8-split-dns--unbound-opnsense)
9. [Regole da rimuovere su OPNsense](#9-regole-da-rimuovere-su-opnsense)
10. [Stato finale e prossimi passi](#10-stato-finale-e-prossimi-passi)
11. [Lezioni apprese](#11-lezioni-apprese)
12. [Riferimento rapido comandi](#12-riferimento-rapido-comandi)

---

## 1. Punto di partenza

### Infrastruttura

| Nodo | Ruolo | IP |
|---|---|---|
| ZimaBoard | OPNsense 26.1.6 (firewall/router) | 10.0.10.1 |
| Nexus (AMD) | Ubuntu Server 24.04, Docker | 10.0.10.20 |
| Torre Intel | Proxmox VE 9 (hypervisor) | 10.0.10.10 |
| Laptop Dell | Client principale (TRUSTED VLAN) | 10.0.10.81 |

### Cosa era già fatto (dal punto zero)

- ✅ VLAN segmentate (TRUSTED 10.0.10.0/24, IOT 10.0.20.0/24, DMZ block-all)
- ✅ SSH hardening con chiavi Ed25519 su tutti i nodi
- ✅ Docker migrato a stack modulari in `/opt/homelab-infra/`
- ✅ Cloudflare DDNS attivo su `keruhomelab.com`
- ✅ RAID /dev/md0 montato su `/mnt/md0` e dati migrati
- ✅ 29 container Docker attivi su Nexus

### Cosa mancava

- ❌ Cloudflare Tunnel (container cloudflared mai avviato)
- ❌ Forgejo ROOT_URL puntava a `http://10.0.10.20:3001/`
- ❌ Split DNS Unbound non configurato
- ❌ Record DNS Cloudflare assenti (erano stati eliminati)
- ❌ Certificato SSL wildcard per accesso LAN

---

## 2. Analisi OPNsense — Firewall

### Regole NAT attive all'inizio della sessione

```
rdr on re0 proto tcp from any to (re0) port = https -> <SERVER_NEXUS> port 443
rdr on re0 proto udp from any to (re0) port = 8085  -> <SERVER_NEXUS> port 8085
```

### Regole WAN pass corrispondenti

```
pass in quick on re0 proto tcp from any to <SERVER_NEXUS> port = https
pass in quick on re0 proto udp from any to <SERVER_NEXUS> port = 8085
```

### Cosa rimuovere (con tunnel attivo)

| Regola | Dove | Azione |
|---|---|---|
| `rdr tcp 443 → SERVER_NEXUS:443` | Firewall → NAT → Destination NAT | ❌ Da eliminare |
| `pass in tcp → SERVER_NEXUS port 443` | Firewall → Rules → WAN | ❌ Da eliminare |
| `rdr udp 8085 → SERVER_NEXUS:8085` | Firewall → NAT → Destination NAT | ✅ Tieni — Headscale |
| `pass in udp → SERVER_NEXUS port 8085` | Firewall → Rules → WAN | ✅ Tieni — Headscale |

**Motivazione:** il Cloudflare Tunnel usa connessioni **uscenti** da Nexus verso Cloudflare. Nessuna porta in ingresso necessaria per i servizi web. Headscale invece richiede ancora il forward UDP 8085 per i client WireGuard esterni.

### Anomalia trovata — Suricata installato

```bash
pkg info | grep suricata
# suricata-8.0.4 — presente ma non in esecuzione
```

Suricata è installato ma `service suricata status` → `not running`. Non consuma RAM. Da mantenere spento — ZimaBoard ha solo 2GB RAM, insufficienti per IDS/IPS in produzione.

### Anomalia trovata — UDP broad su VLAN10

Nel ruleset PF è presente:
```
pass in quick on vlan0.10 inet proto udp all
```
Con flag `quick`, questa regola matcha **tutto l'UDP dalla VLAN Trusted prima dei blocchi verso IoT/DMZ**. In pratica UDP da TRUSTED → IoT non è bloccato. Accettabile in un homelab trusted, ma tecnicamente un gap da tenere presente.

---

## 3. Analisi Nexus — Stack Docker

### Stato container all'analisi

- **29 container Up** su 30 — tutti stabili da 2+ giorni
- **1 container in crash loop** — `homelab-infra-garage-1`
- **GPU attiva** — `ollama-gpu-1` con profilo GPU

### Garage — crash loop risolto

**Causa:** il file `garage.toml` conteneva solo il commento `# Garage S3 — Configurazione base` senza campi obbligatori (mancava `rpc_bind_addr` e altri).

**Log:**
```
Error: TOML decode error: missing field `rpc_bind_addr`
```

**Fix applicato:**
```bash
docker stop homelab-infra-garage-1
```

Garage va configurato correttamente con un `garage.toml` completo prima di riavviarlo (fase Kopia/S3, roadmap futura).

### Immich — naming diverso

I container Immich usano il prefisso `immich_` (underscore) invece di `homelab-infra-*`. Il working dir è correttamente `/opt/homelab-infra`. Il compose Immich usa `name: immich` esplicito — comportamento atteso, nessun problema funzionale.

**Importante per NPM:** il forward hostname deve usare `immich_server` (underscore), non `immich-server` (trattino).

### Rete Docker — struttura

| Rete | ID | Uso |
|---|---|---|
| `homelab-infra_homelab` | e63d5093 | Rete condivisa di tutti gli stack |
| `homepage_default` | 665284ac | Residuo vecchio — non in uso attivo |
| `bridge` | 1a95cfcef | Default Docker |

---

## 4. Problema critico — RAID non montato

### Diagnosi

```bash
df -h /mnt/md0
# Filesystem: /dev/sdc2  468G  89G  355G  21%  /
# Rispondeva con il filesystem ROOT (SSD), non con md0
```

Il RAID era attivo (`[2/2] [UU]`) ma non montato — i dati venivano scritti sull'SSD di sistema.

### Fix applicato (dal resoconto punto zero)

1. Identificato UUID del RAID: `acd20205...`
2. Modificato `/etc/fstab` per mount persistente
3. Eseguito `systemctl daemon-reload && mount -a`
4. Migrati i dati dalla directory temporanea SSD al RAID

### Stato post-fix

```bash
cat /proc/mdstat
# md0 : active raid1 sda[0] sdb[1]
#       3906886464 blocks super 1.2 [2/2] [UU]
#       bitmap: 0/30 pages [0KB], 65536KB chunk

ls /mnt/md0/homelab_data/
# forgejo  (e altri servizi)
```

**Nota:** eseguire `sudo rm -rf /mnt/md0_finto` per pulire i dati residui sull'SSD una volta verificata l'integrità su RAID.

---

## 5. Cloudflare Tunnel — Deploy

### Perché il tunnel

Tiscali blocca le porte 80 e 443 inbound a livello ISP. Il Cloudflare Tunnel bypassa completamente questa limitazione usando connessioni **uscenti** da Nexus.

```
Utente → Cloudflare Edge → Tunnel cifrato → cloudflared su Nexus → NPM → Container
```

### Situazione iniziale

Il compose `stacks/core/compose.yml` aveva già il servizio `cloudflared` configurato con il token, ma il container non era mai stato avviato.

```yaml
# Già presente in stacks/core/compose.yml
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
```

### Verifica connessioni

```bash
docker logs cloudflared --tail=20 2>&1 | grep "Registered"
# 4 connessioni attive verso Milano (mxp02, mxp05, mxp06) e Roma (fco01)
```

Output atteso:
```
Registered tunnel connection connIndex=0 ... location=fco01 protocol=quic
Registered tunnel connection connIndex=1 ... location=mxp03 protocol=quic
Registered tunnel connection connIndex=2 ... location=mxp05 protocol=quic
Registered tunnel connection connIndex=3 ... location=fco01 protocol=quic
```

### Configurazione Public Hostnames su Cloudflare

**Percorso:** Zero Trust → Networks → Tunnels → homelab-nexus → Routes

| Destination | Type | Service |
|---|---|---|
| cloud.keruhomelab.com | Published application | http://nginx:80 |
| git.keruhomelab.com | Published application | http://nginx:80 |
| photos.keruhomelab.com | Published application | http://nginx:80 |
| ntfy.keruhomelab.com | Published application | http://nginx:80 |
| vault.keruhomelab.com | Published application | http://nginx:80 |

Tutti puntano a `http://nginx:80` — NPM fa da reverse proxy verso i singoli container.

### Record DNS Cloudflare

I record DNS vanno creati come CNAME Proxied (non record A):

| Type | Name | Content | Proxy |
|---|---|---|---|
| CNAME | git | `<tunnel-id>.cfargotunnel.com` | ✅ Proxied |
| CNAME | cloud | `<tunnel-id>.cfargotunnel.com` | ✅ Proxied |
| CNAME | vault | `<tunnel-id>.cfargotunnel.com` | ✅ Proxied |
| CNAME | photos | `<tunnel-id>.cfargotunnel.com` | ✅ Proxied |
| CNAME | ntfy | `<tunnel-id>.cfargotunnel.com` | ✅ Proxied |

**Nota:** Cloudflare crea automaticamente questi CNAME quando configuri le Public Hostnames dal tunnel. Se li hai eliminati manualmente (come in questa sessione), vanno ricreati a mano o ri-configurando le hostnames dal tunnel.

### Impostazione SSL/TLS Cloudflare

**Percorso:** keruhomelab.com → SSL/TLS → Overview

Impostare su **Flexible**:
- Il tunnel porta traffico HTTP da Cloudflare a Nexus
- Cloudflare gestisce HTTPS verso gli utenti
- NPM non deve terminare SSL per il traffico dal tunnel

---

## 6. Fix Forgejo — ROOT_URL e rete Docker

### Problema

Forgejo mostrava il warning:
```
AppURL(ROOT_URL): http://10.0.10.20:3001/
```

Causava link sbagliati in email, webhook, OAuth2 e SSH clone URLs.

### Causa

Il `stacks/git/compose.yml` aveva due problemi:
1. **Mancava la dichiarazione della rete** come `external: true`
2. **I domini erano in formato markdown** (`[git.keruhomelab.com](http://...)`) invece di testo semplice — introdotto copiando dalla chat che converte automaticamente gli URL

### Soluzione — scrittura del compose via Python

Per evitare la conversione markdown, il file va scritto con Python:

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

### Riavvio con env-file esplicito

```bash
# Ferma e rimuovi il container vecchio
docker stop homelab-infra-forgejo-1
docker rm homelab-infra-forgejo-1

# Ricrea con il compose corretto
docker compose --env-file .env -f stacks/git/compose.yml up -d forgejo

# Verifica ROOT_URL
sleep 5 && docker logs git-forgejo-1 --tail=3 | grep "AppURL"
# Output atteso: AppURL(ROOT_URL): https://git.keruhomelab.com/
```

### Regola fondamentale per tutti gli stack separati

**Ogni stack file che usa la rete condivisa deve:**

```yaml
networks:
  homelab:
    external: true
    name: homelab-infra_homelab  # nome esatto della rete creata da make up
```

**E ogni servizio che deve essere raggiungibile per hostname deve avere l'alias esplicito:**

```yaml
services:
  mioservizio:
    networks:
      homelab:
        aliases:
          - mioservizio  # questo permette a NPM di usare http://mioservizio:porta
```

Senza l'alias, Docker non registra il container con quel nome sulla rete condivisa quando il progetto Compose ha un nome diverso da `homelab-infra`.

### Perché il problema

Il Makefile lancia `docker compose` dalla root di `/opt/homelab-infra` che include tutti gli stack tramite un compose root. In questo contesto la rete si chiama `homelab-infra_homelab` e i servizi vengono registrati con il loro nome.

Quando si lancia un singolo stack con `-f stacks/git/compose.yml`, il progetto si chiama `git` e Docker cerca una rete `git_homelab` che non esiste — o tenta di creare `homelab` come rete nuova invece di usare quella esistente.

La dichiarazione `external: true` con `name:` forza Docker a usare la rete già esistente.

---

## 7. Fix NPM — SSL e routing

### Proxy Host configurati

| Source | Destination | SSL |
|---|---|---|
| cloud.keruhomelab.com | http://nextcloud:80 | HTTP Only |
| git.keruhomelab.com | http://forgejo:3000 | Let's Encrypt (da sostituire) |
| ntfy.keruhomelab.com | http://ntfy:80 | HTTP Only |
| photos.keruhomelab.com | http://immich_server:2283 | HTTP Only |
| vault.keruhomelab.com | http://vaultwarden:80 | HTTP Only |

### Correzioni applicate

**ntfy porta errata:** era configurato su porta `90` invece di `80`. Corretto in NPM.

**Immich hostname:** il container si chiama `immich_server` con underscore. NPM deve usare `immich_server` (non `immich-server` con trattino).

### Problema Force SSL — 301 loop

**Sintomo:** errore 1033 da Cloudflare.

**Causa:** NPM aveva "Force SSL" attivo su `git.keruhomelab.com`. Cloudflare Tunnel invia HTTP a `nginx:80`, NPM rispondeva con `301 → https://git.keruhomelab.com`, Cloudflare non riusciva a seguire il redirect verso se stesso.

**Diagnosi:**
```bash
curl -v -H "Host: git.keruhomelab.com" http://10.0.10.20:80 2>&1 | grep "< HTTP\|Location"
# HTTP/1.1 301 Moved Permanently
# Location: https://git.keruhomelab.com/
```

**Fix:** su NPM → Edit proxy host → SSL → rimuovere "Force SSL" e impostare SSL a None.

**Dopo il fix:**
```bash
curl -v -H "Host: git.keruhomelab.com" http://10.0.10.20:80 2>&1 | grep "< HTTP"
# HTTP/1.1 200 OK
```

### Problema accesso LAN via HTTPS

Con SSL rimosso da NPM, l'accesso interno (`https://git.keruhomelab.com`) fallisce perché il browser usa HTTPS (HSTS cached) ma NPM non ha più il certificato su porta 443.

**Soluzione definitiva — certificato wildcard:**

Su NPM → SSL Certificates → Add SSL Certificate → Let's Encrypt:
- Domain: `*.keruhomelab.com`
- Use DNS Challenge: ✅
- DNS Provider: Cloudflare
- API Token: token Cloudflare con permessi DNS

Questo emette un unico certificato wildcard da assegnare a tutti i proxy host. Il vantaggio rispetto a un certificato per singolo dominio:
- Una sola operazione invece di 5
- Nessuna scadenza da gestire separatamente
- Funziona per tutti i sottodomini futuri

**Assegnazione:** dopo l'emissione, modifica ogni proxy host → SSL → seleziona il certificato wildcard (non Let's Encrypt request, ma usa il certificato già emesso).

---

## 8. Split DNS — Unbound OPNsense

### Problema senza split DNS

Senza host override, dalla rete interna `git.keruhomelab.com` risolve verso gli IP Cloudflare (`188.114.96.7`). Il traffico esce dalla LAN, passa per Cloudflare, rientra via tunnel — inaffidabile e lento.

### Configurazione

**Percorso:** Services → Unbound DNS → Overrides → Host Overrides

| Enabled | Host | Domain | Type | IP |
|---|---|---|---|---|
| ✅ | git | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| ✅ | cloud | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| ✅ | vault | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| ✅ | photos | keruhomelab.com | A (IPv4) | 10.0.10.20 |
| ✅ | ntfy | keruhomelab.com | A (IPv4) | 10.0.10.20 |

Dopo aver salvato → cliccare **Apply**.

### Verifica

```bash
# Da laptop interno
nslookup git.keruhomelab.com 10.0.10.1
# Server: 10.0.10.1
# Address: 10.0.10.20  ← deve essere l'IP interno, non Cloudflare

# Da terminale
dig git.keruhomelab.com @10.0.10.1 +short
# 10.0.10.20
```

### Flusso traffico con split DNS attivo

```
Da LAN:
  browser → git.keruhomelab.com
          → DNS risolve 10.0.10.20 (OPNsense Unbound)
          → NPM su Nexus (HTTP o HTTPS con certificato)
          → Forgejo
          (traffico non esce mai da LAN)

Da Internet/4G:
  browser → git.keruhomelab.com
          → DNS risolve IP Cloudflare (188.114.96.x)
          → Cloudflare Edge
          → Tunnel → cloudflared su Nexus
          → NPM su Nexus (HTTP)
          → Forgejo
```

---

## 9. Regole da rimuovere su OPNsense

Con il tunnel attivo, le regole NAT per 80/443 non servono più. Rimuoverle riduce la superficie di attacco.

### Da rimuovere — GUI OPNsense

**Firewall → NAT → Destination NAT:**
```
TCP / WAN / any → SERVER_NEXUS:443  ← ELIMINA
```

**Firewall → Rules → WAN:**
```
pass TCP / any → SERVER_NEXUS / port 443  ← ELIMINA
```

### Da mantenere

```
UDP / WAN / any → SERVER_NEXUS:8085  ← TIENI (Headscale WireGuard)
pass UDP / any → SERVER_NEXUS / port 8085  ← TIENI
```

### Verifica dopo rimozione

```bash
ssh root@10.0.10.1
pfctl -sn | grep rdr
# Deve restare solo:
# rdr on re0 proto udp from any to (re0) port = 8085 -> <SERVER_NEXUS> port 8085
```

---

## 10. Stato finale e prossimi passi

### Cosa funziona ✅

| Componente | Stato | Note |
|---|---|---|
| Docker stack (29 container) | ✅ Online | Tutti up e stabili |
| RAID /dev/md0 | ✅ Montato | [2/2] UU, dati migrati |
| Cloudflare Tunnel | ✅ Attivo | 4 connessioni QUIC |
| DNS Cloudflare | ✅ Configurato | 5 CNAME Proxied |
| Split DNS Unbound | ✅ Configurato | 5 host override |
| Forgejo ROOT_URL | ✅ Fixato | https://git.keruhomelab.com/ |
| NPM proxy host | ✅ Configurati | 5 servizi online |
| SSH hardening | ✅ Completato | Ed25519, no password auth |

### Cosa manca ❌

| Componente | Problema | Priorità |
|---|---|---|
| Certificato wildcard NPM | Accesso LAN via HTTPS fallisce senza cert | 🔴 Alta |
| NAT 443 OPNsense | Da rimuovere (non urgente, ma da fare) | 🟠 Media |
| Headscale VPN | Client non configurati | 🟠 Media |
| Garage S3 | Crash loop — manca garage.toml | 🟢 Bassa |
| Kopia backup | Policy non definita | 🟢 Bassa |
| Homepage services.yaml | Link IP:porta invece di domini | 🟢 Bassa |

### Roadmap prossima sessione

```
1. Certificato wildcard *.keruhomelab.com su NPM (DNS-01 Cloudflare)
   → Assegnare a tutti i proxy host
   → Verificare HTTPS da LAN e da 4G

2. Rimozione NAT 443 da OPNsense
   → Firewall → NAT → Destination NAT → elimina TCP 443
   → Firewall → Rules → WAN → elimina pass TCP 443

3. Headscale — configurazione client
   → Creare utente admin su Headscale
   → Generare auth key
   → Installare Tailscale client su laptop e mobile
   → Testare accesso SSH a git su 222 da fuori casa

4. Homepage services.yaml — aggiornare link
   → Sostituire http://10.0.10.20:PORTA con https://dominio.keruhomelab.com
   → Funzionerà sia da LAN (split DNS) che da fuori (tunnel)

5. Garage S3 — configurazione
   → Creare garage.toml completo
   → Inizializzare nodo
   → Creare bucket per Kopia

6. Kopia backup policy
   → Configurare snapshot automatici volumi Docker
   → Target: Garage S3 o HDD esterno
```

---

## 11. Lezioni apprese

### 1 — Rete Docker con stack separati

Quando si lancia un singolo `compose.yml` con `-f` invece del compose root, Docker usa il nome della directory come nome progetto. La rete `homelab` dichiarata senza `external: true` viene creata come rete nuova invece di usare `homelab-infra_homelab`.

**Regola:** ogni stack separato che partecipa alla rete condivisa deve dichiarare:
```yaml
networks:
  homelab:
    external: true
    name: homelab-infra_homelab
```

### 2 — Alias di rete Docker obbligatori

Senza alias espliciti, un container avviato da un progetto con nome diverso (`git`) non è raggiungibile per hostname sulla rete condivisa. NPM cerca `forgejo` ma trova solo `git-forgejo-1`.

**Fix:**
```yaml
networks:
  homelab:
    aliases:
      - forgejo  # alias che NPM usa per trovare il container
```

### 3 — Cloudflare Tunnel usa HTTP interno

Il tunnel porta traffico **HTTP** (non HTTPS) da Cloudflare a NPM. Se NPM ha "Force SSL" attivo risponde con 301 → HTTPS, il tunnel non segue il redirect → errore 1033.

**Regola:** con Cloudflare Tunnel, NPM deve rispondere in HTTP puro sulla porta 80. SSL è terminato da Cloudflare. Per l'accesso LAN si usa un certificato wildcard su NPM separato dal tunnel.

### 4 — HSTS cache nel browser

Se NPM aveva SSL attivo in precedenza, il browser salva in cache l'header HSTS e forza HTTPS per quel dominio. Anche se togli SSL da NPM, il browser continua ad andare su 443 per un periodo.

**Soluzione:** pulire la cache HSTS in `chrome://net-internals/#hsts` oppure usare una finestra in incognito per i test.

### 5 — Copiare URL dalla chat corrompono i file

Il campo testo di Claude converte automaticamente gli URL in formato markdown (`[testo](url)`). Se si copia un compose YAML dalla chat con URL nei valori, i valori diventano `[git.keruhomelab.com](http://git.keruhomelab.com)` che è YAML invalido.

**Soluzione:** scrivere i file con Python usando concatenazione di stringhe invece di URL diretti, oppure usare `sed` per sostituire il formato markdown dopo la scrittura.

### 6 — Immich usa naming con underscore

I container Immich sono `immich_server`, `immich_db`, `immich_ml`, `immich_redis` (underscore). Tutti gli altri container usano il trattino. In NPM e in qualsiasi configurazione che referenzia Immich per hostname, usare l'underscore.

---

## 12. Riferimento rapido comandi

### Docker — Nexus

```bash
cd /opt/homelab-infra

# Avvio stack completo (CPU)
make up

# Avvio con GPU
make up-gpu

# Stop tutto
make down

# Stato container
make ps
# oppure
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort

# Avvio singolo stack con env-file
docker compose --env-file .env -f stacks/git/compose.yml up -d forgejo

# Logs container specifico
docker logs git-forgejo-1 --tail=20 --follow

# Logs cloudflared
docker logs cloudflared --tail=50 -f

# Verifica rete di un container
docker inspect <container> | grep -A10 "homelab-infra_homelab"

# Test raggiungibilità da NPM
docker exec homelab-infra-nginx-1 curl -s -o /dev/null -w "%{http_code}" http://forgejo:3000

# Test NPM risponde correttamente
curl -v -H "Host: git.keruhomelab.com" http://10.0.10.20:80 2>&1 | grep "< HTTP"
```

### OPNsense

```bash
ssh root@10.0.10.1

# Regole NAT attive
pfctl -sn

# Tutte le regole firewall
pfctl -sr

# Verifica port forward specifici
pfctl -sn | grep -E "80|443|8085"

# Ricarica DNS Unbound (dopo modifica host override)
configctl unbound reconfigure

# Verifica Unbound risponde correttamente
host git.keruhomelab.com 127.0.0.1
```

### Diagnostica rete

```bash
# DNS locale (split DNS)
nslookup git.keruhomelab.com 10.0.10.1
dig git.keruhomelab.com @10.0.10.1 +short
# Deve rispondere 10.0.10.20

# DNS esterno (Cloudflare)
dig git.keruhomelab.com @1.1.1.1 +short
# Deve rispondere IP Cloudflare (188.114.x.x) o CNAME cfargotunnel.com

# Test curl con Host header (simula Cloudflare)
curl -v -H "Host: git.keruhomelab.com" http://10.0.10.20:80 2>&1 | grep "< HTTP\|Location"

# RAID status
cat /proc/mdstat
df -h /mnt/md0

# Spazio disco
df -h
du -sh /opt/homelab-infra/ /mnt/md0/homelab_data/
```

### Cloudflare Dashboard — percorsi utili

```
DNS Records:
  keruhomelab.com → DNS → Records

Tunnel:
  Zero Trust → Networks → Tunnels → homelab-nexus

Public Hostnames:
  Zero Trust → Networks → Tunnels → homelab-nexus → Routes

SSL/TLS mode:
  keruhomelab.com → SSL/TLS → Overview
  (impostare su Flexible con tunnel attivo)
```

---

*Documento generato il 4 Maggio 2026*
*ZimaBoard OPNsense 26.1.6 · AMD Nexus Ubuntu 24.04 + Docker · Torre Intel Proxmox 9*
*Dominio: keruhomelab.com · Tunnel: homelab-nexus*
