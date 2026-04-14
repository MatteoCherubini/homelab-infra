# Homelab Infrastructure — Stato Attuale e Roadmap
*Aggiornato: 13 Aprile 2026 — Post-migrazione VLAN*

---

## 1. Topologia di rete attiva

```
Internet (Tiscali FTTH via Fritz!Box)
    ↓
Fritz!Box (bridge/passthrough) → 192.168.178.0/24
    ↓
┌─────────────────────────────────────────────────────┐
│  ZimaBoard — OPNsense 26.1.5                       │
│  WAN: re0 → DHCP 192.168.178.76 (dinamico)         │
│  LAN: re1 → 192.168.1.1/24 (trunk 802.1Q)          │
│  VLAN 10 (TRUSTED): vlan0.10 → 10.0.10.1/24        │
│  VLAN 20 (IOT):     vlan0.20 → 10.0.20.1/24        │
│  VLAN 30 (DMZ):     vlan0.30 → 10.0.30.1/24        │
│  RAM: 2GB · CPU: Celeron N3350 · SSD 256GB          │
└─────────────────────────────────────────────────────┘
    ↓ trunk (tagged 10,20,30 + untagged 1)
┌─────────────────────────────────────────────────────┐
│  Switch TP-Link TL-SG108E (802.1Q configurato)      │
│                                                      │
│  [1]    [2]    [3]    [4]    [5]    [6]   [7]  [8]  │
│  Zima   Nexus  Torre  Laptop TV     IoT   EMG  --   │
│  TRUNK  V10    V10    V10    V20    V20   LAN  --   │
└─────────────────────────────────────────────────────┘
    ↓
    ├── VLAN 10 (TRUSTED) — 10.0.10.0/24
    │   ├── 10.0.10.10  Torre Intel (Proxmox VE 9)
    │   ├── 10.0.10.20  Nexus AMD (Ubuntu Server 24.04 + Docker)
    │   └── 10.0.10.x   Laptop Dell (DHCP, range 10.0.10.50-200)
    │
    ├── VLAN 20 (IOT) — 10.0.20.0/24
    │   └── 10.0.20.x   TV, smart devices (DHCP, range 10.0.20.100-200)
    │
    ├── VLAN 30 (DMZ) — 10.0.30.0/24
    │   └── Parcheggiata (Opzione A — block all, nessun device)
    │
    └── LAN untagged — 192.168.1.0/24
        └── Solo management OPNsense (porta 7 emergenza)
```

---

## 2. Macchine

### ZimaBoard — Firewall OPNsense

| Proprietà | Valore |
|---|---|
| OS | OPNsense 26.1.5-amd64 (Witty Woodpecker) |
| CPU | Intel Celeron N3350 (2 core) |
| RAM | 2GB DDR4 |
| Storage | SSD 256GB |
| WAN | re0 — DHCP da Fritz!Box (IP dinamico) |
| LAN | re1 — 192.168.1.1/24 (trunk) |
| Timezone | Europe/Rome (CEST) |
| DNS | Unbound (porta 53) + Dnsmasq (DHCP, porta 53053) |
| DNSSEC | Attivo |
| SSH | Porta 22, root + password (da chiudere — vedi TODO) |
| IDS/IPS | Disabilitato (RAM insufficiente per Suricata) |

**Servizi attivi su OPNsense:**
- Dnsmasq: DHCP per LAN, TRUSTED, IOT + DNS forwarding
- Unbound: DNS resolver con DNSSEC
- Monit: watchdog WAN DHCP (ping 8.8.8.8, restart ogni 5 min)
- NAT hybrid outbound per tutte le VLAN

### AMD Nexus — Server Docker

| Proprietà | Valore |
|---|---|
| OS | Ubuntu Server 24.04 LTS |
| CPU | AMD Ryzen 5 3600 (6C/12T) |
| RAM | 16GB DDR4 |
| GPU | NVIDIA GTX 1660 Super 6GB |
| IP | 10.0.10.20 (statico netplan) |
| VLAN | 10 (TRUSTED) |
| Docker | 29.3.1 + Compose v5.1.1 |
| Hostname | nexus |

**Storage:**
```
SSD 512GB → / (Ubuntu OS + /opt/homelab config + database)
HDD 4TB × 2 → RAID 1 /dev/md0 → /mnt/md0/homelab_data/ (media e dati)
```

### Torre Intel — Proxmox

| Proprietà | Valore |
|---|---|
| OS | Proxmox VE 9 (Debian Trixie) |
| CPU | Intel Core Ultra 7 265K (20 core) |
| RAM | 64GB DDR5 |
| GPU | RTX 5060 Ti 16GB (passthrough alle VM) |
| IP | 10.0.10.10 (statico /etc/network/interfaces) |
| VLAN | 10 (TRUSTED) |
| GUI | https://10.0.10.10:8006 |

**VM configurate:**
- VM 100 — Windows 11 (gaming, GPU passthrough) — funzionante
- VM 101 — AI (Ubuntu, Ollama modelli grandi) — da creare
- VM 102 — DEV (Ubuntu, sviluppo) — da creare
- VM 103 — AUDIT (Parrot OS) — da creare

### Laptop Dell Latitude 7430

| Proprietà | Valore |
|---|---|
| OS | Ubuntu Studio 24.04 LTS |
| CPU | Intel i5-1235U |
| RAM | 16GB DDR5 |
| NIC | USB-C → GbE (enx2887ba7f29b0) |
| IP | DHCP 10.0.10.x |
| VLAN | 10 (TRUSTED) |
| Field OS | Parrot OS su USB Kingston DT Max 256GB (LUKS) |

---

## 3. Firewall — Regole attive

### WAN (re0) — 2 regole + port forward

| Azione | Proto | Sorgente | Dest | Porta | Descrizione |
|---|---|---|---|---|---|
| PASS | TCP | any | SERVER_NEXUS | 443 | HTTPS → Nginx |
| PASS | UDP | any | SERVER_NEXUS | 8085 | Headscale VPN |

**Destination NAT (port forward):**
| WAN port | Dest interno | Porta | Descrizione |
|---|---|---|---|
| TCP 443 | 10.0.10.20 | 443 | Nginx Proxy Manager |
| UDP 8085 | 10.0.10.20 | 8085 | Headscale |

### LAN (re1 untagged) — 5 regole

| Azione | Proto | Sorgente | Dest | Porta | Descrizione |
|---|---|---|---|---|---|
| PASS | TCP | LAN net | self | 443 | GUI OPNsense |
| PASS | TCP | LAN net | self | 22 | SSH emergenza |
| PASS | UDP/TCP | LAN net | self | 53 | DNS |
| BLOCK | any | LAN net | RFC1918 | any | No reti private |
| PASS | any | LAN net | any | any | Internet |

### TRUSTED (VLAN 10) — Regole complete

| Azione | Proto | Sorgente | Dest | Porta | Descrizione |
|---|---|---|---|---|---|
| PASS | UDP | any | self | 67 | DHCP |
| PASS | TCP/UDP | TRUSTED net | self | 53 | DNS |
| PASS | TCP | TRUSTED net | self | 443 | OPNsense GUI |
| PASS | TCP | TRUSTED net | self | 22 | OPNsense SSH |
| PASS | TCP | TRUSTED net | SERVER_NEXUS | 3000,3001,3002,3003,5678,8086-8092,9000,2283,19999,51515,81 | Servizi web Docker |
| PASS | TCP/UDP | TRUSTED net | SERVER_NEXUS | 8085,11434,3900-3902 | API infrastruttura |
| PASS | TCP | TRUSTED net | SERVER_NEXUS | 222 | Forgejo SSH |
| PASS | TCP | TRUSTED net | SERVER_NEXUS | 22 | SSH Nexus |
| PASS | TCP | TRUSTED net | SERVER_TORRE | 8006 | Proxmox GUI |
| PASS | TCP | TRUSTED net | SERVER_TORRE | 22 | SSH Torre |
| BLOCK | any | TRUSTED net | 10.0.20.0/24 | any | No → IoT |
| BLOCK | any | TRUSTED net | 10.0.30.0/24 | any | No → DMZ |
| PASS | any | TRUSTED net | any | any | Internet libero |

### IOT (VLAN 20) — 5 regole

| Azione | Proto | Sorgente | Dest | Porta | Descrizione |
|---|---|---|---|---|---|
| PASS | UDP/TCP | IOT net | self | 53 | DNS |
| BLOCK | any | IOT net | RFC1918 | any | No reti private |
| PASS | TCP | IOT net | any | 80 | HTTP |
| PASS | TCP | IOT net | any | 443 | HTTPS |
| PASS | UDP | IOT net | any | 123 | NTP |

### DMZ (VLAN 30) — Parcheggiata

| Azione | Proto | Sorgente | Dest | Porta | Descrizione |
|---|---|---|---|---|---|
| BLOCK | any | DMZ net | any | any | Nessun traffico |

### Alias configurati

| Nome | Tipo | Contenuto |
|---|---|---|
| SERVER_NEXUS | Host | 10.0.10.20 |
| SERVER_TORRE | Host | 10.0.10.10 |
| RFC1918 | Network | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 |
| NEXUS_WEB | Port | 3000,3001,3002,3003,5678,8086-8092,9000,2283,19999,51515,81 |
| NEXUS_INFRA | Port | 8085,11434,3900-3902 |
| NEXUS_GIT_SSH | Port | 222 |

---

## 4. Docker Stack — Nexus (27 container attivi)

### Stato container (13 Aprile 2026)

| Servizio | Immagine | Porta | Stato |
|---|---|---|---|
| nginx | jc21/nginx-proxy-manager:latest | 80,81,443 | ✅ UP |
| headscale | headscale/headscale:latest | 8085 | ✅ UP |
| headscale-ui | ghcr.io/gurucomputing/headscale-ui:latest | 8086 | ✅ UP |
| portainer | portainer/portainer-ce:latest | 9000 | ✅ UP |
| homepage | ghcr.io/gethomepage/homepage:latest | 3000 | ✅ UP |
| netdata | netdata/netdata:latest | 19999 | ✅ UP |
| ollama | ollama/ollama:latest | 11434 | ✅ UP |
| open-webui | ghcr.io/open-webui/open-webui:latest | 8090 | ✅ UP |
| n8n | n8nio/n8n:latest | 5678 | ✅ UP |
| n8n-db | postgres:16-alpine | — | ✅ UP |
| nextcloud | nextcloud:latest | 8088 | ✅ UP |
| nextcloud-db | postgres:16-alpine | — | ✅ UP |
| nextcloud-redis | redis:7-alpine | — | ✅ UP |
| paperless | ghcr.io/paperless-ngx/paperless-ngx:latest | 8089 | ✅ UP |
| paperless-db | postgres:16-alpine | — | ✅ UP |
| paperless-redis | redis:7-alpine | — | ✅ UP |
| immich-server | ghcr.io/immich-app/immich-server:release | 2283 | ✅ UP |
| immich-ml | ghcr.io/immich-app/immich-machine-learning:release | — | ✅ UP |
| immich-db | tensorchord/pgvecto-rs:pg16-v0.2.0 | — | ✅ UP |
| immich-redis | redis:7-alpine | — | ✅ UP |
| forgejo | codeberg.org/forgejo/forgejo:14 | 3001,222 | ✅ UP |
| vaultwarden | vaultwarden/server:latest | 8087 | ✅ UP |
| kopia | kopia/kopia:latest | 51515 | ✅ UP |
| ntfy | binwiederhier/ntfy:latest | 8091 | ✅ UP |
| excalidraw | excalidraw/excalidraw:latest | 8092 | ✅ UP |
| pingvin | stonith404/pingvin-share:latest | 3002 | ✅ UP |
| garage | dxflrs/garage:v1.0.0 | 3900-3902 | ⏸️ FERMATO (manca config) |

### Problemi noti risolti durante migrazione

| Problema | Causa | Fix applicato |
|---|---|---|
| n8n crash loop | Permessi /home/node/.n8n/config | `chown -R 1000:1000 /opt/homelab/n8n/data` |
| Garage crash loop | Manca /etc/garage.toml | Fermato — mai configurato, solo predisposto |
| DHCP non funzionava su VLAN | Dnsmasq ascoltava solo su re1 | Aggiunto TRUSTED e IOT alle listen interfaces |
| Regole DHCP firewall mancanti | PF non aveva bootps/bootpc su VLAN | Aggiunta regola pass UDP DHCP su TRUSTED e IOT |

---

## 5. Accesso ai servizi

### Da VLAN trusted (rete locale)

| URL | Servizio |
|---|---|
| http://10.0.10.20:3000 | Homepage Dashboard |
| http://10.0.10.20:3001 | Forgejo (Git) |
| http://10.0.10.20:5678 | n8n (Automazione) |
| http://10.0.10.20:8085 | Headscale |
| http://10.0.10.20:8086 | Headscale UI |
| http://10.0.10.20:8087 | Vaultwarden |
| http://10.0.10.20:8088 | Nextcloud |
| http://10.0.10.20:8089 | Paperless |
| http://10.0.10.20:8090 | Open WebUI (Ollama) |
| http://10.0.10.20:8091 | ntfy |
| http://10.0.10.20:8092 | Excalidraw |
| http://10.0.10.20:9000 | Portainer |
| http://10.0.10.20:2283 | Immich |
| http://10.0.10.20:19999 | Netdata |
| http://10.0.10.20:51515 | Kopia |
| http://10.0.10.20:81 | Nginx Admin |
| https://10.0.10.1 | OPNsense GUI |
| https://10.0.10.10:8006 | Proxmox GUI |

### Da Internet (dopo configurazione Nginx + DDNS)

| Sottodominio | Servizio | Stato |
|---|---|---|
| cloud.dominio.com | Nextcloud | 🔲 Da configurare |
| vault.dominio.com | Vaultwarden | 🔲 Da configurare |
| photos.dominio.com | Immich | 🔲 Da configurare |
| ntfy.dominio.com | ntfy | 🔲 Da configurare |
| git.dominio.com | Forgejo | 🔲 Da configurare (opzionale) |

### Da fuori casa (VPN Headscale)

| Metodo | Stato |
|---|---|
| Headscale su Nexus:8085 | ✅ Container attivo, 🔲 client non configurati |
| Port forward WAN:8085 → Nexus | ✅ Attivo |
| Laptop Tailscale client | 🔲 Da configurare |
| Mobile Tailscale client | 🔲 Da configurare |

---

## 6. TODO — In ordine di priorità

### 🔴 Priorità alta — Sicurezza

- [ ] **SSH key setup** — Generare chiave Ed25519 sul laptop, caricarla su OPNsense, Nexus e Torre. Poi disabilitare password auth e root login su OPNsense.
- [ ] **Cambiare password database Docker** — Le password nel compose sono ancora quelle di default (`nextcloud_secret`, `paperless_secret`, `n8n_secret`, `immich_secret`). Vanno cambiate e spostate nel `.env`.
- [ ] **Acquistare dominio e configurare DDNS** — Serve un dominio per i servizi pubblici e un servizio DDNS per l'IP dinamico Tiscali. Opzioni: Cloudflare (dominio) + plugin DDNS OPNsense.
- [ ] **Configurare Nginx Proxy Manager** — SSL Let's Encrypt per i 5 sottodomini pubblici. Attualmente NPM è attivo ma senza proxy host configurati.
- [ ] **Configurare DHCP statico** — Assegnare i MAC address di Nexus (10.0.10.20) e Torre (10.0.10.10) nel DHCP Dnsmasq. Attualmente funziona perché hanno IP statici nel loro OS, ma il DHCP statico aggiunge un livello di sicurezza.

### 🟠 Priorità media — Infrastruttura

- [ ] **Migrare Docker compose a struttura modulare** — Dal compose monolitico attuale alla struttura con stacks separati, `.env` centralizzato, path relativi, versioni fissate sui servizi critici, zero `container_name`. Il repo modulare è già generato e pronto.
- [ ] **Configurare Headscale + client** — Creare utente, generare auth key, installare Tailscale client su laptop, mobile e Torre. Testare accesso VPN da fuori casa.
- [ ] **Configurare Garage S3** — Creare il file `garage.toml`, inizializzare il nodo, creare bucket per Kopia backup. Attualmente fermato.
- [ ] **Setup iniziale servizi non configurati:**
  - [ ] Forgejo — creare primo utente admin, creare repo `homelab`
  - [ ] Vaultwarden — creare account admin, importare password
  - [ ] Nextcloud — setup wizard, configurare storage RAID
  - [ ] Paperless — creare utente, configurare OCR italiano
  - [ ] Immich — setup iniziale, creare utente
  - [ ] Kopia — configurare backup policy per i volumi Docker
- [ ] **Configurare Homepage dashboard** — Aggiornare `services.yaml` con i nuovi IP (10.0.10.x), aggiungere API key per i widget dei servizi.
- [ ] **Grafana + Loki + Promtail** — Nello stack di monitoring, Grafana/Loki/Promtail sono previsti nel compose modulare ma non ancora deployati.

### 🟢 Priorità bassa — Miglioramenti

- [ ] **VM Torre Intel** — Creare VM 101 (AI), VM 102 (DEV), VM 103 (AUDIT) come da piano originale.
- [ ] **Monitoraggio aggiornamenti** — RSS GitHub releases + notifiche via ntfy per i servizi critici.
- [ ] **Backup automatici** — Kopia schedulato per snapshot automatici dei volumi Docker verso Garage S3 o HDD esterno.
- [ ] **Aggiornare immagini Docker** — Il compose attuale usa `latest` su quasi tutti i servizi critici. La struttura modulare ha versioni fissate — applicare durante la migrazione.
- [ ] **Pulizia LAN untagged** — Rimuovere eventuali device residui dalla 192.168.1.0/24. A regime dovrebbe essere vuota tranne l'AP che ha preso 10.0.10.96 (verificare che sia su VLAN corretta).
- [ ] **UPS / continuità** — Valutare UPS per ZimaBoard e Nexus (always-on).

---

## 7. Lezioni apprese durante la migrazione

1. **Dnsmasq "Listen Interfaces"** — Anche se i range DHCP per le VLAN sono configurati nel config.xml, Dnsmasq non li serve se non è in ascolto su quelle interfacce. La GUI mostra "ALL" per Unbound DNS, non per Dnsmasq — sono due servizi separati.

2. **Regole DHCP firewall** — OPNsense genera automaticamente le regole bootps/bootpc solo per le interfacce dove Dnsmasq è attivo. Quando si aggiungono interfacce a posteriori, bisogna verificare che PF abbia le regole corrispondenti, oppure aggiungerle manualmente.

3. **Dispositivi con IP statico** — Nexus e Torre non chiedono DHCP perché hanno IP hardcoded nel loro OS. Spostarli su una nuova VLAN richiede accesso fisico per cambiare la configurazione di rete. Pianificare l'ordine: prima firewall e switch, poi i dispositivi uno alla volta.

4. **OPNsense 26.1 cambiamenti** — Port Forwarding rinominato in "Destination NAT". Le regole associate non vengono più create automaticamente — vanno scritte a mano sulla WAN. La nuova GUI firewall coesiste con quella legacy.

5. **Port range vs porte separate** — Nel firewall, `80-443` apre tutte le 364 porte nel range. Per aprire solo 80 e 443 servono due regole separate o un alias con le due porte.

---

*Questo documento è il punto di verità dell'infrastruttura. Aggiornare dopo ogni modifica.*