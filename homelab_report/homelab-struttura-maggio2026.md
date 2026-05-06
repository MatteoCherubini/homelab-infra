# Homelab keruhomelab.com — Struttura e Stato Attuale
*Aggiornato: 6 Maggio 2026 · Basato sulle sessioni del 4 e 5 Maggio 2026*

---

## 1. Hardware: le tre macchine

### 🔥 ZimaBoard — Firewall (OPNsense)

| Proprietà | Valore |
|---|---|
| OS | OPNsense 26.1.6 |
| CPU | Intel Celeron N3350 (2 core) |
| RAM | 2GB DDR4 |
| Storage | SSD 256GB |
| IP WAN | DHCP dinamico da Fritz!Box (192.168.178.x) |
| IP LAN | Gateway VLAN 10: `10.0.10.1` |
| Ruolo | Firewall perimetrale, DNS (Unbound + Dnsmasq), DHCP, NAT |

**Note operative:**
- Suricata installato ma deliberatamente spento (2GB RAM insufficienti per IDS in produzione)
- Monit attivo come WAN watchdog intelligente
- Split DNS via Unbound: 5 host override che risolvono `*.keruhomelab.com` sull'IP locale di Nexus quando si è in LAN

---

### ⚙️ Nexus — Server Docker (AMD)

| Proprietà | Valore |
|---|---|
| OS | Ubuntu Server 24.04 LTS |
| CPU | AMD Ryzen 5 3600 (6C/12T) |
| RAM | 16GB DDR4 |
| GPU | NVIDIA GTX 1660 Super 6GB |
| IP | `10.0.10.20` (statico via netplan) |
| VLAN | 10 — TRUSTED |
| Docker | 29.3.1 + Compose v5.1.1 |
| Hostname | `nexus` |

**Storage:**
```
SSD 512GB   → / (OS Ubuntu + /opt/homelab-infra/ configurazioni + DB)
HDD 4TB × 2 → RAID 1 /dev/md0 → /mnt/md0/homelab_data/ (media e dati)
```
Il RAID 1 (3.6TB utili, array [2/2] UU) è montato correttamente via `/etc/fstab` con UUID. Tutti i volumi dei container che richiedono storage persistente puntano a `/mnt/md0/homelab_data/`.

---

### 🖥️ Torre Intel — Proxmox

| Proprietà | Valore |
|---|---|
| OS | Proxmox VE 9 (Debian Trixie) |
| CPU | Intel Core Ultra 7 265K (20 core) |
| RAM | 64GB DDR5 |
| GPU | RTX 5060 Ti 16GB (dedicata al passthrough VM) |
| IP | `10.0.10.10` (statico via /etc/network/interfaces) |
| VLAN | 10 — TRUSTED |
| GUI | `https://10.0.10.10:8006` |

**VM configurate (stato attuale):**

| VM ID | Nome | OS | Stato |
|---|---|---|---|
| 100 | Windows 11 | Windows 11 | ✅ Funzionante (gaming, GPU passthrough RTX 5060 Ti) |
| 101 | AI | Ubuntu 24.04 | 🔲 Da creare |
| 102 | DEV | Ubuntu 24.04 | 🔲 Da creare |
| 103 | AUDIT | Parrot OS | 🔲 Da creare |

---

### 💻 Laptop — Dell Latitude 7430

| Proprietà | Valore |
|---|---|
| OS | Ubuntu Studio 24.04 LTS |
| CPU | Intel i5-1235U |
| RAM | 16GB DDR5 |
| IP | DHCP `10.0.10.x` |
| VLAN | 10 — TRUSTED |
| Field OS | Parrot OS su USB Kingston DT Max 256GB (LUKS) |

---

## 2. Topologia di rete

```
Internet (Tiscali FTTH)
    ↓
Fritz!Box (bridge) — 192.168.178.0/24
    ↓
ZimaBoard / OPNsense
  WAN: re0 → DHCP 192.168.178.x
  LAN: re1 → trunk 802.1Q
    ↓
Switch TP-Link TL-SG108E (8 porte, 802.1Q)

  Porta 1  → ZimaBoard     [TRUNK: tagged 10,20,30 + untagged 1]
  Porta 2  → Nexus AMD     [Access: untagged VLAN 10]
  Porta 3  → Torre Intel   [Access: untagged VLAN 10]
  Porta 4  → Laptop Dell   [Access: untagged VLAN 10]
  Porta 5  → TV/SmartTV    [Access: untagged VLAN 20]
  Porta 6  → Dispositivi IoT [Access: untagged VLAN 20]
  Porta 7  → Emergenza OPNsense (LAN untagged)

VLAN 10 — TRUSTED  10.0.10.0/24
  10.0.10.1   ZimaBoard (gateway)
  10.0.10.10  Torre Intel (Proxmox)
  10.0.10.20  Nexus AMD (Docker)
  10.0.10.50+ Laptop e dispositivi trusted (DHCP)

VLAN 20 — IoT      10.0.20.0/24
  Dispositivi smart — solo Internet, bloccati dalle reti private

VLAN 30 — DMZ      10.0.30.0/24
  Parcheggiata — block all (nessun dispositivo)
```

---

## 3. Comunicazione tra Torre Intel e Nexus

### 3.1 Comunicazione locale (VLAN 10)

Torre Intel e Nexus sono **entrambe sulla VLAN 10 (TRUSTED)**. Possono comunicarsi direttamente senza uscire dal segmento di rete. Questo è il canale primario per tutto il traffico interno.

Le regole firewall OPNsense su VLAN 10 permettono esplicitamente:
- SSH da Trusted → Torre (`10.0.10.10:22`)
- Proxmox GUI da Trusted → Torre (`10.0.10.10:8006`)
- SSH da Trusted → Nexus (`10.0.10.20:22`)
- Tutti i servizi Docker da Trusted → Nexus (porte esposte vedi sezione 4)

### 3.2 Comunicazione futura via Headscale (VPN mesh)

**Headscale** è già deployato come container su Nexus (`10.0.10.20:8085`) ed è raggiungibile dall'esterno via port forward UDP 8085 sulla WAN OPNsense. La VPN **non è ancora operativa** — mancano i client configurati.

Piano:
- Nexus funge da **server Headscale** (coordinatore della rete WireGuard mesh)
- Laptop, mobile e Torre diventano **nodi Tailscale** connessi al server Headscale
- Indirizzamento mesh sulla subnet `100.64.x.x`
- **Caso d'uso critico:** quando la VM AI (VM 101) su Torre sarà attiva, Open WebUI su Nexus punterà a `10.0.10.11:11434` (Ollama sulla VM AI) tramite la VLAN 10 condivisa

### 3.3 Integrazione futura Torre Intel → Nexus per l'AI

Quando la **VM 101 (AI)** sarà creata su Proxmox:
```
VM 101 (AI) su Torre Intel
  IP: 10.0.10.11
  GPU: RTX 5060 Ti 16GB (passthrough)
  Servizio: Ollama (modelli grandi — Llama 3, ecc.)
  
Open WebUI su Nexus (container Docker)
  Punterà a: http://10.0.10.11:11434
  (comunicazione diretta via VLAN 10, senza uscire dalla LAN)
```
Ollama su Nexus (GTX 1660 Super 6GB) continuerà a servire i **modelli leggeri**. La VM AI con RTX 5060 Ti 16GB prenderà in carico i **modelli grandi**.

---

## 4. Servizi Docker su Nexus — Stato attuale

Tutti i container girano sotto `/opt/homelab-infra/` con struttura a stack separati e `.env` centralizzato.

### Stack `core`

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| nginx (NPM) | jc21/nginx-proxy-manager | 80, 81 (admin), 443 | ✅ UP | Proxy per tutti i domini pubblici |
| cloudflared | cloudflare/cloudflared:latest | — | ✅ UP | Bridge Cloudflare Tunnel |
| headscale | headscale/headscale:latest | 8085 | ✅ UP | VPN mesh (client non ancora configurati) |
| headscale-ui | gurucomputing/headscale-ui | 8086 | ✅ UP | Solo LAN |
| portainer | portainer/portainer-ce | 9000 | ✅ UP | Solo LAN |
| homepage | gethomepage/homepage | 3000 | ✅ UP | Solo LAN |
| netdata | netdata/netdata | 19999 | ✅ UP | Solo LAN |

### Stack `ai`

| Container | Immagine | Porta | Stato | Note |
|---|---|---|---|---|
| ollama | ollama/ollama | 11434 | ✅ UP | Profilo GPU GTX 1660 Super attivo |
| open-webui | open-webui/open-webui | 8090 | ✅ UP | Solo LAN (interfaccia per Ollama) |

### Stack `automation`

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| n8n | n8nio/n8n | 5678 | ✅ UP | Solo LAN |
| n8n-db | postgres:16-alpine | — | ✅ UP | — |

### Stack `cloud` (Nextcloud)

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| nextcloud | nextcloud:latest | 8088 | ✅ UP | ✅ cloud.keruhomelab.com |
| nextcloud-db | postgres:16-alpine | — | ✅ UP | — |
| nextcloud-redis | redis:7-alpine | — | ✅ UP | — |

### Stack `photos` (Immich)

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| immich_server | immich-app/immich-server | 2283 | ✅ UP | ✅ photos.keruhomelab.com |
| immich_ml | immich-app/immich-machine-learning | — | ✅ UP | — |
| immich_db | tensorchord/pgvecto-rs | — | ✅ UP | — |
| immich_redis | redis:7-alpine | — | ✅ UP | — |

### Stack `git` (Forgejo)

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| forgejo | codeberg.org/forgejo/forgejo:10 | 3001 (web), 222 (SSH) | ✅ UP | ✅ git.keruhomelab.com |

ROOT_URL fixato a `https://git.keruhomelab.com/` nella sessione del 5 maggio.

### Stack `security` (Vaultwarden)

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| vaultwarden | vaultwarden/server | 8087 | ✅ UP | ✅ vault.keruhomelab.com |

### Stack `notify`

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| ntfy | binwiederhier/ntfy | 8091 | ✅ UP | ✅ ntfy.keruhomelab.com |

### Stack `docs` (Paperless)

| Container | Immagine | Porta | Stato | Accesso esterno |
|---|---|---|---|---|
| paperless | paperless-ngx/paperless-ngx | 8089 | ✅ UP | Solo LAN |
| paperless-db | postgres:16-alpine | — | ✅ UP | — |
| paperless-redis | redis:7-alpine | — | ✅ UP | — |

### Altri servizi

| Container | Porta | Stato | Note |
|---|---|---|---|
| kopia | 51515 | ✅ UP | Backup — non ancora configurato con policy |
| excalidraw | 8092 | ✅ UP | Solo LAN |
| pingvin | 3002 | ✅ UP | File sharing — Solo LAN |
| garage (S3) | 3900-3902 | ⏸️ FERMATO | Manca `garage.toml` completo — roadmap futura |

---

## 5. Cloudflare Tunnel — Come funziona

Il tunnel è la soluzione al blocco ISP (Tiscali chiude le porte 80/443 in ingresso).

### Architettura del flusso

```
┌─────────────────────────────────────────────────────────────┐
│  DA WAN (4G / Internet)                                     │
│                                                             │
│  Browser → HTTPS → Cloudflare Edge (188.114.x.x)           │
│               ↓ SSL Flexible                                │
│            Tunnel QUIC (4 connessioni)                      │
│               ↓                                             │
│         cloudflared container (172.20.0.x su Nexus)         │
│               ↓ HTTP                                        │
│         nginx (NPM) porta 80                                │
│               ↓                                             │
│   forgejo / nextcloud / vaultwarden / immich_server / ntfy  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  DA LAN (VLAN Trusted 10.0.10.0/24)                        │
│                                                             │
│  Browser → https://git.keruhomelab.com                      │
│               ↓                                             │
│     OPNsense Unbound → 10.0.10.20 (non esce dalla LAN)     │
│               ↓                                             │
│     nginx (NPM) porta 443 + certificato Let's Encrypt       │
│               ↓                                             │
│   forgejo / nextcloud / vaultwarden / immich_server / ntfy  │
└─────────────────────────────────────────────────────────────┘
```

### Componenti chiave

**Cloudflared container (su Nexus):**
- Stabilisce 4 connessioni QUIC uscenti verso l'edge Cloudflare Italia (FCO01, MXP03, MXP05)
- Non richiede porte aperte in ingresso su OPNsense
- Il traffico web dall'esterno arriva tramite questo tunnel — non via NAT

**Nginx Proxy Manager (NPM):**
- Riceve il traffico WAN dal tunnel su porta 80 (HTTP, senza SSL)
- Riceve il traffico LAN su porta 443 (HTTPS con certificati Let's Encrypt)
- Fa routing verso i container per hostname interno (es. `forgejo:3000`, `nextcloud:80`, `immich_server:2283`)
- Ogni proxy host ha gli header `X-Forwarded-*` configurati

**SSL — configurazione corretta:**
- Cloudflare SSL mode: `Flexible` (Cloudflare ↔ Browser = HTTPS, Cloudflare ↔ Nexus = HTTP)
- Tunnel route: `http://nginx:80` (non HTTPS — evita errori TLS SNI)
- NPM Force SSL: ON (per i client LAN che usano HTTPS)
- Certificati: Let's Encrypt su NPM per accesso LAN sicuro

**Split DNS (Unbound OPNsense):**
- 5 host override: `git`, `cloud`, `vault`, `photos`, `ntfy` → `10.0.10.20`
- Quando sei in LAN il traffico non esce mai da casa — risoluzione diretta all'IP di Nexus
- Da Internet, Cloudflare DNS risponde con `188.114.x.x` (edge Cloudflare)

### DNS pubblici (Cloudflare)

| Tipo | Nome | Target | Proxy |
|---|---|---|---|
| CNAME | git | `8d0a...142b2c.cfargotunnel.com` | ✅ Proxied |
| CNAME | cloud | `8d0a...142b2c.cfargotunnel.com` | ✅ Proxied |
| CNAME | vault | `8d0a...142b2c.cfargotunnel.com` | ✅ Proxied |
| CNAME | photos | `8d0a...142b2c.cfargotunnel.com` | ✅ Proxied |
| CNAME | ntfy | `8d0a...142b2c.cfargotunnel.com` | ✅ Proxied |

**⚠️ Il Tunnel ID (`8d0a...`) deve sempre corrispondere al token nel `.env` di Nexus.**

---

## 6. VM AI su Proxmox — Piano implementativo

### VM 101 — AI (da creare)

```
Proxmox → Create VM 101:
  Name:    ai
  OS:      Ubuntu Server 24.04 LTS
  CPU:     8 core (dall'Ultra 7 265K da 20 core)
  RAM:     32GB DDR5
  Disk:    100GB SSD
  GPU:     RTX 5060 Ti 16GB (passthrough PCI)
  Network: vmbr0 (VLAN 10)
  IP:      10.0.10.11 (statico)
```

**Post-install:**
1. Installare NVIDIA driver + nvidia-container-toolkit
2. Installare Docker
3. Deploy Ollama con accesso GPU
4. **Aggiornare Open WebUI su Nexus** per puntare a `http://10.0.10.11:11434`

**Comunicazione VM AI ↔ Nexus:**
La VM AI (10.0.10.11) e Nexus (10.0.10.20) sono entrambe sulla VLAN 10 — la chiamata di Open WebUI verso Ollama avviene **interamente in LAN**, senza passare per il tunnel Cloudflare né per OPNsense.

**Regole firewall da aggiungere su OPNsense quando la VM è pronta:**
```
Nuovo alias:  SERVER_AI → 10.0.10.11
Nuova regola: PASS TCP TRUSTED → SERVER_AI porta 11434 (Ollama API)
Nuova regola: PASS TCP TRUSTED → SERVER_AI porta 22 (SSH)
```

### Divisione del lavoro AI

| Macchina | GPU | Ruolo Ollama |
|---|---|---|
| Nexus (AMD) | GTX 1660 Super 6GB | Modelli leggeri (7B, rapidi) |
| VM AI su Torre | RTX 5060 Ti 16GB | Modelli grandi (34B+, qualità alta) |

---

## 7. Cosa resta da fare (priorità)

### 🔴 Alta

- [ ] **Rimuovere NAT 443 da OPNsense** — le regole `rdr tcp 443 → Nexus` non servono più con il tunnel attivo
- [ ] **Aggiornare Homepage `services.yaml`** — sostituire tutti gli `href: http://10.0.10.20:PORTA` con i domini pubblici (`https://git.keruhomelab.com`, ecc.)

### 🟠 Media

- [ ] **SSH hardening** — chiavi Ed25519 su OPNsense, Nexus e Torre; disabilitare password auth
- [ ] **Headscale — configurare client** — creare utente admin, generare auth key, connettere laptop e mobile con Tailscale
- [ ] **Forgejo compose** — aggiungere `REVERSE_PROXY_TRUSTED_PROXIES` per prevenire blocchi CSRF dagli AI agent

### 🟢 Bassa

- [ ] **VM 101 AI su Torre** — creare VM, installare Ollama con RTX 5060 Ti, aggiornare Open WebUI
- [ ] **Monitoring** — Grafana + Loki (container già predisposti, no dashboard configurate)
- [ ] **Backup Kopia** — configurare policy automatiche verso storage locale/remoto

---

*Stack attivo: ZimaBoard OPNsense 26.1.6 · AMD Nexus Ubuntu 24.04 (29 container) · Torre Intel Proxmox VE 9*
*Tunnel ID attivo: `8d0a54fa...142b2c` — 4 connessioni QUIC verso edge Cloudflare Italia*
*Dominio: keruhomelab.com — 5 sottodomini pubblici attivi*
