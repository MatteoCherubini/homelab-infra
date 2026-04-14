# Fase 1 — Guida Implementazione Completa
## Switch TP-Link + OPNsense 26.1.5 + SSH Keys

*DMZ: Opzione A scelta — VLAN 30 parcheggiata (block all)*

---

## 0. SSH — Situazione attuale e piano

**Adesso:** SSH resta aperto con password per lavorarci dal laptop.
**Dopo la Fase 1:** creiamo la chiave SSH e chiudiamo password auth.

### Accesso attuale (funziona già)

```bash
# Dal laptop Ubuntu — connessione a OPNsense
ssh root@192.168.1.1

# Dopo migrazione VLAN sarà:
ssh root@10.0.10.1
```

### Comandi per creare la chiave SSH (da fare DOPO la Fase 1)

**Sul laptop Ubuntu — generare la chiave:**

```bash
# Genera coppia di chiavi Ed25519 (più sicura e veloce di RSA)
ssh-keygen -t ed25519 -C "homelab-laptop" -f ~/.ssh/opnsense_key

# Ti chiederà una passphrase — mettine una forte, la userai ogni volta

# Risultato:
# ~/.ssh/opnsense_key       ← chiave privata (MAI condividere)
# ~/.ssh/opnsense_key.pub   ← chiave pubblica (da caricare su OPNsense)

# Visualizza la chiave pubblica (ti servirà)
cat ~/.ssh/opnsense_key.pub
```

**Su OPNsense — caricare la chiave pubblica:**

```
GUI → System → Access → Users → root → Edit
  → campo "Authorized keys" → incolla il contenuto di opnsense_key.pub
  → Save
```

**Alternativa via SSH (se preferisci terminale):**

```bash
# Dal laptop, copia la chiave pubblica su OPNsense
ssh-copy-id -i ~/.ssh/opnsense_key.pub root@192.168.1.1

# Oppure manualmente:
ssh root@192.168.1.1
mkdir -p /root/.ssh
echo "CONTENUTO_DELLA_CHIAVE_PUB" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

**Configurare il laptop per usare la chiave automaticamente:**

```bash
# Crea/modifica ~/.ssh/config sul laptop
nano ~/.ssh/config
```

Aggiungi:

```
Host opnsense
    HostName 10.0.10.1
    User root
    IdentityFile ~/.ssh/opnsense_key
    Port 22

Host nexus
    HostName 10.0.10.20
    User homelab
    IdentityFile ~/.ssh/opnsense_key
    Port 22

Host torre
    HostName 10.0.10.10
    User root
    IdentityFile ~/.ssh/opnsense_key
    Port 22
```

**Da quel momento in poi, dal laptop:**

```bash
ssh opnsense     # → connette a OPNsense
ssh nexus        # → connette a Nexus
ssh torre        # → connette a Proxmox
```

**Chiudere password auth (SOLO dopo aver verificato che la chiave funziona!):**

```
GUI → System → Settings → Administration → sezione Secure Shell
  → "Permit root user login" → OFF
  → "Permit password login" → OFF
  → Save
```

**Test di sicurezza:** da un altro terminale, prova `ssh root@10.0.10.1` senza specificare la chiave — deve rifiutarti.

---

## 1. Switch TP-Link TL-SG108E — Configurazione VLAN

### 1.1 Accesso alla GUI dello switch

Il TL-SG108E ha una web GUI. Di default:

```
IP: 192.168.0.1 (o 192.168.1.1 — dipende dal firmware)
User: admin
Password: admin
```

Se non riesci ad accederci, collega il laptop direttamente allo switch con cavo e imposta IP statico 192.168.0.2/24 sul laptop.

```bash
# Temporaneamente sul laptop per accedere allo switch
sudo ip addr add 192.168.0.2/24 dev eth0
# Poi apri http://192.168.0.1 nel browser
# Finito il setup, rimuovi:
sudo ip addr del 192.168.0.2/24 dev eth0
```

### 1.2 Abilitare 802.1Q VLAN

Nella GUI del TL-SG108E:

```
VLAN → 802.1Q VLAN
  → 802.1Q VLAN: Enable
  → Applica
```

### 1.3 Creare le VLAN

**VLAN 10 (Trusted):**

```
VLAN ID: 10
VLAN Name: TRUSTED
Member Ports:
  Porta 1: Tagged     (trunk verso ZimaBoard)
  Porta 2: Untagged   (Nexus)
  Porta 3: Untagged   (Torre Intel)
  Porta 4: Untagged   (Laptop)
  Porta 5-8: Not Member
```

**VLAN 20 (IoT):**

```
VLAN ID: 20
VLAN Name: IOT
Member Ports:
  Porta 1: Tagged     (trunk verso ZimaBoard)
  Porta 5: Untagged   (TV/Smart devices)
  Porta 6: Untagged   (Altri IoT)
  Porta 2-4, 7-8: Not Member
```

**VLAN 1 (default — LAN management):**

```
VLAN ID: 1
VLAN Name: Default
Member Ports:
  Porta 1: Untagged   (traffico untagged verso ZimaBoard)
  Porta 7: Untagged   (emergenza — porta libera per accesso diretto)
  Porte 2-6, 8: Not Member
```

> **IMPORTANTE:** Rimuovi le porte 2-6 dalla VLAN 1 default! Di default sono tutte member — devi toglierle manualmente.

### 1.4 Impostare PVID

```
VLAN → 802.1Q PVID Settings

Porta 1: PVID = 1     (traffico untagged = LAN management)
Porta 2: PVID = 10    (Nexus → VLAN trusted)
Porta 3: PVID = 10    (Torre → VLAN trusted)
Porta 4: PVID = 10    (Laptop → VLAN trusted)
Porta 5: PVID = 20    (TV → VLAN IoT)
Porta 6: PVID = 20    (IoT → VLAN IoT)
Porta 7: PVID = 1     (emergenza)
Porta 8: PVID = 1     (libera)
```

### 1.5 Schema visivo porte switch

```
┌─────────────────────────────────────────────────┐
│  TP-Link TL-SG108E                              │
│                                                  │
│  [1]    [2]    [3]    [4]    [5]    [6]  [7] [8]│
│  Zima   Nexus  Torre  Laptop TV     IoT  EMG -- │
│  TRUNK  V10    V10    V10    V20    V20  LAN -- │
└─────────────────────────────────────────────────┘
```

### 1.6 Verifica

Dopo aver applicato, ricollega i cavi nell'ordine giusto.
**Non scollegare ancora Nexus e Torre** — lo faremo nella Fase 4.
Per ora configura solo lo switch e lascia i cavi dove sono.

---

## 2. OPNsense 26.1.5 — Configurazione

### NOTA IMPORTANTE su OPNsense 26.1

La 26.1 "Witty Woodpecker" ha cambiamenti significativi rispetto alle versioni precedenti:

- **Firewall rules**: c'è una NUOVA GUI per le regole. La trovi sotto `Firewall → Rules` (nuovo stile con griglia). Le vecchie regole (legacy) restano visibili ma la GUI nuova è quella principale.
- **Port Forwarding** ora si chiama **"Destination NAT"** (`Firewall → NAT → Destination NAT`)
- **ISC-DHCP** è diventato un plugin — tu usi Dnsmasq, quindi non ti impatta.
- L'interfaccia generale è comunque simile — menu a sinistra, pannelli a destra.

---

### 2.1 Timezone

```
System → Settings → General

  Timezone: Europe/Rome

  → Save
```

**Alternativa SSH:**

```bash
ssh root@192.168.1.1

# Modifica config.xml
sed -i 's|<timezone>Etc/UTC</timezone>|<timezone>Europe/Rome</timezone>|' /conf/config.xml

# Ricarica configurazione
configctl system timezone set Europe/Rome
```

---

### 2.2 Rinominare le interfacce VLAN

Le interfacce si rinominano cambiando il campo **Description** nella pagina di ciascuna.

**VLAN 10 — da OPT1 a TRUSTED:**

```
Interfaces → [OPT1]      (clicca su OPT1 nel menu a sinistra)

  Description: TRUSTED    (era "OPT1")
  
  ✓ Verifica che sia abilitata (Enable Interface: checked)
  ✓ IPv4: Static IPv4 → 10.0.10.1/24  (dovrebbe essere già così)
  
  → Save → Apply Changes
```

**VLAN 20 — da OPT2 a IOT:**

```
Interfaces → [OPT2]

  Description: IOT
  
  ✓ Enable: checked
  ✓ IPv4: 10.0.20.1/24
  
  → Save → Apply Changes
```

**VLAN 30 — da OPT3 a DMZ:**

```
Interfaces → [OPT3]

  Description: DMZ
  
  ✓ Enable: checked
  ✓ IPv4: 10.0.30.1/24
  
  → Save → Apply Changes
```

Dopo il save, il menu a sinistra si aggiorna automaticamente:
`OPT1` → `TRUSTED`, `OPT2` → `IOT`, `OPT3` → `DMZ`.

**Alternativa SSH (modifica diretta del config.xml):**

```bash
ssh root@192.168.1.1

# Backup prima di tutto!
cp /conf/config.xml /conf/config.xml.backup.$(date +%Y%m%d)

# Modifica le description
sed -i 's|<descr>OPT1</descr>|<descr>TRUSTED</descr>|' /conf/config.xml
sed -i 's|<descr>OPT2</descr>|<descr>IOT</descr>|' /conf/config.xml
sed -i 's|<descr>OPT3</descr>|<descr>DMZ</descr>|' /conf/config.xml

# Ricarica configurazione
configctl interface reload
```

> **Nota:** l'identificatore interno resta `opt1`, `opt2`, `opt3` — è solo il nome visualizzato che cambia. Le regole firewall e il DHCP fanno riferimento all'identificatore interno, che non cambia.

---

### 2.3 DHCP — Assegnazioni statiche

Tu usi **Dnsmasq** per DHCP. Aggiungiamo le assegnazioni statiche.

```
Services → Dnsmasq DNS → DHCP Hosts (o "Static Hosts")
```

Aggiungi due entry:

**Nexus:**

```
Interface: TRUSTED (opt1)
MAC Address: (MAC della NIC di Nexus — trovalo con: ip link show su Nexus)
IP Address: 10.0.10.20
Hostname: nexus
Description: AMD Docker Server
```

**Torre:**

```
Interface: TRUSTED (opt1)
MAC Address: (MAC della NIC Intel i210-T1 della Torre)
IP Address: 10.0.10.10
Hostname: torre
Description: Proxmox Host
```

**Come trovare i MAC address:**

```bash
# Su Nexus
ip link show | grep -A1 "enp"
# Output: link/ether XX:XX:XX:XX:XX:XX

# Su Torre (Proxmox)
ip link show | grep -A1 "enp"
```

**Aggiorna anche il range DHCP per VLAN 10:**

```
Services → Dnsmasq DNS → DHCP Ranges

Trova il range per opt1 (TRUSTED) e modificalo:
  Start: 10.0.10.50
  End:   10.0.10.99
```

Questo lascia 10.0.10.2-49 liberi per futuri server statici.

---

### 2.4 Unbound DNS — DNSSEC

```
Services → Unbound DNS → General

  DNSSEC: ✓ (spunta)
  
  Listen Interfaces: verifica che ci siano LAN, TRUSTED, IOT
                     (NON aggiungere DMZ — non ne ha bisogno)

  → Save → Apply
```

**Alternativa SSH:**

```bash
ssh root@192.168.1.1

# Abilita DNSSEC nel config
sed -i 's|<dnssec>0</dnssec>|<dnssec>1</dnssec>|' /conf/config.xml

# Riavvia Unbound
configctl unbound reconfigure
```

---

### 2.5 Creare gli Alias

Questa è la parte più importante — gli alias rendono le regole leggibili e manutenibili.

```
Firewall → Aliases
```

Clicca **+** per aggiungerne uno nuovo per ciascuno:

**Alias di tipo Host:**

| Nome | Tipo | Contenuto | Descrizione |
|---|---|---|---|
| SERVER_NEXUS | Host(s) | 10.0.10.20 | Server Docker AMD |
| SERVER_TORRE | Host(s) | 10.0.10.10 | Proxmox host |

**Alias di tipo Network:**

| Nome | Tipo | Contenuto | Descrizione |
|---|---|---|---|
| RFC1918 | Network(s) | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 | Tutte le reti private |

**Alias di tipo Port:**

| Nome | Tipo | Contenuto | Descrizione |
|---|---|---|---|
| NEXUS_WEB | Port(s) | 3000 3001 3002 3003 5678 8086 8087 8088 8089 8090 8091 8092 9000 2283 19999 51515 81 | UI web servizi Docker |
| NEXUS_INFRA | Port(s) | 8085 11434 3900 3901 3902 | API infrastruttura |
| NEXUS_GIT_SSH | Port(s) | 222 | Forgejo SSH |

> **Formato:** in OPNsense 26.1, quando crei un alias di tipo Port, separa le porte con spazi o vai a capo. Non usare virgole.

**Alternativa SSH — creare alias via API:**

```bash
# Gli alias si possono anche creare via configctl, ma la GUI è più pratica.
# Se preferisci, puoi editare /conf/config.xml direttamente nella sezione
# <OPNsense><Firewall><Alias><aliases> e aggiungere blocchi XML:

# Esempio struttura:
# <alias uuid="...">
#   <enabled>1</enabled>
#   <name>SERVER_NEXUS</name>
#   <type>host</type>
#   <content>10.0.10.20</content>
#   <description>Server Docker AMD</description>
# </alias>
```

---

### 2.6 Regole Firewall

In OPNsense 26.1 ci sono **due posti** dove gestire le regole:

1. **Firewall → Rules → [interfaccia]** — la GUI legacy (le tue regole attuali sono qui)
2. **Firewall → Automation → Filter** — la GUI nuova (griglia moderna)

In 26.1.5 la migrazione è graduale. Le regole esistenti restano nella GUI legacy.
**Raccomandazione:** usa la GUI che trovi più comoda. Entrambe scrivono le stesse regole PF.
Se vedi il menu "Firewall → Rules" con le interfacce sotto, usa quello.

#### WAN — Regole ingresso (queste le aggiungiamo DOPO i port forward, Step 2.7)

Non toccare ancora.

#### LAN (re1 untagged) — Ridurre i permessi

Vai in `Firewall → Rules → LAN`.

**Elimina** le due regole default:
- "Default allow LAN to any rule" (IPv4)
- "Default allow LAN IPv6 to any rule" (IPv6)

**Aggiungi queste nuove regole (in questo ordine):**

| # | Action | Proto | Source | Destination | Dst Port | Description |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP | LAN net | LAN address | 443 | LAN → GUI OPNsense |
| 2 | Pass | TCP | LAN net | LAN address | 22 | LAN → SSH emergenza |
| 3 | Pass | UDP/TCP | LAN net | LAN address | 53 | LAN → DNS |
| 4 | Block | any | LAN net | RFC1918 | any | LAN → NO reti private |
| 5 | Pass | any | LAN net | any | any | LAN → Internet |

**Per creare ciascuna regola, clicca + e compila:**

```
Esempio regola 1:
  Action: Pass
  Interface: LAN
  Direction: in
  TCP/IP Version: IPv4
  Protocol: TCP
  Source: LAN net (seleziona dal dropdown)
  Destination: LAN address
  Destination port: 443 (HTTPS)
  Description: LAN → GUI OPNsense
  → Save
```

```
Esempio regola 4 (block):
  Action: Block
  Interface: LAN
  Direction: in
  TCP/IP Version: IPv4
  Protocol: any
  Source: LAN net
  Destination: RFC1918 (seleziona l'alias dal dropdown)
  Destination port: any
  Description: LAN → NO reti private
  → Save
```

**Dopo aver aggiunto tutte, clicca "Apply Changes".**

#### TRUSTED (VLAN 10) — Accesso controllato

Vai in `Firewall → Rules → TRUSTED` (o OPT1 se non si è ancora aggiornato il menu).

**Elimina** la regola esistente "trusted-allow-all".

**Aggiungi queste regole:**

| # | Action | Proto | Source | Destination | Dst Port | Description |
|---|---|---|---|---|---|---|
| 1 | Pass | UDP/TCP | TRUSTED net | TRUSTED address | 53 | DNS |
| 2 | Pass | TCP | TRUSTED net | TRUSTED address | 443 | OPNsense GUI |
| 3 | Pass | TCP | TRUSTED net | TRUSTED address | 22 | OPNsense SSH |
| 4 | Pass | TCP | TRUSTED net | SERVER_NEXUS | NEXUS_WEB | Servizi web Docker |
| 5 | Pass | TCP/UDP | TRUSTED net | SERVER_NEXUS | NEXUS_INFRA | API infrastruttura |
| 6 | Pass | TCP | TRUSTED net | SERVER_NEXUS | NEXUS_GIT_SSH | Git SSH |
| 7 | Pass | TCP | TRUSTED net | SERVER_NEXUS | 22 | SSH Nexus |
| 8 | Pass | TCP | TRUSTED net | SERVER_TORRE | 8006 | Proxmox GUI |
| 9 | Pass | TCP | TRUSTED net | SERVER_TORRE | 22 | SSH Torre |
| 10 | Block | any | TRUSTED net | 10.0.20.0/24 | any | No → IoT |
| 11 | Block | any | TRUSTED net | 10.0.30.0/24 | any | No → DMZ |
| 12 | Pass | any | TRUSTED net | any | any | Internet libero |

> **Nota sui dropdown:** quando selezioni "Destination", dovresti vedere gli alias che hai creato (SERVER_NEXUS, NEXUS_WEB, ecc.). Se non li vedi, digita il nome — OPNsense fa autocompletamento.

> **Nota su "TRUSTED address":** nelle regole 1-3, la destinazione è l'IP del firewall sulla VLAN 10 (10.0.10.1). In OPNsense si seleziona come "TRUSTED address" nel dropdown.

#### IOT (VLAN 20) — Internet restrittivo

Vai in `Firewall → Rules → IOT`.

**Elimina** tutte le regole esistenti (iot-block-trusted, iot-block-dmz, iot-allow-internet).

**Aggiungi:**

| # | Action | Proto | Source | Destination | Dst Port | Description |
|---|---|---|---|---|---|---|
| 1 | Pass | UDP/TCP | IOT net | IOT address | 53 | DNS |
| 2 | Block | any | IOT net | RFC1918 | any | No reti private |
| 3 | Pass | TCP | IOT net | any | 80 | HTTP |
| 4 | Pass | TCP | IOT net | any | 443 | HTTPS |
| 5 | Pass | UDP | IOT net | any | 123 | NTP |

> **Ordine critico:** la regola 2 (block RFC1918) DEVE stare PRIMA delle regole 3-5. In PF le regole sono "last match wins" per le pass, ma "first match wins" per i block con `quick`. OPNsense aggiunge `quick` di default, quindi l'ordine che vedi nella GUI è l'ordine di esecuzione.

#### DMZ (VLAN 30) — Parcheggiata (Opzione A)

Vai in `Firewall → Rules → DMZ`.

**Elimina** tutte le regole esistenti (dmz-block-trusted, dmz-block-iot, dmz-allow-web).

**Aggiungi una sola regola:**

| # | Action | Proto | Source | Destination | Dst Port | Description |
|---|---|---|---|---|---|---|
| 1 | Block | any | DMZ net | any | any | DMZ parcheggiata |

---

### 2.7 Port Forward (Destination NAT)

In OPNsense 26.1, il Port Forwarding è stato rinominato in **Destination NAT**.

```
Firewall → NAT → Destination NAT
```

**Port forward HTTPS:**

```
Clicca +

  Interface: WAN
  Protocol: TCP
  Source: any
  Destination: WAN address
  Destination port: 443
  Redirect target IP: 10.0.10.20 (SERVER_NEXUS)
  Redirect target port: 443
  Description: HTTPS → Nginx Proxy Manager

  → Save
```

**Port forward Headscale (VPN):**

```
Clicca +

  Interface: WAN
  Protocol: UDP
  Source: any
  Destination: WAN address
  Destination port: 8085
  Redirect target IP: 10.0.10.20 (SERVER_NEXUS)
  Redirect target port: 8085
  Description: Headscale WireGuard VPN

  → Save
```

**Regole WAN associate:**

In OPNsense 26.1, le "firewall rule associations" non sono più automatiche.
Devi creare manualmente le regole WAN:

```
Firewall → Rules → WAN

Regola 1:
  Action: Pass
  Interface: WAN
  Protocol: TCP
  Source: any
  Destination: SERVER_NEXUS (alias)
  Destination port: 443
  Description: WAN HTTPS → Nginx

Regola 2:
  Action: Pass
  Interface: WAN
  Protocol: UDP
  Source: any
  Destination: SERVER_NEXUS (alias)
  Destination port: 8085
  Description: WAN Headscale VPN

→ Apply Changes
```

---

## 3. Comandi di verifica (dopo aver completato tutto)

Esegui questi comandi via SSH su OPNsense per verificare che tutto sia configurato correttamente.

```bash
ssh root@192.168.1.1
```

### 3.1 Verifica interfacce

```bash
# Lista interfacce con IP
ifconfig | grep -E "^[a-z]|inet "

# Devi vedere:
# re0   → IP DHCP dal modem (WAN)
# re1   → 192.168.1.1 (LAN)
# vlan0.10 → 10.0.10.1 (TRUSTED)
# vlan0.20 → 10.0.20.1 (IOT)
# vlan0.30 → 10.0.30.1 (DMZ)
```

### 3.2 Verifica alias

```bash
# Lista delle tabelle PF (gli alias diventano tabelle)
pfctl -sT

# Contenuto di un alias specifico
pfctl -t SERVER_NEXUS -Ts
# Deve mostrare: 10.0.10.20

pfctl -t RFC1918 -Ts
# Deve mostrare: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16

pfctl -t NEXUS_WEB -Ts
# Deve mostrare tutte le porte web
```

### 3.3 Verifica regole firewall attive

```bash
# Tutte le regole PF caricate (output lungo)
pfctl -sr

# Conta regole per interfaccia
pfctl -sr | grep -c "on re1 "      # LAN
pfctl -sr | grep -c "on vlan0.10"  # TRUSTED
pfctl -sr | grep -c "on vlan0.20"  # IOT
pfctl -sr | grep -c "on vlan0.30"  # DMZ
pfctl -sr | grep -c "on re0 "     # WAN

# Verifica specifica: regola block RFC1918 su IoT
pfctl -sr | grep "vlan0.20" | grep "block"
```

### 3.4 Verifica NAT / Port Forward

```bash
# Regole NAT attive
pfctl -sn

# Deve mostrare le due regole di redirect:
# rdr on re0 ... -> 10.0.10.20 port 443
# rdr on re0 ... -> 10.0.10.20 port 8085
```

### 3.5 Verifica DHCP

```bash
# Leases attivi Dnsmasq
cat /var/db/dnsmasq.leases

# Config Dnsmasq attiva (cerca le entry statiche)
cat /var/etc/dnsmasq*.conf | grep "dhcp-host"
# Deve mostrare le assegnazioni statiche per Nexus e Torre
```

### 3.6 Verifica DNS

```bash
# Test risoluzione DNS locale
drill google.com @127.0.0.1

# Test DNSSEC
drill -D google.com @127.0.0.1
# Se DNSSEC funziona, vedrai flag "ad" (authenticated data)

# Alternativa con dig (se disponibile)
dig +dnssec google.com @127.0.0.1
```

### 3.7 Verifica timezone

```bash
date
# Deve mostrare l'ora italiana (CEST/CET), non UTC
```

### 3.8 Backup configurazione

```bash
# Esporta la configurazione attuale (fallo PRIMA e DOPO le modifiche)
cp /conf/config.xml /root/config_backup_fase1_$(date +%Y%m%d_%H%M).xml

# Scaricala sul laptop
# Dal laptop:
scp root@192.168.1.1:/root/config_backup_fase1_*.xml ~/
```

---

## 4. Checklist finale Fase 1

```
□ Switch TP-Link configurato con VLAN 802.1Q
  □ VLAN 10 creata (porte 1-4)
  □ VLAN 20 creata (porte 1, 5-6)
  □ PVID impostati correttamente
  □ Porte 2-6 rimosse da VLAN 1 default

□ OPNsense — Setup base
  □ Timezone: Europe/Rome
  □ Interfacce rinominate: TRUSTED, IOT, DMZ
  □ DHCP statico: Nexus=10.0.10.20, Torre=10.0.10.10
  □ DHCP range VLAN 10: 10.0.10.50-99
  □ DNSSEC abilitato su Unbound

□ OPNsense — Alias
  □ SERVER_NEXUS (host: 10.0.10.20)
  □ SERVER_TORRE (host: 10.0.10.10)
  □ RFC1918 (network: 10/8, 172.16/12, 192.168/16)
  □ NEXUS_WEB (port: lista porte web)
  □ NEXUS_INFRA (port: 8085, 11434, 3900-3902)
  □ NEXUS_GIT_SSH (port: 222)

□ OPNsense — Regole firewall
  □ LAN: 5 regole (GUI+SSH+DNS, block RFC1918, pass internet)
  □ TRUSTED: 12 regole (DNS, mgmt, servizi Nexus/Torre, block laterale, internet)
  □ IOT: 5 regole (DNS, block RFC1918, HTTP/HTTPS/NTP)
  □ DMZ: 1 regola (block all)
  □ WAN: 2 regole (HTTPS + Headscale)

□ OPNsense — Destination NAT
  □ WAN:443 → 10.0.10.20:443
  □ WAN:8085 → 10.0.10.20:8085

□ Verifiche
  □ ifconfig mostra tutte le interfacce con IP corretti
  □ pfctl -sT mostra gli alias
  □ pfctl -sr mostra le regole
  □ pfctl -sn mostra i NAT
  □ date mostra ora italiana
  □ DNS con DNSSEC funziona
  □ Backup config.xml salvato

□ NON ANCORA FATTO (Fase 2):
  □ Spostare fisicamente i cavi nello switch
  □ Cambiare IP a Nexus (10.0.10.20)
  □ Cambiare IP a Torre (10.0.10.10)
  □ Chiudere SSH password (dopo setup chiave)
```

---

*Quando hai completato tutti i check, mandami l'output dei comandi di verifica e passiamo alla Fase 2 — migrazione fisica dei dispositivi sulle VLAN.*