# 🟢 Homelab UPS Orchestration

> Spegnimento ordinato torre → nexus su blackout, con ritorno automatico.
> Basato su **NUT** (Network UPS Tools), **systemd**, **SSH forced-command** e **Docker Compose**.

---

## 📐 Architettura

```
┌─────────────────┐      USB       ┌─────────────────┐
│  Green Cell     │◄───────────────│     nexus       │
│  PowerProof 2k  │                │  (NUT primary)  │
│  2000VA         │                │                 │
└────────┬────────┘                │  ┌───────────┐  │
         │                         │  │ nut-server│  │
    ┌────┴────┐                    │  │ upsmon    │  │
    │ Schuko  │◄── nexus (~80W)    │  │ upssched  │  │
    │   +     │◄── torre (~400W)   │  └───────────┘  │
    │   IEC   │◄── switch          │                 │
    └────┬────┘◄── modem (opt.)   │  kg-ups-handler │
         │                         └────────┬────────┘
         │                                  │ SSH (nut)
         │                         ┌────────┴────────┐
         └────────────────────────►│      torre      │
                                   │  (Proxmox VE)   │
                                   │                 │
                                   │ torre-emergency-│
                                   │    shutdown     │
                                   └─────────────────┘
```

### Strategia di spegnimento

| Nodo | Carico | Tempo spegnimento | Decisione |
|------|--------|-------------------|-----------|
| **torre** (GPU) | fino a ~400W | lento (guest → host) | **giù subito**, a `ONBATT + 60s` |
| **nexus** | ~80W | veloce | **resta su**, giù a `LOWBATT` |

I 60 secondi di tolleranza evitano falsi positivi sui lampi di rete.

---

## 🔌 Hardware checklist

| Componente | Stato | Nota |
|------------|-------|------|
| UPS Green Cell PowerProof 2000VA | ✅ | Driver `nutdrv_qx`, protocollo `q1` |
| nexus (server principale) | ✅ | Collegato a Schuko |
| torre (Proxmox/GPU) | ✅ | Collegato a Schuko |
| Switch di rete | ✅ | **Deve** essere sull'UPS |
| Modem/ONT | ⚠️ opz. | Serve per notifiche ntfy durante blackout |
| BIOS nexus: "Power On after AC loss" | ✅ | ON |
| BIOS torre: "Stay Off after AC loss" | ✅ | ON + WoL da S5 |

> ⚠️ **Senza lo switch sull'UPS**, nexus non può comandare lo spegnimento di torre durante il blackout.

---

## ⚙️ NUT su nexus (primary)

### Dipendenze

```bash
sudo apt install nut libusb-1.0-0-dev
```

### `/etc/nut/ups.conf`

```ini
maxretry = 1
pollinterval = 2

[nexus-ups]
    driver = nutdrv_qx
    protocol = q1
    port = auto
    vendorid = 0665
    productid = 5161
    desc = "Green Cell PowerProof 2000VA"
    runtimecal = 2340,8,4740,4
    default.battery.packs = 2
    default.battery.type = PbAcid
    default.battery.voltage.nominal = 24
    default.battery.voltage.low = 21.00
    default.battery.voltage.high = 25.00
    default.battery.charge.low = 20
    default.input.voltage.nominal = 230.0
    default.output.voltage.nominal = 230.0
```

> `runtimecal` è calibrata a carichi 4-8% (~50-100W). Con torre accesa (~33% = ~400W) la stima `battery.runtime` è **ottimista e inaffidabile** — la logica di spegnimento si basa sul tempo da `ONBATT`, non sul runtime.

### `/etc/nut/nut.conf`

```ini
MODE=netserver
```

### `/etc/nut/upsd.conf`

```ini
LISTEN 127.0.0.1 3493
```

### `/etc/nut/upsd.users`

```ini
[upsmon]
    password = <PASSWORD_FORTE>
    upsmon master
```

### `/etc/nut/upsmon.conf`

```ini
MONITOR nexus-ups@localhost 1 upsmon <PASSWORD_FORTE> master
MINSUPPLIES 1
POLLFREQ 5
POLLFREQALERT 5
SHUTDOWNCMD "/usr/local/bin/kg-ups-handler nexus-down"
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE  SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
```

> `SHUTDOWNCMD` è gestito da **upsmon** (che si ri-eleva a root), non da upssched.

### `/etc/nut/upssched.conf`

```ini
CMDSCRIPT /usr/local/bin/kg-ups-handler
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

AT ONBATT  * START-TIMER  torre-down 60
AT ONBATT  * EXECUTE      notify-onbatt
AT ONLINE  * CANCEL-TIMER torre-down
AT ONLINE  * EXECUTE      notify-online
```

### Avvio

```bash
sudo systemctl restart nut-server nut-monitor
sudo upsc nexus-ups@localhost
```

---

## 🔐 SSH nut → torre (forced command)

**Il problema:** `upssched` gira come utente `nut`, non root. Per spegnere torre via SSH, `nut` deve avere una chiave e torre deve accettarla tramite il wrapper `n8n-qm-wrap`.

### Su nexus: genera chiave per `nut`

```bash
sudo mkdir -p /var/lib/nut/.ssh
sudo chown nut:nut /var/lib/nut /var/lib/nut/.ssh
sudo chmod 700 /var/lib/nut/.ssh

sudo -u nut ssh-keygen -t ed25519 -f /var/lib/nut/.ssh/id_ed25519 -N "" -C "nut@nexus-ups"
```

### Su torre: aggiungi il case al wrapper

Modifica `/usr/local/sbin/n8n-qm-wrap` e inserisci **prima** del `*)`:

```bash
  "torre-emergency-shutdown"|"torre-emergency-shutdown --dry-run")
    logger -t n8n-qm-wrap "ok: ${cmd}"
    case "$cmd" in
      *--dry-run) exec /usr/local/bin/torre-emergency-shutdown --dry-run ;;
      *)          exec /usr/local/bin/torre-emergency-shutdown ;;
    esac
    ;;
```

### Su torre: authorized_keys

Aggiungi in `/root/.ssh/authorized_keys`:

```text
command="/usr/local/sbin/n8n-qm-wrap",no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC... nut@nexus-ups
```

### Verifica

```bash
sudo -u nut ssh -o ConnectTimeout=5 -o BatchMode=yes root@10.0.10.10 "torre-emergency-shutdown --dry-run"
```

Deve restituire il dry-run **senza** `unauthorized command`.

---

## 🧠 Script di orchestrazione

### `kg-ups-handler` (nexus)

Gestisce:
- `torre-down` → SSH a torre per graceful shutdown
- `nexus-down` → `compose down` + halt (chiamato da upsmon a LOWBATT)
- `notify-onbatt` / `notify-online` → notifiche ntfy

> **Nota:** il comando SSH verso torre deve essere **solo il nome** (`torre-emergency-shutdown`), non il path completo — il wrapper `n8n-qm-wrap` fa il matching sui nomi.

### `torre-emergency-shutdown` (torre)

Esegue su Proxmox:
1. `qm shutdown` di tutti i guest running (graceful, 90s timeout)
2. `qm stop` forzato per chi è ancora su
3. `sync` + `shutdown -h now`

---

## 🐳 Docker Compose sotto systemd

`/etc/systemd/system/homelab-compose.service`:

```ini
[Unit]
Description=Homelab docker compose stacks
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/homelab-infra
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down --timeout 30
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-compose
```

> `RemainAfterExit=yes` fa sì che al boot il `compose up -d` rialzi tutto, e `systemctl stop` esegua il `compose down` pulito chiamato da `kg-ups-handler`.

---

## 🧪 Test procedure

### 1. Verifica base NUT

```bash
sudo upsc nexus-ups@localhost
```

Atteso: `ups.status: OL`, `battery.charge: 100`, `input.voltage: ~229V`.

### 2. Verifica SSH nut → torre

```bash
sudo -u nut ssh root@10.0.10.10 "torre-emergency-shutdown --dry-run"
```

### 3. Dry-run

Su nexus:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler torre-down
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler nexus-down
```

Su torre:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/torre-emergency-shutdown --dry-run
```

### 4. Evento simulato (FSD)

⚠️ **Questo spegne davvero.**

```bash
sudo upsmon -c fsd
```

### 5. Prova vera a 60 secondi

1. Stacca la spina dell'UPS dalla parete (torre accesa).
2. Aspetta ~60 secondi.
3. **Torre** deve spegnersi ordinatamente (guest → host halt).
4. **Nexus** deve restare acceso.
5. Rattacca la spina prima di `LOWBATT` → `ONLINE` cancella il timer.

### 6. Verifica killpower (LOWBATT)

1. Lascia scaricare fino a `LOWBATT` (o forza con FSD).
2. Verifica che l'UPS **tagli l'output** (prese spente).
3. Rattacca la corrente.
4. Verifica che **nexus si riaccenda da solo**.

> ⚠️ **Se l'UPS non taglia l'output**, nexus resta in stato `halted` e non riparte automaticamente. Serve intervento manuale o una presa smart a monte.

---

## 🚨 Troubleshooting

| Sintomo | Causa | Fix |
|---------|-------|-----|
| `Cannot load USB library` | Manca `libusb-1.0-0-dev` | `sudo apt install libusb-1.0-0-dev` |
| `Duplicate driver instance` | PID file residuo | `sudo rm -f /run/nut/*.pid` |
| `upsd disabled` | `MODE` non impostato in `nut.conf` | `echo 'MODE=netserver' \| sudo tee /etc/nut/nut.conf` |
| `unauthorized command` su torre | `torre-emergency-shutdown` non whitelistato nel wrapper | Aggiungi il case in `/usr/local/sbin/n8n-qm-wrap` |
| `Connection failure` | `upsd` non in ascolto | `sudo systemctl start nut-server` |
| Torre non si spegne | Switch non sull'UPS | Sposta lo switch sotto UPS |
| Nexus non riparte dopo blackout | BIOS "Power On after AC loss" = OFF | Abilitalo nel BIOS |
| Container non ripartono al boot | `homelab-compose.service` non enabled | `sudo systemctl enable homelab-compose` |

---

## 📋 Criterio di uscita

- [ ] `upsc nexus-ups@localhost` restituisce dati validi (`OL`, carica, tensione).
- [ ] `nut-server` e `nut-monitor` attivi e senza errori.
- [ ] Case `torre-emergency-shutdown` in `/usr/local/sbin/n8n-qm-wrap`.
- [ ] `sudo -u nut ssh root@10.0.10.10 "torre-emergency-shutdown --dry-run"` funziona.
- [ ] `kg-ups-handler` e `torre-emergency-shutdown` installati; dry-run ok.
- [ ] `homelab-compose.service` enabled e attivo.
- [ ] Switch sull'UPS; `torre` in `/etc/hosts`; BIOS nexus = on-after-AC; BIOS torre = stay-off + WoL.
- [ ] Prova reale a 60s superata: torre giù ordinata, nexus su.
- [ ] Verifica killpower a LB: nexus riparte da solo (o noto che serve intervento manuale).

---

## 📝 Note operative

- **Non fidarti di `battery.runtime`** quando torre è accesa: la calibrazione è a basso carico.
- **Il lavoro rifiutato non si perde**: la coda di ingest è persistente; `genome-reconcile` ripesca a corrente tornata.
- **Notifiche sono best-effort**: se il modem non è sull'UPS, il push ntfy non parte durante il blackout — ma lo spegnimento procede comunque.
- **OPNsense**: non è nel percorso critico (nexus e torre sono sulla stessa /24). Se non è sull'UPS, cade e riparte da solo.

---

*Documento generato per l'homelab nexus/torre — Green Cell PowerProof 2000VA.*
