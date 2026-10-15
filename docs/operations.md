# Operations

Every routine action has a `make` target. `make help` lists them.

```
make init           First-run setup: .env, data directories, permissions
make up             Start everything and remove orphan containers
make down           Stop everything
make restart        Restart every service
make ps             Status of running services
make logs           Follow logs from every service

make check          Validate prerequisites and compose configuration
make check-env      Check .env against .env.example for drift
make verify         Compare declared image tags against the running containers
make test           Offline suite: lint, syntax, JSON/YAML, secrets, unit tests
make healthcheck    End-to-end check: health endpoints + data fingerprint
make health         Show only containers that are not healthy
make gpu-check      Check for an NVIDIA GPU
make check-updates  Build the service manifest and check for new releases

make backup                Dumps, then restic to the off-site repositories
make backup-init           Create the off-site restic repositories, once
make backup-snapshots      List the snapshots of every backup set
make backup-restore-test   Restore every set into a scratch directory and verify it
make backup-maintenance    Show what the history rules would remove, remove it once confirmed, check;
                           ADMIN key, asked and never stored
```

---

## First run

```bash
cp .env.example .env
$EDITOR .env          # domains, paths, and every secret
make init             # data directories and permissions
make check            # prerequisites and compose validity
make up
make healthcheck
```

`make check` reports how many `CHANGE_ME` values are still in place. It warns
rather than failing, so it does not block a deliberate partial setup.

## Keeping the repository and the runtime honest

Three checks answer three different questions, and it is worth knowing which
answers which:

| Target | Question |
|--------|----------|
| `make check-env` | Does `.env` have every key the template declares? |
| `make verify` | Is what is running the version the repository says? |
| `make healthcheck` | Do the services actually respond? |

`make check-env` fails on a key that is missing and warns about keys present
only in `.env`. Extra keys are normal on a machine running a local-only stack
through an override — see [configuration](configuration.md).

`make verify` compares `docker compose config` against `docker compose ps`,
so it catches the case where someone bumped a version in `.env` and never
recreated the container.

## Day-to-day

```bash
make health                      # anything unhealthy right now
make logs                        # follow everything
docker compose logs -f n8n       # follow one service
./scripts/healthcheck.sh n8n     # check one service end-to-end
```

## Careful with

**`make up` passes `--remove-orphans`.** Any container carrying this project's
label that no compose file declares gets deleted. Local-only services must be
declared in `docker-compose.override.yml`, not left running from a branch that
is no longer checked out.

**`git clean -x` or `-X`** would remove `.env`,
`docker-compose.override.yml` and `data/` — the databases, the certificates,
the vault and the Ollama models. Plain `git clean -fd` is safe; the `-x` family
is not. `git clean` also reads the `.gitignore` currently checked out, so
switch branches first, then clean.

**Unattended upgrades can take the GPU away.** A driver update installed while
the machine is running leaves the kernel module and the userspace libraries
mismatched, and stops `nvidia-persistenced`; every container holding a GPU
reservation then refuses to start. `needrestart` may cycle
`homelab-compose.service` in the same window, restarting the whole stack.
Check `/var/run/reboot-required` before concluding something else broke. See
[the AI stack](stacks/ai.md).

**Restarting a service that others poll** produces a transient failure in the
pollers. An n8n workflow that queries Syncthing every minute failed once during
a 34-second Syncthing restart and succeeded on the next tick. Expected, and
self-healing — but worth recognising rather than investigating.

## When the server does not come back

The server powers itself back on when mains power returns: the BIOS is set
to *Restore on AC power loss → Power On* (tested on 2026-10-13: halted, power
cord pulled for 30 seconds, back up on its own). Wake-on-LAN stays disabled
(`ethtool enp37s0` reports `Wake-on: d`), so that is the **only** way back
without somebody at the button.

It needs the power to the server to actually drop. Unplugging the UPS from the
wall does not do it — that is what the UPS is for. After a long outage the
UPS's *killpower* does it: NUT halts the server at low battery and tells the
UPS to cut its outlets and restore them when mains returns
([UPS orchestration](stacks/ups.md)). Tested on 2026-10-15 with a forced
shutdown: outlets dark 30 seconds after the halt, back three minutes later,
the server up on its own.

It rests on two things that fail without a sound, so they are the first to
check when the server stays off after an outage: the USB cable from the UPS
(`lsusb`; the health check's "ups" line), and `POWERDOWNFLAG` in
`upsmon.conf`, without which the UPS is never told to cut anything.

It matters because a machine in that state **looks alive from outside**. The
power supply keeps the network card's PHY energised on standby, so the switch
reports the port linked at full speed, with its LED on, while the operating
system is not running at all. The only honest signal is the packet counter:
a port that has received zero packets has nothing behind it.

**Ask the journal before anything else.** One command settles whether the
machine ever booted:

```bash
journalctl --list-boots
```

A gap — no entry between the last clean shutdown and now — means no boot
happened, or none reached the point of starting the journal. No amount of
checking addresses, VLANs, cables or storage can explain that, and checking
them first is how an afternoon disappears.

Only once a boot exists is it worth asking what went wrong inside it:

```bash
journalctl -b -1 -p err      # errors from the previous boot
systemctl --failed
cat /proc/mdstat             # RAID 1: [2/2] [UU] is healthy, [2/1] [U_] is degraded
ip -br -4 addr               # one interface carries everything: enp37s0
```

Addressing and the physical layout are in
[architecture](architecture.md#host-network-and-physical-topology); the
shutdown half of the design is in [UPS orchestration](stacks/ups.md).

## Server-side

The server tracks `main` only, with a narrowed fetch refspec:

```bash
git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git fetch origin --prune
git merge --ff-only origin/main
```

Host-level artefacts — currently the UPS handler — are installed from `host/`
and are not managed by Compose. See [the UPS runbook](stacks/ups.md).
