# Homelab Infrastructure — Resoconto Completo
*Aggiornato: Aprile 2026 · Versione 3.0*

---

## Indice

1. [Topologia generale](#1-topologia-generale)
2. [ZimaBoard — Firewall OPNsense](#2-zimaboard--firewall-opnsense)
3. [AMD Nexus — Server always-on](#3-amd-nexus--server-always-on)
4. [Torre Intel — Proxmox + VM](#4-torre-intel--proxmox--vm)
5. [Dell Latitude 7430 — Laptop field](#5-dell-latitude-7430--laptop-field)
6. [Distribuzione storage completa](#6-distribuzione-storage-completa)
7. [Rete e firewall — logica e porte](#7-rete-e-firewall--logica-e-porte)
8. [Flusso operativo dal campo](#8-flusso-operativo-dal-campo)

---

## 1. Topologia Generale

```
Internet (Tiscali FTTH OpenFiber)
    ↓
Modem (passthrough)
    ↓
┌─────────────────────────────────────┐
│  ZimaBoard — OPNsense Firewall      │
│  WAN: re0 → modem                   │
│  LAN: re1 → switch                  │
└─────────────────────────────────────┘
    ↓
Switch TP-Link TL-SG108E (managed, 802.1Q VLAN)
    ↓
    ├── VLAN 10 (trusted)  → Torre Intel · AMD Nexus · Laptop
    ├── VLAN 20 (IoT)      → TV · telefoni · smart devices
    └── VLAN 30 (DMZ)      → Nginx Proxy Manager (servizi pubblici)
```

---

## 2. ZimaBoard — Firewall OPNsense

### Hardware

| Componente | Dettaglio |
|---|---|
| CPU | Intel Celeron N3350 (2 core, 1.1-2.4GHz) |
| RAM | 2GB DDR4 |
| Rete | 2× GbE onboard (re0 WAN, re1 LAN) |
| Storage | SSD SATA 256GB |
| Consumo | ~10W idle |
| OS | OPNsense 24.x (UFS — ZFS escluso per RAM insufficiente) |

### Ruolo

Firewall perimetrale always-on. Gestisce tutto il traffico in entrata e uscita, separa le VLAN, fa da gateway per tutta la rete domestica e di lavoro.

### Configurazione rete

```
WAN (re0):  DHCP da modem Tiscali — IP dinamico
LAN (re1):  192.168.1.1/24 — gateway per tutti i dispositivi
VLAN 10:    10.0.10.1/24 — trusted (Torre, AMD, Laptop)
VLAN 20:    10.0.20.1/24 — IoT (dispositivi non fidati)
VLAN 30:    10.0.30.1/24 — DMZ (servizi esposti pubblicamente)
```

### Servizi attivi su OPNsense

| Servizio | Funzione |
|---|---|
| DHCP (Dnsmasq) | Assegna IP a tutti i dispositivi per VLAN |
| DNS resolver | Risoluzione DNS locale e forwarding |
| NAT Hybrid Outbound | Necessario per WireGuard/Headscale NAT traversal |
| Firewall rules | Isolamento VLAN, blocco IoT→trusted |
| Monit watchdog | Rinnovo automatico DHCP WAN se connessione cade |
| Cron watchdog | `configctl interface newip re0` ogni 5 minuti |

### Regole firewall per VLAN

**VLAN 10 — Trusted:** accesso libero a tutto. AMD, Torre e Laptop si vedono tra loro e accedono a Internet senza restrizioni.

**VLAN 20 — IoT:** vede solo Internet. Non può raggiungere VLAN 10 (trusted) né VLAN 30 (DMZ). Se un dispositivo IoT viene compromesso non può attaccare i server.

**VLAN 30 — DMZ:** solo traffico TCP su 80 e 443 verso Internet. Nessun accesso alle VLAN interne. Qui sta Nginx Proxy Manager che espone i servizi pubblici.

### Storage ZimaBoard

```
SSD 256GB → OPNsense OS + log + stato firewall
            (4GB usati, 252GB liberi — sovradimensionato ma già disponibile)
```

### Problema noto e soluzione

Dopo download molto pesanti o riavvio del modem, OPNsense occasionalmente non rinnova il lease DHCP sulla WAN autonomamente. Soluzione applicata:
- **Monit:** ping 8.8.8.8 ogni ciclo, se fallisce 3 volte esegue `configctl interface newip re0`
- **Cron:** stesso comando ogni 5 minuti come fallback
- **Emergenza remota:** riavvio ZimaBoard via SSH da Headscale

---

## 3. AMD Nexus — Server Always-On

### Hardware

| Componente | Dettaglio |
|---|---|
| CPU | AMD Ryzen 5 3600 (6C/12T, 3.6-4.2GHz) |
| RAM | 16GB DDR4 |
| GPU | NVIDIA GTX 1660 Super 6GB GDDR6 |
| NIC | 1× GbE onboard |
| Consumo | ~55-60W idle |
| OS | Ubuntu Server 24.04 LTS (minimale, no UI) |
| Hostname | nexus |
| IP | 192.168.1.20 (temporaneo → 10.0.10.10 con VLAN) |

### Ruolo

Server always-on — mai spento. Ospita tutti i servizi Docker, la VPN mesh Headscale, lo storage dei dati, e l'AI inference di primo livello (modelli 7B sulla GTX 1660 Super).

### Storage

```
SSD SATA 512GB  → /         Ubuntu OS
                → /opt/homelab/    config Docker, database leggeri,
                                   volumi PostgreSQL, Redis, config

HDD 4TB × 2     → RAID 1 mdadm → /mnt/md0/homelab_data/
  (/dev/md0)      Forgejo repo, Nextcloud files, Paperless media,
                  Immich foto/video, Garage S3 data,
                  ntfy, Pingvin Share
```

### Stack Docker (27 container)

**Infrastruttura:**

| Container | Porta | Funzione |
|---|---|---|
| nginx | 80, 443, 81 | Nginx Proxy Manager — reverse proxy SSL |
| headscale | 8085 | VPN mesh WireGuard self-hosted |
| headscale-ui | 8086 | GUI web per Headscale |
| portainer | 9000 | GUI gestione Docker |
| netdata | 19999 | Monitoring sistema real-time |
| homepage | 3000 | Dashboard unificata |

**AI & Automazione:**

| Container | Porta | Funzione |
|---|---|---|
| ollama | 11434 | Inference LLM (GTX 1660 Super) |
| open-webui | 8090 | Chat UI per Ollama |
| n8n | 5678 | Workflow automation |
| n8n-db | — | PostgreSQL per n8n |

**Storage & Documenti:**

| Container | Porta | Funzione |
|---|---|---|
| nextcloud | 8088 | Storage file e sync |
| nextcloud-db | — | PostgreSQL |
| nextcloud-redis | — | Cache |
| paperless | 8089 | Archivio documenti + OCR ITA/ENG |
| paperless-db | — | PostgreSQL |
| paperless-redis | — | Cache |
| immich-server | 2283 | Gestione foto e video |
| immich-ml | — | Machine learning riconoscimento foto |
| immich-db | — | pgvecto-rs (PostgreSQL + vettori) |
| immich-redis | — | Cache |
| garage | 3900-3902 | Object storage S3-compatible |
| kopia | 51515 | Backup snapshot Docker volumes |

**Sviluppo & Sicurezza:**

| Container | Porta | Funzione |
|---|---|---|
| forgejo | 3001, 222 | Git repository self-hosted |
| vaultwarden | 8087 | Password manager (Bitwarden compat.) |

**Strumenti:**

| Container | Porta | Funzione |
|---|---|---|
| ntfy | 8091 | Notifiche push |
| excalidraw | 8092 | Lavagna virtuale collaborativa |
| pingvin | 3002 | File sharing temporaneo |

### GPU AMD — capacità AI

La GTX 1660 Super con 6GB VRAM gestisce:
- **Mistral 7B Q4_K_M** (~4.5GB) — modello principale per chat e report
- **Phi-3 Mini** (~2GB) — modello veloce per task semplici
- Non può girare modelli 13B+ (VRAM insufficiente)

Modelli più grandi (Mistral Nemo 12B, Phi-4 14B) girano sulla VM-AI della Torre Intel con RTX 5060 Ti 16GB, attivata on-demand.

---

## 4. Torre Intel — Proxmox + VM

### Hardware Host

| Componente | Dettaglio |
|---|---|
| CPU | Intel Core Ultra 7 265K (8 P-core + 12 E-core = 20 core, 5.5GHz turbo) |
| RAM | 64GB DDR5 6000MHz |
| GPU | RTX 5060 Ti 16GB GDDR7 (GB206, Blackwell) — in passthrough alle VM |
| NIC usata | Intel i210-T1 PCIe (igb) — stabile |
| NIC ignorata | Realtek RTL8125 onboard — causa lockup, blacklistata |
| WiFi | MT7925e (WiFi7 + BT 5.4) — in passthrough alla VM gaming |
| OS Host | Proxmox VE 9 (Debian Trixie) |
| IP | 192.168.1.10 |

### Storage Torre

```
NVMe 1TB (Kingston Fury Renegade)  → Proxmox OS + pool LVM-Thin VM
HDD 1TB (Toshiba)                  → PBS snapshots + Jellyfin media
SSD 512GB (Silicon Power)          → datastore ISO
```

### Configurazione GRUB kernel

```
intel_iommu=on    → IOMMU per GPU passthrough
pcie_aspm=off     → RTX Blackwell instabile con ASPM
pci=noaer         → riduce rumore log PCIe
```

> **CRITICO:** nessun `iommu=pt` — mette i gruppi IOMMU in modalità identity
> e rende il GPU passthrough impossibile. Il tipo corretto è `DMA-FQ`.

### Allocazione CPU — Arrow Lake

```
Thread 0-7   = 8 P-core (Performance core, 5.5GHz)
               → VM gaming, VM AI (isolcpus rimosso per compatibilità KVM)
Thread 8-19  = 12 E-core (Efficiency core, 4.2GHz)
               → VM DEV, VM AUDIT, processi Proxmox host
```

### VM configurate

#### VM 100 — win-gaming (Windows 11 Pro)

**Scopo:** gaming, produttività Windows, Sunshine/Moonlight streaming

| Risorsa | Valore | Note |
|---|---|---|
| CPU | 8 core host | P-core, affinity 0-7 |
| RAM | 48GB | memory-backend-memfd, no balloon |
| Disco | 500GB virtio | LVM-Thin, writeback, iothread |
| GPU | RTX 5060 Ti 16GB | passthrough PCIe, x-vga=1 |
| Audio GPU | NVIDIA HDMI | passthrough PCIe |
| WiFi/BT | MT7925e | passthrough PCIe — WiFi7 + BT 5.4 |
| USB ctrl | Intel 80:14.0 | passthrough PCIe — hotplug fisico nativo |
| Tastiera | Razer Cynosa | USB diretto 1532:023f |
| Mouse | GXT 158 | USB diretto 1ea7:0030 |
| Gamepad | Xbox 360 | USB diretto 045e:028e |
| BT dongle | 0489:e124 | USB diretto — BT aggiuntivo |
| Monitor | KTC 27" 2K 200Hz | collegato direttamente a RTX |

**Hyper-V flags:**
```
hv_relaxed, hv_spinlocks=0x1fff, hv_vapic, hv_time,
hv_vendor_id=proxmox12345, hv_frequencies, hv_reenlightenment,
hv_vpindex, hv_tlbflush, hv_ipi
```
> `hv_vendor_id=proxmox12345` — non `AuthenticAMD` (confonde scheduler Intel)
> e non il default KVM (blocca anti-cheat). Generico e neutro.

**Memoria:** `memory-backend-memfd` invece di allocazione standard —
necessario con GPU passthrough VFIO per evitare OOM. `numa: 0` per
evitare conflitto con il nodo NUMA definito negli args.

**Problema MiniFuse 2:** la scheda audio Arturia MiniFuse 2 (1c75:af90)
deve essere aggiunta come `usb4: host=1c75:af90`. Il controller USB
fisico passato (80:14.0) gestisce l'hotplug di qualsiasi dispositivo
collegato fisicamente alle porte del case.

---

#### VM 101 — VM-AI (Ubuntu 22.04 + kernel 6.14) — DA CREARE

**Scopo:** Ollama con modelli grandi (Mistral Nemo 12B, Phi-4 14B),
ChromaDB per RAG, inferenza AI di qualità elevata on-demand.

| Risorsa | Valore | Note |
|---|---|---|
| CPU | 8 core host | P-core, stessi della gaming (mai contemporanea) |
| RAM | 48GB | no balloon |
| Disco | 100GB | per modelli AI |
| GPU | RTX 5060 Ti 16GB | passthrough — stessa della gaming |
| Avvio | on-demand | mai contemporanea a VM gaming |

Con 16GB VRAM gestisce:
- Mistral Nemo 12B Q4_K_M (~7.1GB) — 47 tok/sec
- Phi-4 14B Q4_K_M (~8.5GB)
- Context window: 16k-32k token

---

#### VM 102 — VM-DEV (Ubuntu 24.04) — DA CREARE

**Scopo:** sviluppo software — VS Code, Docker, Angular, Node.js, test

| Risorsa | Valore | Note |
|---|---|---|
| CPU | 8 E-core | thread 8-15 |
| RAM | 8GB | |
| Disco | 80GB | |
| GPU | nessuna | usa iGPU Arc del 265K |
| Avvio | always-on | gira sempre in background |

---

#### VM 103 — VM-AUDIT (Parrot OS Security) — DA CREARE

**Scopo:** audit di rete, Wireshark, Nmap, importazione snapshot PBS,
ambienti di test isolati.

| Risorsa | Valore | Note |
|---|---|---|
| CPU | 4 E-core | thread 16-19 |
| RAM | 4GB | |
| Disco | 40GB | |
| GPU | nessuna | |
| Avvio | on-demand | |

---

### Scheduler VM — logica

Le VM gaming e AI **non girano mai contemporaneamente** — condividono
la stessa RTX 5060 Ti. La VM-DEV gira sempre. La VM-AUDIT si avvia
on-demand.

n8n su AMD gestirà lo switch automatico:
- Webhook "avvia gaming" → ferma VM-AI → avvia VM gaming
- Webhook "avvia AI" → ferma VM gaming → avvia VM AI

```bash
# Esempio manuale switch
qm stop 101   # ferma VM-AI
qm start 100  # avvia gaming

qm stop 100   # ferma gaming
qm start 101  # avvia VM-AI
```

---

## 5. Dell Latitude 7430 — Laptop Field

### Hardware

| Componente | Dettaglio |
|---|---|
| CPU | Intel Core i5-1235U |
| RAM | 16GB DDR5 |
| Storage | NVMe 512GB |
| NIC | USB-C → GbE adapter (field bridge) |
| WiFi | Intel AX211 |
| Audio | Arturia MiniFuse 2 (USB class-compliant) |
| OS principale | Ubuntu Studio 24.04 LTS (RT kernel) |
| OS field | Parrot OS Security (Live USB Kingston DT Max 256GB) |

### Ruolo

Macchina da lavoro portatile. Due modalità operative:

**Modalità sviluppo (Ubuntu Studio):**
VS Code, Angular, Docker, GitKraken, produzione audio con MiniFuse 2.

**Modalità field/audit (Parrot OS da USB):**
Audit reti clienti, scansioni vulnerability, generazione report.
Tutto gira da chiavetta LUKS cifrata — se persa, i dati sono illeggibili.

### Chiavetta USB field (Kingston DT Max 256GB)

```
Struttura Ventoy:
├── Parrot-security-amd64.iso    → ISO gold master
├── persistence.dat (LUKS)       → ambiente persistente cifrato
└── bootstrap.sh                 → recovery in emergenza
```

Boot: Ventoy → Parrot OS con persistence cifrata LUKS.
Passphrase LUKS richiesta ad ogni avvio — senza di essa il drive è inutilizzabile.

### Tool field installati

```
netaudit.sh   → scansione rete completa (nmap, vulnerability, traffico)
netreport.sh  → report HTML con analisi AI via Ollama remoto
netfix.sh     → correzioni interattive (SMBv1, DNS, printer queue, ecc.)
bootstrap.sh  → recovery ambiente da zero in 10 minuti
```

---

## 6. Distribuzione Storage Completa

### Vista d'insieme

```
┌─────────────────────────────────────────────────────────────────────┐
│ ZIMABOARD                                                           │
│   SSD 256GB  → OPNsense OS + log                                   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ AMD NEXUS                                                           │
│   SSD 512GB  → Ubuntu OS + /opt/homelab (config Docker + DB)       │
│   HDD 4TB ╗                                                        │
│   HDD 4TB ╝  RAID 1 → /mnt/md0/homelab_data (dati persistenti)    │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ TORRE INTEL                                                         │
│   NVMe 1TB   → Proxmox OS + LVM-Thin pool (tutte le VM)            │
│               ├── VM 100 disco: 500GB (Windows 11)                 │
│               ├── VM 101 disco: 100GB (AI) — futuro                │
│               ├── VM 102 disco: 80GB  (DEV) — futuro               │
│               └── VM 103 disco: 40GB  (AUDIT) — futuro             │
│   HDD 1TB    → PBS snapshots + Jellyfin media library              │
│   SSD 512GB  → ISO repository (Windows, Ubuntu, Parrot, ecc.)      │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ LAPTOP                                                              │
│   NVMe 512GB → Ubuntu Studio OS + workspace sviluppo               │
│   USB 256GB  → Parrot OS field (LUKS persistence)                  │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ CASSETTO (cold backup)                                              │
│   HDD 1TB    → backup manuale periodico dati critici               │
└─────────────────────────────────────────────────────────────────────┘
```

### Logica di separazione SSD vs RAID su AMD

| Tipo dato | Dove | Motivo |
|---|---|---|
| Config Docker, Compose | SSD | accesso frequente, velocità |
| Database PostgreSQL | SSD | I/O random intenso, latenza bassa |
| Redis cache | SSD | in-memory ma persistenza su SSD |
| File utenti (Nextcloud) | RAID | grandi, rari, sicurezza dati |
| Foto/video (Immich) | RAID | enormi, raramente scritti |
| Documenti (Paperless) | RAID | archivio permanente |
| Repository Git (Forgejo) | RAID | critici, backup necessario |
| Object storage (Garage) | RAID | grandi blob |

---

## 7. Rete e Firewall — Logica e Porte

### Schema VLAN

```
192.168.1.0/24  → LAN principale (dispositivi senza VLAN tag)
10.0.10.0/24    → VLAN 10 trusted  (infrastruttura)
10.0.20.0/24    → VLAN 20 IoT      (dispositivi consumer)
10.0.30.0/24    → VLAN 30 DMZ      (servizi pubblici)
```

### IP fissi per nodo

| Nodo | IP attuale | IP futuro (VLAN) | VLAN |
|---|---|---|---|
| ZimaBoard LAN | 192.168.1.1 | 10.0.10.1 | gateway |
| Torre Intel | 192.168.1.10 | 10.0.10.10 | trusted |
| AMD Nexus | 192.168.1.20 | 10.0.10.20 | trusted |
| Laptop (cavo) | DHCP 192.168.1.x | DHCP 10.0.10.x | trusted |

### Porte aperte per nodo — AMD Nexus

Queste porte sono accessibili dalla VLAN trusted (10.0.10.0/24).
**Nessuna** è esposta direttamente a Internet — tutto passa per Nginx
Proxy Manager sulla DMZ con certificato SSL.

| Porta | Servizio | Protocollo |
|---|---|---|
| 3000 | Homepage dashboard | HTTP |
| 3001 | Forgejo web | HTTP |
| 222 | Forgejo SSH | SSH |
| 3002 | Pingvin Share | HTTP |
| 3900 | Garage S3 API | HTTP |
| 3901 | Garage S3 web | HTTP |
| 5678 | n8n | HTTP |
| 8085 | Headscale | HTTP/WireGuard |
| 8086 | Headscale UI | HTTP |
| 8087 | Vaultwarden | HTTP |
| 8088 | Nextcloud | HTTP |
| 8089 | Paperless | HTTP |
| 8090 | Open WebUI | HTTP |
| 8091 | ntfy | HTTP |
| 8092 | Excalidraw | HTTP |
| 9000 | Portainer | HTTP |
| 11434 | Ollama API | HTTP |
| 19999 | Netdata | HTTP |
| 51515 | Kopia | HTTP |
| 2283 | Immich | HTTP |
| 80/81/443 | Nginx Proxy Manager | HTTP/HTTPS |

### Porte aperte — Torre Intel (Proxmox)

| Porta | Servizio | Accessibile da |
|---|---|---|
| 8006 | Proxmox GUI (HTTPS) | VLAN trusted |
| 22 | SSH Proxmox | VLAN trusted |

### Esposizione pubblica via Nginx Proxy Manager

I servizi accessibili dall'esterno (quando configurati) passano tutti
per Nginx Proxy Manager sulla DMZ con certificato Let's Encrypt:

```
Internet → DNS pubblico → IP pubblico dinamico
    → OPNsense port forward → Nginx (VLAN 30 DMZ)
    → proxy interno → servizio su AMD VLAN 10
```

Servizi candidati all'esposizione pubblica:
- Nextcloud (sync file da mobile)
- Vaultwarden (password da ovunque)
- Headscale (VPN da fuori casa)
- ntfy (notifiche push)
- Forgejo (webhook CI/CD)

### WireGuard / Headscale

Tutti i nodi connessi a Headscale formano una rete mesh privata
raggiungibile da qualsiasi posizione, incluso il laptop in modalità field:

```
Laptop field (Parrot OS)
    ↓ WireGuard via Internet
Headscale su AMD (porta 8085)
    ↓ rete mesh privata
    ├── AMD Nexus  (Ollama, report, storage)
    ├── Torre Intel (Proxmox, VM-AI on-demand)
    └── altri nodi futuri
```

---

## 8. Flusso Operativo dal Campo

### Scenario: audit rete cliente → report → email

```
1. LAPTOP PARROT OS (campo)
   └── sudo bash netaudit.sh
       → scansiona rete cliente (20 min)
       → genera /tmp/netaudit_Cliente_data/

2. LAPTOP → AMD via Headscale/WireGuard
   └── bash netreport.sh /tmp/netaudit_.../ --remote
       → manda prompt a Ollama su AMD (GTX 1660 Super, Mistral 7B)
       → oppure su VM-AI Torre (RTX 5060 Ti, Mistral Nemo 12B)
       → genera report_cliente.html

3. AMD — automatico via n8n
   └── workflow: markdown → PDF
       → salva su Nextcloud /clienti/NomeCliente/
       → archivia in Paperless con tag cliente+data
       → invia email al cliente

4. LAPTOP
   └── rsync report → AMD:~/clienti/NomeCliente/
       → apri report nel browser, fai firmare, procedi
```

### Accesso remoto di emergenza

Se AMD perde connessione mentre sei in campo:
```bash
# Connetti via Headscale (sempre attivo su AMD)
tailscale up --login-server https://headscale.tuodominio.com

# SSH diretto
ssh homelab@100.64.x.x  # IP Headscale di AMD

# Se OPNsense ha perso WAN
ssh root@192.168.1.1    # accesso locale
configctl interface newip re0
```

---

*Documento generato Aprile 2026*
*ZimaBoard OPNsense · AMD Nexus Ubuntu+Docker · Torre Intel Proxmox 9 · Dell Latitude 7430*