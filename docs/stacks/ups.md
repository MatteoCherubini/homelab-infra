# UPS orchestration

Ordered shutdown, hypervisor → server, on mains failure, with automatic
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
| Where the handler finds the hypervisor, and the ntfy token | `/etc/nut/kg-ups.env`, `root:nut`, mode 0640 |

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
    │   +     │◄── hypervisor      │  └───────────┘  │
    │         │    (~400W)         │                 │
    │   IEC   │◄── switch          │                 │
    └────┬────┘◄── modem (opt.)   │  kg-ups-handler │
         │                         └────────┬────────┘
         │                                  │ SSH (nut)
         │                         ┌────────┴────────┐
         └────────────────────────►│   hypervisor    │
                                   │  (Proxmox VE)   │
                                   │                 │
                                   │ hypervisor-     │
                                   │ emergency-      │
                                   │ shutdown        │
                                   └─────────────────┘
```

### Shutdown strategy

| Node | Load | Shutdown time | Decision |
|------|------|---------------|----------|
| **hypervisor** (GPU) | up to ~400W | slow (guests → host) | **goes down first**, at `ONBATT` + the grace period |
| **server** | ~80W | fast | **stays up**, goes down at `LOWBATT` |

The grace period is the `START-TIMER` value in `upssched.conf` — 180 seconds
here. It rides out flickers and short outages; a shorter one leaves more battery
for the server. The handler's messages do not repeat the number, so changing it
is one edit.

---

## 🔌 Hardware checklist

| Component | Status | Note |
|-----------|--------|------|
| Green Cell PowerProof 2000VA UPS | ✅ | `nutdrv_qx` driver, `q1` protocol |
| server (main server) | ✅ | On the Schuko outlet |
| hypervisor (Proxmox/GPU) | ✅ | On the Schuko outlet |
| Network switch | ✅ | **Must** be on the UPS |
| USB cable, UPS → server | ✅ | Check it after every move: `lsusb -d 0665:5161` must print a line |
| Modem/ONT | ⚠️ opt. | Needed for ntfy notifications during an outage |
| server BIOS: "Power On after AC loss" | ✅ | ON — tested 2026-10-13: halted, cord pulled 30 s, back on by itself |
| hypervisor BIOS: "Stay Off after AC loss" | ✅ | ON, plus WoL from S5 |

> ⚠️ **Without the switch on the UPS**, the server cannot tell the hypervisor to shut down during an outage.

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

> `runtimecal` is calibrated at 4–8% load (~50–100W). With the hypervisor running (~33% = ~400W) the `battery.runtime` estimate is **optimistic and unreliable** — the shutdown logic keys off time since `ONBATT`, not off runtime.

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
NOCOMMWARNTIME 3600
SHUTDOWNCMD "/usr/local/bin/kg-ups-handler server-down"
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE  SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK  SYSLOG+WALL+EXEC
NOTIFYFLAG NOCOMM  SYSLOG+WALL+EXEC
```

> `SHUTDOWNCMD` is run by **upsmon**, which re-elevates to root — not by upssched.

### `/etc/nut/upssched.conf`

```ini
CMDSCRIPT /usr/local/bin/kg-ups-handler
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

AT ONBATT  * START-TIMER  hypervisor-down 180
AT ONBATT  * EXECUTE      notify-onbatt
AT ONLINE  * CANCEL-TIMER hypervisor-down
AT ONLINE  * EXECUTE      notify-online
AT COMMBAD * START-TIMER  notify-commbad 60
AT COMMOK  * CANCEL-TIMER notify-commbad notify-commok
AT NOCOMM  * EXECUTE      notify-nocomm
```

The last three lines watch the link to the UPS, which is the one failure
everything else here cannot report: with no data from the UPS there is no
`ONBATT`, so no shutdown and no notice.

- **`COMMBAD`** is a link that was up and went. A loss shorter than a minute
  says nothing; a longer one sends one notice.
- **`COMMOK`** cancels that notice if it has not gone yet, and otherwise says
  the link is back: `CANCEL-TIMER <name> <cmd>` runs `<cmd>` only when the
  timer has already fired.
- **`NOCOMM`** repeats every `NOCOMMWARNTIME` seconds, an hour here, while the
  UPS stays unreadable. It is also the only notice when the link never came up
  at boot, since there was no link to lose.

### Startup

```bash
sudo systemctl restart nut-server nut-monitor
sudo upsc server-ups@localhost
```

---

## 🔐 SSH nut → hypervisor (forced command)

**The problem:** `upssched` runs as the `nut` user, not as root. To shut the hypervisor down over SSH, `nut` needs a key and the hypervisor must accept it through its forced command, `n8n-qm-wrap`.

### On the server: a key for `nut`

```bash
sudo mkdir -p /var/lib/nut/.ssh
sudo chown nut:nut /var/lib/nut /var/lib/nut/.ssh
sudo chmod 700 /var/lib/nut/.ssh

sudo -u nut ssh-keygen -t ed25519 -f /var/lib/nut/.ssh/id_ed25519 -N "" -C "nut@<server>"
```

### On the hypervisor: the wrapper and the scripts

The wrapper and the scripts it runs come from the knowledge-genome-orchestrator
(`deploy/hypervisor`): `n8n-qm-wrap` at `/usr/local/sbin/n8n-qm-wrap`,
`hypervisor-emergency-shutdown` and `hypervisor-vm-arbiter` in
`/usr/local/bin`. The wrapper already accepts
`hypervisor-emergency-shutdown [--dry-run]`; nothing is edited by hand.

### On the hypervisor: authorized_keys

On Proxmox `/root/.ssh/authorized_keys` is a link to
`/etc/pve/priv/authorized_keys`. Add:

```text
command="/usr/local/sbin/n8n-qm-wrap",no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC... nut@<server>
```

### On the server: where the handler finds the hypervisor

`/etc/nut/kg-ups.env`, owned by `root:nut` with mode 0640 — never in the
handler, never in `.env`. `upssched` runs the handler as `nut`, so a file only
root can read leaves it without a target and without the token:

```bash
KG_UPS_HYPERVISOR=root@<hypervisor-address>
NTFY_TOKEN=tk_...
```

### Verify

```bash
sudo -u nut ssh -i /var/lib/nut/.ssh/id_ed25519 -o ConnectTimeout=5 -o BatchMode=yes \
  root@<hypervisor-address> "hypervisor-emergency-shutdown --dry-run"
```

It must print the dry-run output **without** `unauthorized command`.

---

## 🧠 Orchestration scripts

### `kg-ups-handler` (on the server)

Source: `host/kg-ups-handler`. Install with:

```bash
sudo install -m 0755 host/kg-ups-handler /usr/local/bin/kg-ups-handler
```

It reads `KG_UPS_HYPERVISOR` and the ntfy token from `/etc/nut/kg-ups.env`.
With `KG_UPS_HYPERVISOR` empty it shuts nothing down and says so, urgently.

Handles:
- `hypervisor-down` → SSH to the hypervisor for a graceful shutdown
- `server-down` → `compose down` plus halt (called by upsmon at LOWBATT)
- `notify-onbatt` / `notify-online` → ntfy notifications
- `notify-commbad` / `notify-commok` / `notify-nocomm` → ntfy notifications
  when the server cannot read the UPS, and when it can again

> **Note:** the SSH command sent to the hypervisor must be **the bare name** (`hypervisor-emergency-shutdown`), not the full path — the `n8n-qm-wrap` wrapper matches on names.

### `hypervisor-emergency-shutdown` (on the hypervisor)

On Proxmox it runs:
1. `qm shutdown` for every running guest (graceful, 90s timeout)
2. a forced `qm stop` for anything still up
3. `shutdown -h now`

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
sudo -u nut ssh -i /var/lib/nut/.ssh/id_ed25519 root@<hypervisor-address> "hypervisor-emergency-shutdown --dry-run"
```

### 3. Dry run

On the server:
```bash
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler hypervisor-down
KG_UPS_DRYRUN=1 /usr/local/bin/kg-ups-handler server-down
```

The first one goes through the hypervisor's forced command for real, with
`--dry-run`: it fails if the wrapper stopped accepting the verb.

On the hypervisor:
```bash
/usr/local/bin/hypervisor-emergency-shutdown --dry-run
```

### 4. Simulated event (FSD)

⚠️ **This really does shut things down.**

```bash
sudo upsmon -c fsd
```

### 5. Real grace-period test

1. Pull the UPS plug from the wall, with the hypervisor running.
2. Wait past the grace period (180 seconds here).
3. **The hypervisor** must shut down cleanly (guests → host halt).
4. **server** must stay up.
5. Plug it back in before `LOWBATT` → `ONLINE` cancels the timer.

### 6. Killpower check (LOWBATT)

1. Let it drain to `LOWBATT`, or force it with FSD.
2. Confirm the UPS **cuts its output** (outlets dead).
3. Restore mains power.
4. Confirm **server powers itself back on**.

> ⚠️ **If the UPS does not cut its output**, server stays `halted` and will not restart on its own. That needs manual intervention, or a smart plug upstream.

### 7. Losing the link to the UPS

Harmless: nothing is shut down.

1. Unplug the USB cable at the server and wait more than a minute.
2. Expected: the notice "UPS link lost", and `upsc server-ups ups.status`
   answers with an error — `Data stale` while the driver is still waiting for
   the device, `Driver not connected` once it has given up.
3. Plug it back in. Within about 15 seconds `ups.status` is `OL` again, and the
   notice "UPS link back" arrives.

`make healthcheck` reports the same state on its own line under "Power".

---

## 🚨 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot load USB library` | `libusb-1.0-0-dev` missing | `sudo apt install libusb-1.0-0-dev` |
| `Driver not connected`; the driver's journal says `insufficient permissions on everything` and restarts every 15 s | The UPS is not on the USB bus at all. Finding nothing, the driver tries every other USB device and is refused by each: it reads like a permissions problem and is not one | `lsusb -d 0665:5161`; plug the cable back in. The driver picks it up by itself within 15 s |
| `Duplicate driver instance` | Stale PID file | `sudo rm -f /run/nut/*.pid` |
| `upsd disabled` | `MODE` not set in `nut.conf` | `echo 'MODE=netserver' \| sudo tee /etc/nut/nut.conf` |
| `unauthorized command` on the hypervisor | The wrapper does not accept `hypervisor-emergency-shutdown` | Install the orchestrator's `deploy/hypervisor/n8n-qm-wrap` at `/usr/local/sbin/n8n-qm-wrap` |
| `Connection failure` | `upsd` not listening | `sudo systemctl start nut-server` |
| The hypervisor does not shut down | Switch not on the UPS, or `KG_UPS_HYPERVISOR` empty | Move the switch onto the UPS; set it in `/etc/nut/kg-ups.env` |
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

Verified on 2026-10-15:

- [x] `KG_UPS_DRYRUN=1 kg-ups-handler hypervisor-down`, run as `nut`, reaches
      the hypervisor's forced command with the role names and prints its dry run
- [x] The UPS back on the USB bus. It had been left unplugged after a move, and
      for days nothing said so: the driver restarted every 15 seconds, upsmon
      wrote to the journal, and `make healthcheck` still passed. A manual
      `upscmd -l` found it. That is why the link is now watched (the last three
      lines of `upssched.conf`) and checked (`make healthcheck`, "Power")

Not verified yet, and worth doing before relying on them:

- [ ] The link watch: test procedure, section 7
- [ ] A real grace-period test: hypervisor down cleanly, server still up
- [ ] Killpower at LOWBATT: the UPS cuts its output and the server powers back
      on by itself

The dry run deserves a periodic check, at the quarterly session: an SSH forced
command that stopped matching fails at precisely the moment it is needed and
never before. A missing link to the UPS used to fail the same way; now it says
so, within a minute when the link drops and within the hour when it never came
up.

## 📝 Operational notes

- **Do not trust `battery.runtime`** while the hypervisor is running: the calibration is for low load.
- **Rejected work is not lost**: the ingest queue is persistent, and `genome-reconcile` picks it up once power is back.
- **Notifications are best-effort**: if the modem is not on the UPS the ntfy push will not go out during an outage — the shutdown still proceeds.
- **The firewall** is not in the critical path (the server and the hypervisor share one subnet). If it is not on the UPS it drops and comes back by itself.

---

*Written for this homelab's server/hypervisor pair — Green Cell PowerProof 2000VA.*
