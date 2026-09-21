# UPS stack

Ordered shutdown, workstation → server, on mains failure, with automatic
recovery. Built on **NUT** (Network UPS Tools), **systemd**, an **SSH forced
command** and **Docker Compose**.

This subsystem spans two layers, which is why its pieces live in two places:

| Layer | What | Where |
|-------|------|-------|
| Host | The event handler NUT invokes, installed to `/usr/local/bin` | `host/kg-ups-handler` |
| Host | NUT configuration, systemd units, the SSH forced command | Not in the repository — created from this runbook |
| Container | `nut-upsd`, the NUT server as a container | `stacks/ups/compose.yml` |

> **Status: not currently enabled.** The include line for `stacks/ups` is
> commented out in `docker-compose.yml`, pending the physical install. The
> host-side design below is complete and tested; uncomment the include once the
> UPS is wired up.

The two layers are alternatives, not complements: either NUT runs on the host
(the arrangement this runbook describes, and the one that works, because
`upsmon` must halt the host itself) or it runs in the container. The container
stack is kept for the case where only monitoring is wanted, without the
shutdown orchestration.

---

## 📐 Architecture

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

### Shutdown strategy

| Node | Load | Shutdown time | Decision |
|------|------|---------------|----------|
| **torre** (GPU) | up to ~400W | slow (guests → host) | **goes down first**, at `ONBATT + 60s` |
| **nexus** | ~80W | fast | **stays up**, goes down at `LOWBATT` |

The 60-second grace period avoids reacting to brief mains flickers.

---

## 🔌 Hardware checklist

| Component | Status | Note |
|-----------|--------|------|
| Green Cell PowerProof 2000VA UPS | ✅ | `nutdrv_qx` driver, `q1` protocol |
| nexus (main server) | ✅ | On the Schuko outlet |
| torre (Proxmox/GPU) | ✅ | On the Schuko outlet |
| Network switch | ✅ | **Must** be on the UPS |
| Modem/ONT | ⚠️ opt. | Needed for ntfy notifications during an outage |
| nexus BIOS: "Power On after AC loss" | ✅ | ON |
| torre BIOS: "Stay Off after AC loss" | ✅ | ON, plus WoL from S5 |

> ⚠️ **Without the switch on the UPS**, nexus cannot tell torre to shut down during an outage.

---

## ⚙️ NUT on nexus (primary)

### Dependencies

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

> `runtimecal` is calibrated at 4–8% load (~50–100W). With torre running (~33% = ~400W) the `battery.runtime` estimate is **optimistic and unreliable** — the shutdown logic keys off time since `ONBATT`, not off runtime.

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
    password = <STRONG_PASSWORD>
    upsmon master
```

### `/etc/nut/upsmon.conf`

```ini
MONITOR nexus-ups@localhost 1 upsmon <STRONG_PASSWORD> master
MINSUPPLIES 1
POLLFREQ 5
POLLFREQALERT 5
SHUTDOWNCMD "/usr/local/bin/kg-ups-handler nexus-down"
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE  SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
```

> `SHUTDOWNCMD` is run by **upsmon**, which re-elevates to root — not by upssched.

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

### Startup

```bash
sudo systemctl restart nut-server nut-monitor
sudo upsc nexus-ups@localhost
```

---

## 🔐 SSH nut → torre (forced command)

**The problem:** `upssched` runs as the `nut` user, not as root. To shut torre down over SSH, `nut` needs a key and torre must accept it through the `n8n-qm-wrap` wrapper.

### On nexus: generate a key for `nut`

```bash
sudo mkdir -p /var/lib/nut/.ssh
sudo chown nut:nut /var/lib/nut /var/lib/nut/.ssh
sudo chmod 700 /var/lib/nut/.ssh

sudo -u nut ssh-keygen -t ed25519 -f /var/lib/nut/.ssh/id_ed25519 -N "" -C "nut@nexus-ups"
```

### On torre: add the case to the wrapper

Edit `/usr/local/sbin/n8n-qm-wrap` and insert this **before** the `*)` branch:

```bash
  "torre-emergency-shutdown"|"torre-emergency-shutdown --dry-run")
    logger -t n8n-qm-wrap "ok: ${cmd}"
    case "$cmd" in
      *--dry-run) exec /usr/local/bin/torre-emergency-shutdown --dry-run ;;
      *)          exec /usr/local/bin/torre-emergency-shutdown ;;
    esac
    ;;
```

### On torre: authorized_keys

Add to `/root/.ssh/authorized_keys`:

```text
command="/usr/local/sbin/n8n-qm-wrap",no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC... nut@nexus-ups
```

### Verify

```bash
sudo -u nut ssh -o ConnectTimeout=5 -o BatchMode=yes root@10.0.10.10 "torre-emergency-shutdown --dry-run"
```

It must print the dry-run output **without** `unauthorized command`.

---

## 🧠 Orchestration scripts

### `kg-ups-handler` (on the server)

Source: `host/kg-ups-handler`. Install with:

```bash
sudo install -m 0755 host/kg-ups-handler /usr/local/bin/kg-ups-handler
```

The ntfy token it uses lives in `/etc/nut/kg-ups.env`, mode 0600, owned by
root — never in `.env`, which is readable by the user running Compose.

Handles:
- `torre-down` → SSH to torre for a graceful shutdown
- `nexus-down` → `compose down` plus halt (called by upsmon at LOWBATT)
- `notify-onbatt` / `notify-online` → ntfy notifications

> **Note:** the SSH command sent to torre must be **the bare name** (`torre-emergency-shutdown`), not the full path — the `n8n-qm-wrap` wrapper matches on names.

### `torre-emergency-shutdown` (torre)

On Proxmox it runs:
1. `qm shutdown` for every running guest (graceful, 90s timeout)
2. a forced `qm stop` for anything still up
3. `sync` followed by `shutdown -h now`

---

## 🐳 Docker Compose under systemd

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

> `RemainAfterExit=yes` is what makes `compose up -d` bring everything back at boot, and makes `systemctl stop` run the clean `compose down` that `kg-ups-handler` invokes.

---

## 🧪 Test procedure

### 1. NUT basics

```bash
sudo upsc nexus-ups@localhost
```

Expected: `ups.status: OL`, `battery.charge: 100`, `input.voltage: ~229V`.

### 2. SSH nut → torre

```bash
sudo -u nut ssh root@10.0.10.10 "torre-emergency-shutdown --dry-run"
```

### 3. Dry run

On nexus:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler torre-down
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler nexus-down
```

On torre:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/torre-emergency-shutdown --dry-run
```

### 4. Simulated event (FSD)

⚠️ **This really does shut things down.**

```bash
sudo upsmon -c fsd
```

### 5. Real 60-second test

1. Pull the UPS plug from the wall, with torre running.
2. Wait ~60 seconds.
3. **torre** must shut down cleanly (guests → host halt).
4. **nexus** must stay up.
5. Plug it back in before `LOWBATT` → `ONLINE` cancels the timer.

### 6. Killpower check (LOWBATT)

1. Let it drain to `LOWBATT`, or force it with FSD.
2. Confirm the UPS **cuts its output** (outlets dead).
3. Restore mains power.
4. Confirm **nexus powers itself back on**.

> ⚠️ **If the UPS does not cut its output**, nexus stays `halted` and will not restart on its own. That needs manual intervention, or a smart plug upstream.

---

## 🚨 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot load USB library` | `libusb-1.0-0-dev` missing | `sudo apt install libusb-1.0-0-dev` |
| `Duplicate driver instance` | Stale PID file | `sudo rm -f /run/nut/*.pid` |
| `upsd disabled` | `MODE` not set in `nut.conf` | `echo 'MODE=netserver' \| sudo tee /etc/nut/nut.conf` |
| `unauthorized command` on torre | `torre-emergency-shutdown` not whitelisted in the wrapper | Add the case to `/usr/local/sbin/n8n-qm-wrap` |
| `Connection failure` | `upsd` not listening | `sudo systemctl start nut-server` |
| torre does not shut down | Switch not on the UPS | Move the switch onto the UPS |
| nexus does not restart after an outage | BIOS "Power On after AC loss" = OFF | Enable it in the BIOS |
| Containers do not start at boot | `homelab-compose.service` not enabled | `sudo systemctl enable homelab-compose` |

---

## 📋 Exit criteria

- [ ] `upsc nexus-ups@localhost` returns sane data (`OL`, charge, voltage).
- [ ] `nut-server` and `nut-monitor` active and error-free.
- [ ] `torre-emergency-shutdown` case present in `/usr/local/sbin/n8n-qm-wrap`.
- [ ] `sudo -u nut ssh root@10.0.10.10 "torre-emergency-shutdown --dry-run"` works.
- [ ] `kg-ups-handler` and `torre-emergency-shutdown` installed; dry runs pass.
- [ ] `homelab-compose.service` enabled and active.
- [ ] Switch on the UPS; `torre` in `/etc/hosts`; nexus BIOS = on-after-AC; torre BIOS = stay-off + WoL.
- [ ] Real 60-second test passed: torre down cleanly, nexus still up.
- [ ] Killpower checked at LB: nexus comes back on its own, or it is documented that manual intervention is needed.

---

## 📝 Operational notes

- **Do not trust `battery.runtime`** while torre is running: the calibration is for low load.
- **Rejected work is not lost**: the ingest queue is persistent, and `genome-reconcile` picks it up once power is back.
- **Notifications are best-effort**: if the modem is not on the UPS the ntfy push will not go out during an outage — the shutdown still proceeds.
- **OPNsense** is not in the critical path (nexus and torre share the same /24). If it is not on the UPS it drops and comes back by itself.

---

*Written for this homelab's server/workstation pair — Green Cell PowerProof 2000VA.*
