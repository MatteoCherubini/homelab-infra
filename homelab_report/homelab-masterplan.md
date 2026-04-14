# Homelab Masterplan — Implementazione Completa
*Generato: Aprile 2026 · Basato su struttura.md v3.0 + analisi config attuale*

---

## Stato attuale vs obiettivo

| Elemento | Stato attuale | Obiettivo |
|---|---|---|
| Nexus (server Docker) | LAN 192.168.1.20 (nessuna VLAN) | VLAN 10 trusted — 10.0.10.20 |
| Torre Intel (Proxmox) | LAN 192.168.1.10 (nessuna VLAN) | VLAN 10 trusted — 10.0.10.10 |
| Laptop (cavo) | DHCP LAN 192.168.1.x | DHCP VLAN 10 — 10.0.10.x |
| Interfacce VLAN | Chiamate OPT1/OPT2/OPT3 | Rinominare TRUSTED/IOT/DMZ |
| Firewall rules | Scheletro (pass any) | Regole granulari per servizio |
| LAN untagged | Pass any — completamente aperta | Solo management OPNsense |
| Nginx Proxy Manager | Su Nexus (VLAN trusted) | Resta su Nexus, proxy via VLAN 10 |
| Headscale VPN | Su Nexus porta 8085 | Port forward WAN → Nexus:8085 |
| DNS | Unbound attivo, no DNSSEC | DNSSEC on, regole DNS esplicite |
| SSH OPNsense | Root login + password | Solo key auth, no root |

---

## Fase 0 — Prerequisiti hardware

### Switch TP-Link TL-SG108E — configurazione VLAN 802.1Q

Prima di spostare qualsiasi dispositivo, lo switch deve essere configurato:

| Porta switch | Dispositivo | VLAN mode | VLAN ID |
|---|---|---|---|
| 1 | ZimaBoard (re1) | Trunk (tagged 10,20,30 + untagged 1) | ALL |
| 2 | AMD Nexus | Access (untagged) | 10 |
| 3 | Torre Intel | Access (untagged) | 10 |
| 4 | Laptop (cavo) | Access (untagged) | 10 |
| 5 | TV / Smart devices | Access (untagged) | 20 |
| 6 | Altri IoT | Access (untagged) | 20 |
| 7 | Libera | — | — |
| 8 | Libera | — | — |

**PVID (Port VLAN ID)**: ogni porta access ha il PVID impostato al suo VLAN ID.
La porta 1 (trunk) ha PVID=1 (LAN management).

---

## Fase 1 — OPNsense: rinominare e pulire

### 1.1 Rinominare interfacce

In OPNsense GUI → Interfaces → Assignments:

| Nome attuale | Nuovo nome | Interfaccia |
|---|---|---|
| OPT1 | TRUSTED | vlan0.10 |
| OPT2 | IOT | vlan0.20 |
| OPT3 | DMZ | vlan0.30 |

### 1.2 Timezone

System → General → Timezone: `Europe/Rome` (attualmente `Etc/UTC`)

### 1.3 SSH hardening

System → Settings → Administration:
- Permit root login: **OFF**
- Password auth: **OFF** (dopo aver caricato la chiave pubblica)
- Listen interfaces: **LAN + TRUSTED** (non WAN)

### 1.4 Unbound DNS

Services → Unbound DNS:
- DNSSEC: **ON**
- Listen interfaces: LAN, TRUSTED, IOT (non DMZ — la DMZ non ha bisogno di DNS interno)

---

## Fase 2 — Alias OPNsense

Creare questi alias prima di scrivere le regole. Sono la base di tutto.

### Alias di rete

| Nome alias | Tipo | Contenuto | Descrizione |
|---|---|---|---|
| SERVER_NEXUS | Host | 10.0.10.20 | Server Docker AMD |
| SERVER_TORRE | Host | 10.0.10.10 | Proxmox host |
| TRUSTED_NET | Network | 10.0.10.0/24 | Rete trusted |
| IOT_NET | Network | 10.0.20.0/24 | Rete IoT |
| DMZ_NET | Network | 10.0.30.0/24 | Rete DMZ |
| RFC1918 | Network | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 | Tutte le reti private |

### Alias porte — servizi Nexus raggiungibili da trusted

| Nome alias | Tipo | Contenuto | Descrizione |
|---|---|---|---|
| NEXUS_WEB_SERVICES | Port | 3000,3001,3002,5678,8086,8087,8088,8089,8090,8091,8092,9000,2283,19999,51515,3003 | Tutte le UI web Docker |
| NEXUS_INFRA | Port | 8085,11434,3900,3901,3902 | API e infrastruttura (Headscale, Ollama, Garage) |
| NEXUS_GIT_SSH | Port | 222 | Forgejo SSH |
| PROXMOX_MGMT | Port | 8006 | GUI Proxmox |
| DNS_PORT | Port | 53 | DNS |
| VPN_HEADSCALE | Port | 8085 | Headscale coordination |

### Alias porte — servizi esposti via reverse proxy

| Nome alias | Tipo | Contenuto | Descrizione |
|---|---|---|---|
| PUBLIC_SERVICES | Port | 80,443 | HTTP/HTTPS in ingresso |

---

## Fase 3 — Regole firewall per interfaccia

### Filosofia: default deny, allow esplicito

Ogni interfaccia ha come ultima regola implicita un **block all**.
Le regole sono ordinate: deny specifici → allow specifici → deny finale.

Per la ZimaBoard con 2GB RAM: **niente IDS/IPS** (Suricata mangia troppo).
Il filtraggio si fa tutto con PF stateful — leggero e veloce.

---

### 3.1 WAN (re0) — Ingresso da Internet

| # | Azione | Proto | Sorgente | Dest | Porta dest | Descrizione |
|---|---|---|---|---|---|---|
| 1 | PASS | TCP | any | WAN address | 443 | HTTPS → Nginx (port forward) |
| 2 | PASS | UDP | any | WAN address | 8085 | Headscale WireGuard (port forward) |
| — | BLOCK | * | any | any | any | Default deny (implicito) |

**NAT / Port Forward associati:**

| Proto | WAN port | Dest interno | Porta dest | Descrizione |
|---|---|---|---|---|
| TCP | 443 | 10.0.10.20 (Nexus) | 443 | HTTPS → Nginx Proxy Manager |
| UDP | 8085 | 10.0.10.20 (Nexus) | 8085 | Headscale VPN coordination |

> **Nota**: solo 2 porte aperte verso Internet. Tutto il resto passa per VPN (Headscale) o per il reverse proxy HTTPS.

---

### 3.2 LAN (re1 untagged) — Management only

Dopo la migrazione, la LAN untagged serve solo per accesso di emergenza al firewall.

| # | Azione | Proto | Sorgente | Dest | Porta dest | Descrizione |
|---|---|---|---|---|---|---|
| 1 | PASS | TCP | LAN net | This firewall | 443 | GUI OPNsense |
| 2 | PASS | TCP | LAN net | This firewall | 22 | SSH emergenza |
| 3 | PASS | UDP/TCP | LAN net | This firewall | 53 | DNS (per DHCP residui) |
| 4 | BLOCK | * | LAN net | RFC1918 | any | No accesso a reti interne |
| 5 | PASS | * | LAN net | any | any | Internet (se servono device temporanei) |
| — | BLOCK | * | any | any | any | Default deny |

---

### 3.3 TRUSTED (VLAN 10) — Accesso completo ma consapevole

| # | Azione | Proto | Sorgente | Dest | Porta dest | Descrizione |
|---|---|---|---|---|---|---|
| 1 | PASS | UDP/TCP | TRUSTED net | This firewall | 53 | DNS |
| 2 | PASS | TCP | TRUSTED net | This firewall | 443 | GUI OPNsense |
| 3 | PASS | TCP | TRUSTED net | This firewall | 22 | SSH OPNsense |
| 4 | PASS | TCP | TRUSTED net | SERVER_NEXUS | NEXUS_WEB_SERVICES | UI web servizi |
| 5 | PASS | TCP/UDP | TRUSTED net | SERVER_NEXUS | NEXUS_INFRA | API infrastruttura |
| 6 | PASS | TCP | TRUSTED net | SERVER_NEXUS | NEXUS_GIT_SSH | Git SSH |
| 7 | PASS | TCP | TRUSTED net | SERVER_NEXUS | 22 | SSH Nexus |
| 8 | PASS | TCP | TRUSTED net | SERVER_TORRE | PROXMOX_MGMT | Proxmox GUI |
| 9 | PASS | TCP | TRUSTED net | SERVER_TORRE | 22 | SSH Proxmox |
| 10 | BLOCK | * | TRUSTED net | IOT_NET | any | No trusted → IoT |
| 11 | BLOCK | * | TRUSTED net | DMZ_NET | any | No trusted → DMZ |
| 12 | PASS | * | TRUSTED net | any | any | Internet libero |
| — | BLOCK | * | any | any | any | Default deny |

> **Perché bloccare trusted → IoT/DMZ?** Se un laptop trusted è compromesso, non deve poter attaccare lateralmente IoT o DMZ. Il traffico verso i servizi passa comunque per Nexus (che è in trusted), non per le altre VLAN.

---

### 3.4 IOT (VLAN 20) — Solo Internet, solo HTTPS + DNS

| # | Azione | Proto | Sorgente | Dest | Porta dest | Descrizione |
|---|---|---|---|---|---|---|
| 1 | PASS | UDP/TCP | IOT net | This firewall | 53 | DNS |
| 2 | BLOCK | * | IOT net | RFC1918 | any | No accesso reti private |
| 3 | PASS | TCP | IOT net | any | 80 | HTTP (aggiornamenti firmware) |
| 4 | PASS | TCP | IOT net | any | 443 | HTTPS (cloud IoT) |
| 5 | PASS | UDP | IOT net | any | 123 | NTP (orologi IoT) |
| — | BLOCK | * | any | any | any | Default deny |

> **Nota critica**: la regola 2 (block RFC1918) PRIMA delle pass internet. Così un IoT compromesso non può raggiungere nessuna rete interna, ma può comunque uscire su Internet per i suoi cloud. NTP aggiunto perché molti IoT non funzionano senza.

---

### 3.5 DMZ (VLAN 30) — Attualmente vuota

La DMZ nella tua architettura attuale è **inutilizzata**: Nginx Proxy Manager gira su Nexus in VLAN 10, non in DMZ.

**Due opzioni:**

**Opzione A — DMZ eliminata (consigliata per semplicità):**
Non servire nulla dalla DMZ. Il reverse proxy resta su Nexus. I port forward WAN puntano direttamente a Nexus:443. La VLAN 30 viene disabilitata.

**Opzione B — DMZ attiva (se vuoi isolare il proxy):**
Sposti un'istanza di Nginx Proxy Manager su un dispositivo dedicato in VLAN 30 (es. un container LXC su Proxmox, o un Raspberry Pi). Il port forward WAN punta alla DMZ, e la DMZ fa reverse proxy verso i servizi su VLAN 10.

**Raccomandazione**: Opzione A. Con una ZimaBoard da 2GB non hai bisogno di complessità aggiuntiva. Il reverse proxy su Nexus è già isolato dai container Docker e protetto dal firewall. La DMZ ha senso quando esponi server web dedicati, non quando tutto passa per un reverse proxy.

Se scegli A, le regole DMZ diventano semplicemente:

| # | Azione | Proto | Sorgente | Dest | Porta dest | Descrizione |
|---|---|---|---|---|---|---|
| 1 | BLOCK | * | DMZ net | any | any | Nessun traffico (VLAN parcheggiata) |

---

## Fase 4 — Mappa porte definitiva

### Nexus (10.0.10.20) — Porte esposte su VLAN trusted

| Porta | Servizio | Proto | Chi accede | Esposto a Internet? |
|---|---|---|---|---|
| 22 | SSH Ubuntu | TCP | trusted | No (solo via VPN) |
| 80 | Nginx HTTP | TCP | trusted | Sì (port forward WAN:443→Nexus:443) |
| 81 | Nginx Admin | TCP | trusted | **No** — solo rete locale |
| 443 | Nginx HTTPS | TCP | trusted + WAN | Sì (entry point pubblico) |
| 222 | Forgejo SSH | TCP | trusted | No (solo via VPN) |
| 2283 | Immich | TCP | trusted | Sì (via Nginx reverse proxy) |
| 3000 | Homepage | TCP | trusted | No |
| 3001 | Forgejo Web | TCP | trusted | Opzionale (via Nginx) |
| 3002 | Pingvin Share | TCP | trusted | Opzionale (via Nginx) |
| 3003 | Grafana | TCP | trusted | No |
| 3900-3902 | Garage S3 | TCP | trusted | No |
| 5678 | n8n | TCP | trusted | No |
| 8085 | Headscale | TCP+UDP | trusted + WAN | Sì (port forward WAN:8085) |
| 8086 | Headscale UI | TCP | trusted | No |
| 8087 | Vaultwarden | TCP | trusted | Sì (via Nginx reverse proxy) |
| 8088 | Nextcloud | TCP | trusted | Sì (via Nginx reverse proxy) |
| 8089 | Paperless | TCP | trusted | Opzionale (via Nginx) |
| 8090 | Open WebUI | TCP | trusted | No |
| 8091 | ntfy | TCP | trusted | Sì (via Nginx reverse proxy) |
| 8092 | Excalidraw | TCP | trusted | No |
| 9000 | Portainer | TCP | trusted | No |
| 11434 | Ollama API | TCP | trusted | No (solo via VPN) |
| 19999 | Netdata | TCP | trusted | No |
| 51515 | Kopia | TCP | trusted | No |

### Servizi raggiungibili da Internet (via Nginx reverse proxy su Nexus:443)

| Sottodominio | Servizio interno | Porta interna | Motivo esposizione |
|---|---|---|---|
| cloud.tuodominio.com | Nextcloud | 8088 | Sync file da mobile/laptop |
| vault.tuodominio.com | Vaultwarden | 8087 | Password da ovunque |
| photos.tuodominio.com | Immich | 2283 | Backup foto mobile |
| ntfy.tuodominio.com | ntfy | 8091 | Notifiche push |
| git.tuodominio.com | Forgejo | 3001 | Webhook CI/CD (opzionale) |

> **Tutto il resto** (Homepage, Portainer, Netdata, n8n, Ollama, Grafana, Kopia, Excalidraw, Garage) è accessibile **solo da VLAN trusted o via VPN Headscale**. Zero esposizione pubblica.

### Torre Intel (10.0.10.10) — Porte esposte su VLAN trusted

| Porta | Servizio | Proto | Esposto a Internet? |
|---|---|---|---|
| 22 | SSH Proxmox | TCP | No |
| 8006 | Proxmox GUI | TCP | No |

### Accesso da fuori casa — Strategia VPN-first

```
Laptop field / Mobile
    ↓ Internet
    ↓ WireGuard (porta 8085 UDP)
Headscale su Nexus (10.0.10.20)
    ↓ rete mesh 100.64.x.x
    ├── Nexus: tutti i servizi Docker (accesso diretto)
    ├── Torre: Proxmox GUI + SSH
    └── OPNsense: GUI + SSH (se Headscale client installato)
```

**Regola d'oro**: se un servizio non ha bisogno di accesso pubblico anonimo, passa per VPN. Solo Nextcloud, Vaultwarden, Immich e ntfy meritano esposizione pubblica perché servono alle app mobile che non supportano VPN nativa.

---

## Fase 5 — DHCP statico per VLAN

### Dnsmasq — assegnazioni statiche

| VLAN | IP | MAC | Hostname | Note |
|---|---|---|---|---|
| 10 | 10.0.10.10 | (MAC Torre) | torre | Proxmox host |
| 10 | 10.0.10.20 | (MAC Nexus) | nexus | Docker server |
| 10 | 10.0.10.50-99 | DHCP pool | — | Laptop e dispositivi trusted |
| 20 | 10.0.20.100-200 | DHCP pool | — | IoT devices |

> **DHCP range VLAN 10**: 10.0.10.50 → 10.0.10.99 (non 100-200 come ora — lasci spazio per altri server statici futuri)

---

## Fase 6 — Piano di migrazione (ordine esecuzione)

### Step 1: Preparazione (senza downtime)

- [ ] Configurare switch TP-Link con VLAN 802.1Q (tabella Fase 0)
- [ ] Rinominare interfacce OPNsense: OPT1→TRUSTED, OPT2→IOT, OPT3→DMZ
- [ ] Creare tutti gli alias in OPNsense (tabella Fase 2)
- [ ] Impostare timezone Europe/Rome
- [ ] Configurare DHCP statico per Nexus (10.0.10.20) e Torre (10.0.10.10)

### Step 2: Regole firewall (senza downtime)

- [ ] Scrivere tutte le regole TRUSTED (Fase 3.3)
- [ ] Scrivere tutte le regole IOT (Fase 3.4)
- [ ] Scrivere regole DMZ (block all se Opzione A)
- [ ] Scrivere regole LAN ridotte (Fase 3.2)
- [ ] **Non applicare ancora** — solo salvare

### Step 3: Port forward WAN (senza downtime)

- [ ] Creare port forward WAN:443 → 10.0.10.20:443 (Nginx)
- [ ] Creare port forward WAN:8085 → 10.0.10.20:8085 (Headscale)
- [ ] Creare regole WAN associate (Fase 3.1)

### Step 4: Migrazione Nexus (breve downtime ~5 min)

- [ ] SSH su Nexus, ferma tutti i container: `docker compose down`
- [ ] Cambia IP statico in netplan: 10.0.10.20/24, gateway 10.0.10.1, DNS 10.0.10.1
- [ ] Collegare il cavo Nexus alla porta switch assegnata a VLAN 10
- [ ] `netplan apply`
- [ ] Verifica ping 10.0.10.1 (gateway) e 8.8.8.8 (internet)
- [ ] Aggiorna `.env` del docker compose: HOMEPAGE_ALLOWED_HOSTS, NEXTCLOUD_TRUSTED_DOMAINS
- [ ] `docker compose up -d`
- [ ] Verifica tutti i servizi da un dispositivo su VLAN 10

### Step 5: Migrazione Torre (breve downtime ~2 min)

- [ ] Cambia IP statico in Proxmox: 10.0.10.10/24, gateway 10.0.10.1
- [ ] Collegare cavo alla porta switch VLAN 10
- [ ] Verifica accesso Proxmox GUI su https://10.0.10.10:8006

### Step 6: Applicare regole firewall

- [ ] Applicare le regole preparate allo Step 2
- [ ] Testare da VLAN trusted: accesso a tutti i servizi Nexus
- [ ] Testare da IoT: verifica che NON raggiunge 10.0.10.0/24
- [ ] Testare da LAN untagged: verifica accesso solo a OPNsense GUI

### Step 7: Hardening finale

- [ ] SSH OPNsense: disabilita root login e password auth
- [ ] Abilita DNSSEC su Unbound
- [ ] Configura Nginx Proxy Manager con Let's Encrypt per i domini pubblici
- [ ] Configura Headscale e connetti laptop + mobile
- [ ] Testa accesso VPN da fuori casa

### Step 8: Docker compose aggiornamento

- [ ] Applicare la nuova struttura modulare con `.env` aggiornato:
  - `DATA_ROOT=/opt/homelab/data`
  - `MEDIA_ROOT=/mnt/md0/homelab_data`
  - Tutte le password cambiate da "CHANGE_ME" a valori reali
  - `NEXTCLOUD_TRUSTED_DOMAINS=cloud.tuodominio.com 10.0.10.20`
  - `HOMEPAGE_ALLOWED_HOSTS=10.0.10.20:3000`

---

## Riepilogo sicurezza finale

| Superficie di attacco | Prima | Dopo |
|---|---|---|
| Porte aperte su Internet | 0 (ma nessuna protezione interna) | 2 (443 HTTPS + 8085 Headscale) |
| Segmentazione rete | Nessuna (tutto su LAN flat) | 3 VLAN isolate |
| IoT → Server | Accesso libero | Bloccato (block RFC1918) |
| Password nel compose | In chiaro | In .env (gitignored) |
| DNS | No validazione | DNSSEC attivo |
| SSH firewall | Root + password | Key-only, no root |
| Accesso remoto | Nessuno configurato | VPN Headscale mesh |
| Servizi pubblici | 0 | 5 (via Nginx + SSL + VPN fallback) |

---

*Questo documento è il piano esecutivo. Ogni step è indipendente e reversibile.*