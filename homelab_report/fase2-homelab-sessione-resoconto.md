# Homelab keruhomelab.com — Resoconto Sessione
*Generato: 3 Maggio 2026 · Dominio: keruhomelab.com · Server: Nexus (10.0.10.20)*

---

## Indice

1. [Contesto di partenza](#1-contesto-di-partenza)
2. [Problemi identificati e risolti](#2-problemi-identificati-e-risolti)
3. [Problemi identificati e parzialmente risolti](#3-problemi-identificati-e-parzialmente-risolti)
4. [Scoperta bloccante — ISP blocca porta 443](#4-scoperta-bloccante--isp-blocca-porta-443)
5. [Stato attuale dell'infrastruttura](#5-stato-attuale-dellinfrastruttura)
6. [Prossimi passi](#6-prossimi-passi)
7. [Riferimento rapido — Comandi utili](#7-riferimento-rapido--comandi-utili)

---

## 1. Contesto di partenza

### Infrastruttura hardware
| Componente | Ruolo | IP |
|---|---|---|
| ZimaBoard | OPNsense 26.1.6 (firewall/router) | 10.0.10.1 |
| Nexus (AMD) | Ubuntu Server 24.04, Docker | 10.0.10.20 |
| Torre Intel | Proxmox (hypervisor) | 10.0.10.10 |
| Laptop Dell | Client principale (TRUSTED VLAN) | 10.0.10.81 |

### Stack Docker in produzione su Nexus
Il compose è in `/opt/homelab-infra/` (non `/opt/homelab` come indicato nella documentazione precedente — **discrepanza da correggere nei doc**).

| Stack | Servizi |
|---|---|
| core | Nginx Proxy Manager, Headscale, Portainer, Homepage |
| cloud | Nextcloud + PostgreSQL + Redis |
| photos | Immich + PostgreSQL + Redis + ML |
| docs | Paperless-ngx + PostgreSQL + Redis |
| ai | Ollama + Open WebUI |
| automation | n8n + PostgreSQL |
| git | Forgejo |
| security | Vaultwarden |
| storage | Garage S3, Kopia |
| monitoring | Netdata, Grafana, Loki, Promtail |
| tools | ntfy, Excalidraw |

### Fasi completate prima di questa sessione
- ✅ Fase 1 — VLAN, firewall, switch, alias, NAT
- ✅ Fase 2A — Pulizia OPNsense
- ✅ Fase 2B — SSH hardening (chiave Ed25519)
- ✅ Fase 2C — Migrazione Docker a struttura modulare
- ✅ Fase 2D — Setup iniziale servizi (parziale)
- 🔶 Fase 2E — Dominio + DDNS + SSL — **avviata ma incompleta**

---

## 2. Problemi identificati e risolti

### 2.1 — Bug Ollama: conflitto porta dopo `make up-gpu`

**Sintomo:** dopo `make down`, era necessario eseguire manualmente `docker stop homelab-infra-ollama-1` prima di poter fare `make up-gpu`.

**Causa (doppia):**
1. `make down` senza `--profile gpu` non fermava i container avviati con profilo GPU, lasciando `ollama-gpu-1` attivo con la porta 11434 occupata.
2. Sia `ollama` (senza profilo) che `ollama-gpu` (profilo `gpu`) mappavano la stessa porta `11434`, causando conflitto quando venivano avviati insieme.

**Fix applicato — `stacks/ai/compose.yml`:**
```yaml
ollama:
  profiles:
    - cpu          # aggiunto — si esclude mutuamente con gpu

ollama-gpu:
  profiles:
    - gpu
  networks:
    homelab:
      aliases:
        - ollama   # alias aggiunto — open-webui lo trova sempre
```

**Fix applicato — `Makefile`:**
```makefile
up:      COMPOSE_PARALLEL_LIMIT=1 docker compose --profile cpu up -d
up-gpu:  docker compose --profile gpu up -d
down:    docker compose --profile cpu --profile gpu down
```

**Nota:** `open-webui` puntava a `http://ollama:11434` — con il profilo GPU attivo, il container `ollama` non partiva e la WebUI non trovava nessuno. L'alias di rete risolve questo senza toccare la configurazione di Open WebUI.

---

### 2.2 — Open WebUI: PDF con "content is empty"

**Sintomo:** caricando un PDF su Open WebUI, il messaggio era: *"The content provided is empty"*. Il PDF si visualizzava correttamente in anteprima.

**Causa:** il PDF era composto da immagini scansionate (nessun layer di testo). Il motore di estrazione predefinito di NPM (PyPDF) non esegue OCR e non trova nulla.

**Soluzione discussa:** utilizzare Apache Tika come motore di estrazione alternativo in Open WebUI.

**Problema successivo — Tika non raggiungibile:**
Aggiungendo Tika, Open WebUI restituiva:
```
HTTPConnectionPool(host='tika', port=9998): Failed to resolve 'tika'
```

**Causa:** Tika era stato aggiunto in un compose file separato senza dichiarare la rete `homelab` come `external: true`. Docker Compose creava una rete isolata invece di agganciarsi alla rete condivisa.

**Fix:**
```yaml
# nel compose file di Tika
services:
  tika:
    networks:
      - homelab

networks:
  homelab:
    external: true   # ← obbligatorio in tutti gli stack secondari
```

---

### 2.3 — Nginx Proxy Manager: email admin non configurata

**Sintomo:** richiedendo un certificato Let's Encrypt in NPM, errore: *"The ACME server believes admin@example.com is an invalid email address"*.

**Causa:** l'account admin di NPM non era mai stato aggiornato dopo il primo accesso — email rimasta `admin@example.com` (valore di default).

**Fix:** `NPM → icona utente in alto a destra → Edit Details` → email aggiornata con indirizzo reale.

---

### 2.4 — Let's Encrypt: challenge HTTP-01 fallisce attraverso Cloudflare

**Sintomo:** dopo aver corretto l'email, il challenge continuava a fallire:
```
Invalid response from http://git.keruhomelab.com/.well-known/acme-challenge/...: 523
```

**Causa:** Let's Encrypt usa il challenge HTTP-01, che richiede di raggiungere il dominio sulla porta 80. Il dominio passa attraverso Cloudflare (proxy attivo), che a sua volta non riusciva a raggiungere l'origine → 523. Circolo vizioso: serve il certificato per risolvere il 523, ma il challenge per il certificato fallisce a causa del 523.

**Fix:** cambio del metodo di challenge da HTTP-01 a **DNS-01** tramite API Cloudflare. Il DNS-01 non richiede che il server sia raggiungibile — verifica la proprietà del dominio creando un record DNS temporaneo.

```
NPM → Edit Proxy Host → SSL → Use DNS Challenge
DNS Provider: Cloudflare
Credentials: dns_cloudflare_api_token = <TOKEN>
```

**Risultato:** certificato Let's Encrypt emesso con successo per `git.keruhomelab.com`.

---

### 2.5 — NAT OPNsense: porta 80 mancante

**Sintomo:** `pfctl -sn` mostrava solo il forward per la porta 443 e 8085, non per la 80.

**Diagnosi:**
```bash
pfctl -sn | grep -E "80|443"
# Output:
rdr on re0 proto tcp from any to (re0) port = https -> SERVER_NEXUS port 443
rdr on re0 proto udp from any to (re0) port = 8085  -> SERVER_NEXUS port 8085
# porta 80 assente
```

**Fix:** aggiunta regola Destination NAT in OPNsense (`Firewall → NAT → Destination NAT`):
- Interface: WAN / Protocol: TCP / Destination port: HTTP (80) / Redirect: SERVER_NEXUS:80

**Nota:** la porta 80 si è rivelata non necessaria per i certificati (risolto con DNS-01), ma rimane utile per eventuali redirect HTTP→HTTPS futuri. Può essere rimossa se si usa esclusivamente il DNS-01 challenge.

---

### 2.6 — Denominazione nuova UI OPNsense 26.1

**Problema pratico:** la documentazione esistente riferisce `Firewall → NAT → Port Forward`, voce non più esistente in OPNsense 26.1.

**Cambiamento:** in OPNsense 26.1, "Port Forward" è stato rinominato **"Destination NAT"**.
Percorso aggiornato: `Firewall → NAT → Destination NAT`.

---

## 3. Problemi identificati e parzialmente risolti

### 3.1 — Split DNS non configurato

**Sintomo:** dalla rete interna (TRUSTED VLAN), i sottodomini `*.keruhomelab.com` non risolvono direttamente a `10.0.10.20`. Il traffico esce verso Cloudflare e rientra (hairpin NAT) — intermittente e inaffidabile.

**Causa:** gli host override in Unbound DNS (OPNsense) non sono stati configurati. È il passo **2E.6** della roadmap, mai completato.

**Fix da applicare:** `Services → Unbound DNS → Host Overrides` su OPNsense:

| Host | Dominio | IP |
|---|---|---|
| cloud | keruhomelab.com | 10.0.10.20 |
| vault | keruhomelab.com | 10.0.10.20 |
| photos | keruhomelab.com | 10.0.10.20 |
| ntfy | keruhomelab.com | 10.0.10.20 |
| git | keruhomelab.com | 10.0.10.20 |

**Impatto attuale:** verificato che dalla rete interna `git.keruhomelab.com` risolve già `10.0.10.20` (il curl dal laptop ha mostrato `IPv4: 10.0.10.20`) — probabilmente OPNsense sta già gestendo il NAT reflection. Il comportamento resta inaffidabile senza gli override espliciti.

---

### 3.2 — Certificati SSL: solo git ha Let's Encrypt

**Stato attuale proxy host:**
| Sottodominio | SSL | Note |
|---|---|---|
| `git.keruhomelab.com` | ✅ Let's Encrypt | Certificato emesso correttamente |
| `cloud.keruhomelab.com` | ❌ HTTP Only | Da completare |
| `ntfy.keruhomelab.com` | ❌ HTTP Only | Da completare |
| `photos.keruhomelab.com` | ❌ HTTP Only | Da completare |
| `vault.keruhomelab.com` | ❌ HTTP Only | **Critico** — password in chiaro |

**Fix da applicare:** ripetere il processo DNS-01 challenge per i restanti 4 proxy host, oppure emettere un unico certificato wildcard `*.keruhomelab.com` e assegnarlo a tutti.

---

## 4. Scoperta bloccante — ISP blocca porta 443

### Il problema

Nonostante NAT corretto, certificati SSL presenti e NPM funzionante, il 523 persiste dall'esterno.

**Diagnosi via yougetsignal.com:**
```
IP pubblico: 82.84.30.255
Port 443: CLOSED
ISP: Tiscali
```

Tiscali (come la maggior parte degli ISP residenziali italiani) **blocca le porte 80 e 443 in ingresso** a livello di infrastruttura. Non è un problema di configurazione — il traffico viene scartato prima ancora di arrivare al modem.

**Conferma via tcpdump:** il traffico interno (dalla VLAN) arriva correttamente a Nexus sulla 443. Il problema è esclusivamente lato WAN.

### Implicazioni

- Il NAT su OPNsense era e rimane corretto
- NPM funziona correttamente
- I certificati SSL sono validi
- **L'unica soluzione è bypassare la limitazione dell'ISP**

### Soluzione: Cloudflare Tunnel

Cloudflare Tunnel (`cloudflared`) crea una connessione **uscente** da Nexus verso i server Cloudflare. Il traffico degli utenti arriva a Cloudflare → transita nel tunnel → raggiunge Nexus, **senza mai dover aprire porte in ingresso**.

**Vantaggi:**
- Zero porte aperte sul firewall (NAT 443 e 80 possono essere rimossi)
- Funziona con qualsiasi ISP, anche con IP dinamico
- Cloudflare WAF, DDoS protection e Bot Fight Mode rimangono attivi
- SSL gestito da Cloudflare — niente più Let's Encrypt su NPM
- Piano gratuito Cloudflare include i tunnel senza limiti di banda

**Architettura risultante:**
```
Utente → Cloudflare Edge → Tunnel cifrato → cloudflared su Nexus → NPM → Container
```

---

## 5. Stato attuale dell'infrastruttura

### Cosa funziona ✅
| Componente | Stato | Note |
|---|---|---|
| Docker stack completo | ✅ Online | Tutti i container up |
| Rete VLAN segmentata | ✅ Attiva | TRUSTED, IOT, DMZ separate |
| OPNsense firewall | ✅ Configurato | Alias, regole, NAT presenti |
| DDNS Cloudflare | ✅ Attivo | IP aggiornato automaticamente |
| Record DNS Cloudflare | ✅ Presenti | 5 sottodomini + root, tutti Proxied |
| Certificato SSL git | ✅ Valido | Let's Encrypt via DNS-01 |
| Accesso interno via IP | ✅ Funzionante | Tutti i servizi raggiungibili su 10.0.10.20:PORT |
| Accesso interno via dominio | ✅ Parziale | git funziona, altri da verificare post-SSL |
| SSH hardening | ✅ Completato | Ed25519, no password auth |

### Cosa non funziona ❌
| Componente | Problema | Priorità |
|---|---|---|
| Accesso esterno (WAN) | ISP blocca 443 — nessun sottodominio raggiungibile da Internet | 🔴 Alta |
| SSL su 4 proxy host | cloud, ntfy, photos, vault ancora HTTP Only | 🔴 Alta |
| Split DNS Unbound | Host override non configurati | 🟠 Media |
| Cloudflare Full (Strict) | Senza tunnel/SSL completo, la modalità SSL non è corretta | 🟠 Media |

### Alias firewall rilevanti
| Alias | Contenuto | Uso |
|---|---|---|
| `SERVER_NEXUS` | `10.0.10.20` | Target NAT e regole firewall |
| `SERVER_TORRE` | `10.0.10.10` | Proxmox |
| `NEXUS_WEB` | Porte servizi web | Regole TRUSTED |
| `NEXUS_INFRA` | Porte infrastruttura | Regole TRUSTED |
| `RFC1918` | Reti private | Blocco in uscita da DMZ/IOT |

### Regole NAT Destination attive
| Porta | Protocollo | Destinazione | Descrizione |
|---|---|---|---|
| 443 | TCP | SERVER_NEXUS:443 | HTTPS → Nginx Proxy Manager |
| 8085 | UDP | SERVER_NEXUS:8085 | Headscale WireGuard VPN |
| 80 | TCP | SERVER_NEXUS:80 | HTTP (aggiunta oggi, opzionale) |

---

## 6. Prossimi passi

### Priorità 1 — Cloudflare Tunnel (blocca tutto il resto)

Il tunnel risolve il problema ISP e sblocca l'accesso esterno a tutti i servizi.

**Procedura:**

**Step 1 — Crea il tunnel su Cloudflare Dashboard:**
```
Cloudflare → Zero Trust → Networks → Tunnels → Create a tunnel
Nome: homelab-nexus
Connettore: Docker
```
Cloudflare fornirà un token (`TUNNEL_TOKEN`).

**Step 2 — Aggiungi `cloudflared` al compose (es. `stacks/core/compose.yml`):**
```yaml
cloudflared:
  image: cloudflare/cloudflared:latest
  restart: unless-stopped
  command: tunnel --no-autoupdate run
  environment:
    TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN}
  networks:
    - homelab
```

**Step 3 — Aggiungi al `.env`:**
```bash
CLOUDFLARE_TUNNEL_TOKEN=<token dal dashboard>
```

**Step 4 — Configura le Public Hostnames nel tunnel:**
```
git.keruhomelab.com    → http://nginx:80
cloud.keruhomelab.com  → http://nginx:80
vault.keruhomelab.com  → http://nginx:80
photos.keruhomelab.com → http://nginx:80
ntfy.keruhomelab.com   → http://nginx:80
```
Tutti puntano a NPM che fa da reverse proxy verso i singoli container.

**Step 5 — Aggiorna i record DNS su Cloudflare:**
I record A attuali vanno sostituiti con record CNAME che puntano al tunnel:
```
git    CNAME  <tunnel-id>.cfargotunnel.com
cloud  CNAME  <tunnel-id>.cfargotunnel.com
...
```
Cloudflare lo fa automaticamente dalla UI del tunnel.

**Step 6 — Pulizia OPNsense (opzionale ma consigliato):**
Con il tunnel attivo, le regole NAT per 80 e 443 non servono più. Possono essere disabilitate per ridurre la superficie di attacco.

---

### Priorità 2 — Completare i certificati SSL (dopo il tunnel)

Con Cloudflare Tunnel, il SSL può essere gestito in due modi:

**Opzione A — SSL terminato da Cloudflare (più semplice):**
Cloudflare gestisce HTTPS verso gli utenti, il tunnel viaggia in HTTP interno. NPM non ha bisogno di certificati. La comunicazione Cloudflare→tunnel è cifrata da Cloudflare stesso.

**Opzione B — SSL end-to-end (più sicuro):**
Emettere un certificato wildcard `*.keruhomelab.com` tramite DNS-01 su NPM e configurare il tunnel per usare HTTPS verso NPM. Cloudflare Full Strict funziona correttamente.

Per un homelab personale, l'Opzione A è sufficiente e più semplice da mantenere.

---

### Priorità 3 — Split DNS in Unbound

Anche con il tunnel attivo, configurare gli host override garantisce che dalla VLAN interna il traffico non esca mai su Internet.

`Services → Unbound DNS → Host Overrides`:
- 5 entry: `cloud`, `vault`, `photos`, `ntfy`, `git` → `10.0.10.20`

---

### Priorità 4 — Completare le fasi rimanenti della roadmap

| Fase | Descrizione | Dipendenze |
|---|---|---|
| 2F | Headscale VPN | Tunnel attivo (per accesso esterno alla VPN) |
| 2G | UPS + NUT | UPS fisicamente connesso |
| 2H | Grafana + Loki | Già parzialmente configurato |
| 2I | Kopia + Garage S3 backup | Nessuna |

---

### Priorità 5 — Aggiornare la documentazione

- Correggere il path del progetto da `/opt/homelab` a `/opt/homelab-infra`
- Aggiungere la sezione Cloudflare Tunnel alla fase 2E
- Aggiornare i riferimenti UI di OPNsense 26.1 (Port Forward → Destination NAT)
- Aggiungere nota su ISP e limitazioni porte inbound

---

## 7. Riferimento rapido — Comandi utili

```bash
# ── Docker (su Nexus) ───────────────────────────────────────
ssh nexus
cd /opt/homelab-infra

make up                    # Avvia tutto (profilo CPU)
make up-gpu                # Avvia con GPU NVIDIA
make down                  # Ferma tutto (tutti i profili)
make ps                    # Stato container
make logs                  # Log live
make pull                  # Aggiorna immagini

docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
docker compose logs nginx --tail=50
docker compose logs nginx --follow

# ── Diagnostica rete ────────────────────────────────────────
sudo ss -tlnp | grep -E "80|443"           # Porte in ascolto
sudo tcpdump -i any port 443 -c 10 -nn     # Traffico sulla 443
curl -sk https://localhost -o /dev/null -w "%{http_code}"

# ── OPNsense ────────────────────────────────────────────────
ssh opnsense
pfctl -sn                                  # Regole NAT attive
pfctl -sn | grep -E "80|443"               # Verifica forward specifici
pfctl -sr                                  # Tutte le regole firewall
configctl unbound reconfigure              # Ricarica DNS Unbound

# ── Backup config OPNsense ──────────────────────────────────
scp root@10.0.10.1:/conf/config.xml ~/backup_opnsense_$(date +%Y%m%d).xml
```

---

## Appendice — Architettura di rete attuale

```
Internet
    │
    ▼
Tiscali (ISP) — blocca porte 80/443 inbound
    │
    ▼
IP Pubblico: 82.84.30.255
    │
    ▼
ZimaBoard — OPNsense 26.1.6
├── WAN: 82.84.30.255
├── TRUSTED (opt1): 10.0.10.0/24
│   ├── Nexus:  10.0.10.20  (Docker host)
│   ├── Torre:  10.0.10.10  (Proxmox)
│   └── Laptop: 10.0.10.81  (client)
├── IOT (opt2): 10.0.20.0/24
└── DMZ (opt3): 10.0.30.0/24  (block all)

Nexus (10.0.10.20)
├── :80   → NPM (HTTP)
├── :443  → NPM (HTTPS)
├── :81   → NPM Admin UI
├── :8085 → Headscale
├── :8086 → Headscale UI
├── :8087 → Vaultwarden
├── :8088 → Nextcloud
├── :8089 → Paperless-ngx
├── :8090 → Open WebUI
├── :8091 → ntfy
├── :8092 → Excalidraw
├── :2283 → Immich
├── :3001 → Forgejo
├── :3003 → Grafana
├── :5678 → n8n
├── :9000 → Portainer
└── :11434 → Ollama

Cloudflare (DNS Proxy attivo)
├── cloud.keruhomelab.com  → 82.84.30.255 (proxied)
├── vault.keruhomelab.com  → 82.84.30.255 (proxied)
├── photos.keruhomelab.com → 82.84.30.255 (proxied)
├── ntfy.keruhomelab.com   → 82.84.30.255 (proxied)
└── git.keruhomelab.com    → 82.84.30.255 (proxied)
```

---

*Documento generato al termine della sessione del 3 Maggio 2026.*
*Prossima sessione: implementazione Cloudflare Tunnel.*
