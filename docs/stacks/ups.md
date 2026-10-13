# UPS orchestration

Ordered shutdown, workstation → server, on mains failure, with automatic
recovery. Built on **NUT** (Network UPS Tools), **systemd** and an **SSH
forced command**.

**This runs on the host, not in Compose, and that is not a temporary state.**

`upsmon` has to halt the machine it is monitoring. A container cannot halt its
own host, so the shutdown half of this design can only live outside Docker.
What Compose contributes is the other direction: `homelab-compose.service`
gives the handler a clean way to bring the stacks down before the halt, and to
bring them back up at boot.

| Piece | Where |
|-------|-------|
| The event handler NUT invokes, installed to `/usr/local/bin` | `host/kg-ups-handler` |
| NUT configuration, systemd units, the SSH forced command | On the host — created from this runbook, not tracked here |
| The ntfy token the handler uses | `/etc/nut/kg-ups.env`, mode 0600, owned by root |

Only the handler is version-controlled. The rest is host configuration that
this document describes well enough to rebuild.

> **There was once a `stacks/ups/compose.yml`** running `nut-upsd` in a
> container, left behind a commented-out include. It was removed, because
> enabling it on this host would have conflicted three ways: the host `upsd`
> already holds port 3493, the host `nutdrv_qx` already holds the UPS over USB,
> and the container still could not perform the halt that is the entire point.
> It was an alternative that was tried and rejected, not a pending step.

---

## 📐 Architecture

```
┌─────────────────┐      USB       ┌─────────────────┐
│  Green Cell     │◄───────────────│     server       │
│  PowerProof 2k  │                │  (NUT primary)  │
│  2000VA         │                │                 │
└────────┬────────┘                │  ┌───────────┐  │
         │                         │  │ nut-server│  │
    ┌────┴────┐                    │  │ upsmon    │  │
    │ Schuko  │◄── server (~80W)    │  │ upssched  │  │
    │   +     │◄── hypervisor (~400W)   │  └───────────┘  │
    │   IEC   │◄── switch          │                 │
    └────┬────┘◄── modem (opt.)   │  kg-ups-handler │
         │                         └────────┬────────┘
         │                                  │ SSH (nut)
         │                         ┌────────┴────────┐
         └────────────────────────►│      hypervisor      │
                                   │  (Proxmox VE)   │
                                   │                 │
                                   │ hypervisor-emergency-│
                                   │    shutdown     │
                                   └─────────────────┘
```

### Shutdown strategy

| Node | Load | Shutdown time | Decision |
|------|------|---------------|----------|
| **hypervisor** (GPU) | up to ~400W | slow (guests → host) | **goes down first**, at `ONBATT + 60s` |
| **server** | ~80W | fast | **stays up**, goes down at `LOWBATT` |

The 60-second grace period avoids reacting to brief mains flickers.

---

## 🔌 Hardware checklist

| Component | Status | Note |
|-----------|--------|------|
| Green Cell PowerProof 2000VA UPS | ✅ | `nutdrv_qx` driver, `q1` protocol |
| server (main server) | ✅ | On the Schuko outlet |
| hypervisor (Proxmox/GPU) | ✅ | On the Schuko outlet |
| Network switch | ✅ | **Must** be on the UPS |
| Modem/ONT | ⚠️ opt. | Needed for ntfy notifications during an outage |
| server BIOS: "Power On after AC loss" | ✅ | ON — tested 2026-10-13: halted, cord pulled 30 s, back on by itself |
| hypervisor BIOS: "Stay Off after AC loss" | ✅ | ON, plus WoL from S5 |

> ⚠️ **Without the switch on the UPS**, server cannot tell hypervisor to shut down during an outage.

---

## ⚙️ NUT on server (primary)

### Dependencies

```bash
sudo apt install nut libusb-1.0-0-dev
```

### `/etc/nut/ups.conf`

```ini
maxretry = 1
pollinterval = 2

[server-ups]
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

> `runtimecal` is calibrated at 4–8% load (~50–100W). With hypervisor running (~33% = ~400W) the `battery.runtime` estimate is **optimistic and unreliable** — the shutdown logic keys off time since `ONBATT`, not off runtime.

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
MONITOR server-ups@localhost 1 upsmon <STRONG_PASSWORD> master
MINSUPPLIES 1
POLLFREQ 5
POLLFREQALERT 5
SHUTDOWNCMD "/usr/local/bin/kg-ups-handler server-down"
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

AT ONBATT  * START-TIMER  hypervisor-down 60
AT ONBATT  * EXECUTE      notify-onbatt
AT ONLINE  * CANCEL-TIMER hypervisor-down
AT ONLINE  * EXECUTE      notify-online
```

### Startup

```bash
sudo systemctl restart nut-server nut-monitor
sudo upsc server-ups@localhost
```

---

## 🔐 SSH nut → hypervisor (forced command)

**The problem:** `upssched` runs as the `nut` user, not as root. To shut hypervisor down over SSH, `nut` needs a key and hypervisor must accept it through the `n8n-qm-wrap` wrapper.

### On server: generate a key for `nut`

```bash
sudo mkdir -p /var/lib/nut/.ssh
sudo chown nut:nut /var/lib/nut /var/lib/nut/.ssh
sudo chmod 700 /var/lib/nut/.ssh

sudo -u nut ssh-keygen -t ed25519 -f /var/lib/nut/.ssh/id_ed25519 -N "" -C "nut@server-ups"
```

### On hypervisor: add the case to the wrapper

Edit `/usr/local/sbin/n8n-qm-wrap` and insert this **before** the `*)` branch:

```bash
  "hypervisor-emergency-shutdown"|"hypervisor-emergency-shutdown --dry-run")
    logger -t n8n-qm-wrap "ok: ${cmd}"
    case "$cmd" in
      *--dry-run) exec /usr/local/bin/hypervisor-emergency-shutdown --dry-run ;;
      *)          exec /usr/local/bin/hypervisor-emergency-shutdown ;;
    esac
    ;;
```

### On hypervisor: authorized_keys

Add to `/root/.ssh/authorized_keys`:

```text
command="/usr/local/sbin/n8n-qm-wrap",no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC... nut@server-ups
```

### Verify

```bash
sudo -u nut ssh -o ConnectTimeout=5 -o BatchMode=yes root@192.0.2.10 "hypervisor-emergency-shutdown --dry-run"
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
- `hypervisor-down` → SSH to hypervisor for a graceful shutdown
- `server-down` → `compose down` plus halt (called by upsmon at LOWBATT)
- `notify-onbatt` / `notify-online` → ntfy notifications

> **Note:** the SSH command sent to hypervisor must be **the bare name** (`hypervisor-emergency-shutdown`), not the full path — the `n8n-qm-wrap` wrapper matches on names.

### `hypervisor-emergency-shutdown` (hypervisor)

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
sudo upsc server-ups@localhost
```

Expected: `ups.status: OL`, `battery.charge: 100`, `input.voltage: ~229V`.

### 2. SSH nut → hypervisor

```bash
sudo -u nut ssh root@192.0.2.10 "hypervisor-emergency-shutdown --dry-run"
```

### 3. Dry run

On server:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler hypervisor-down
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler server-down
```

On hypervisor:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/hypervisor-emergency-shutdown --dry-run
```

### 4. Simulated event (FSD)

⚠️ **This really does shut things down.**

```bash
sudo upsmon -c fsd
```

### 5. Real 60-second test

1. Pull the UPS plug from the wall, with hypervisor running.
2. Wait ~60 seconds.
3. **hypervisor** must shut down cleanly (guests → host halt).
4. **server** must stay up.
5. Plug it back in before `LOWBATT` → `ONLINE` cancels the timer.

### 6. Killpower check (LOWBATT)

1. Let it drain to `LOWBATT`, or force it with FSD.
2. Confirm the UPS **cuts its output** (outlets dead).
3. Restore mains power.
4. Confirm **server powers itself back on**.

> ⚠️ **If the UPS does not cut its output**, server stays `halted` and will not restart on its own. That needs manual intervention, or a smart plug upstream.

---

## 🚨 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot load USB library` | `libusb-1.0-0-dev` missing | `sudo apt install libusb-1.0-0-dev` |
| `Duplicate driver instance` | Stale PID file | `sudo rm -f /run/nut/*.pid` |
| `upsd disabled` | `MODE` not set in `nut.conf` | `echo 'MODE=netserver' \| sudo tee /etc/nut/nut.conf` |
| `unauthorized command` on hypervisor | `hypervisor-emergency-shutdown` not whitelisted in the wrapper | Add the case to `/usr/local/sbin/n8n-qm-wrap` |
| `Connection failure` | `upsd` not listening | `sudo systemctl start nut-server` |
| hypervisor does not shut down | Switch not on the UPS | Move the switch onto the UPS |
| server does not restart after an outage | BIOS "Power On after AC loss" = OFF, or the UPS never cut its outlets | Enable it in the BIOS; test killpower (section 6) |
| Containers do not start at boot | `homelab-compose.service` not enabled | `sudo systemctl enable homelab-compose` |

---

## 📋 State of the installation

Verified on the server on 2026-09-21:

- [x] `upsc server-ups@localhost` returns sane data — `ups.status: OL`,
      battery 100%, input 225.2V
- [x] `nut-server` and `nut-monitor` enabled and active
- [x] `kg-ups-handler` installed at `/usr/local/bin`, owned by root
- [x] `/etc/nut/` holds the full configuration, including `kg-ups.env`
- [x] `homelab-compose.service` enabled, so the stacks come back at boot
- [x] The workstation is reachable from the server

Not verified from here, and worth re-checking before relying on it:

- [ ] The `hypervisor-emergency-shutdown` case is present in
      `/usr/local/sbin/n8n-qm-wrap` on the workstation
- [ ] `sudo -u nut ssh root@<workstation> "hypervisor-emergency-shutdown --dry-run"`
      still succeeds — the forced command is the part that silently rots, because
      nothing exercises it until a real outage does
- [ ] A real 60-second test: workstation down cleanly, server still up
- [ ] Killpower at LOWBATT: the UPS cuts its output and the server powers back
      on by itself

The second one deserves a periodic check. Everything else in this design fails
loudly; an SSH forced command that stopped matching fails at precisely the
moment it is needed and never before.

## 📝 Operational notes

- **Do not trust `battery.runtime`** while hypervisor is running: the calibration is for low load.
- **Rejected work is not lost**: the ingest queue is persistent, and `genome-reconcile` picks it up once power is back.
- **Notifications are best-effort**: if the modem is not on the UPS the ntfy push will not go out during an outage — the shutdown still proceeds.
- **OPNsense** is not in the critical path (server and hypervisor share the same /24). If it is not on the UPS it drops and comes back by itself.

---

*Written for this homelab's server/workstation pair — Green Cell PowerProof 2000VA.*
