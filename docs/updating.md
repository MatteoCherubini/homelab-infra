# Updating

Image versions are pinned in `.env` and never floated, with two deliberate
exceptions: **Excalidraw**, which holds no state, and **Ollama**, whose models
live in a volume the image does not own. Everything else is pinned so that
"what is running" is answerable from the repository.

**Cloudflared used to be the third exception, and it is the case against
floating.** It holds no state, so `latest` looked harmless. But with
`--no-autoupdate`, `latest` means whatever was pulled last, and the checker
skips `latest` tags, so nothing ever said it was behind. On 2026-10-28 an
e-mail from Cloudflare asked every tunnel for 2026.10.2 or later, because older
builds still trusted eight compromised eMudhra intermediate certificates. The
running tunnel was 2026.3.0, seven months old. "Holds no state" answers whether
an upgrade can break something. It does not answer whether you will hear about
one, and the door to the internet is the service where that matters most.

The path is automated up to the point of decision, and manual past it.

---

## 1. Detection — `scripts/check_updates.py`

The script builds a manifest of every service from `docker compose config`,
enriches it from `services_metadata.json`, and queries each upstream forge for
the newest stable release **on the current major branch**.

It speaks to GitHub, Codeberg, and any Gitea-compatible API through an
extensible registry, with an RSS fallback when the API path fails. Output is
JSON on stdout for n8n, warnings on stderr, and the exit code is always 0 so a
failure never crashes the workflow.

Two properties of the selection logic are there because their absence caused
real bugs:

**Candidates are compared by semantic version, not by API order.** Forges sort
`/releases` by tag creation date, which for two releases published on the same
day can invert version order. On 2026-09-21 GitHub listed n8n 2.39.9 before
2.39.10, and taking the first element proposed a version superseded that same
day.

**Pre-release keywords are matched as version markers, not substrings.** A bare
`"rc" in title` hits *architecture*, *source*, *search* and *force*; `dev` hits
*device*; `test` hits *latest*. On a forge that titles releases with a sentence,
six out of nine legitimate titles would be discarded.

Both matter more than they look, because **this script fails silently**. If
release selection wrongly discards a valid release, nothing errors — it reports
"no updates", which is indistinguishable from there genuinely being none, and
the host can sit on a vulnerable version for months. Both behaviours are pinned
by unit tests; see [testing](testing.md).

Staying on the current major is also deliberate. Forgejo publishes 15.x and
16.x in parallel; the checker reports 15.0.9, not 16.0.5. Crossing a major is a
decision, not an update.

**Except for calendar versions.** Cloudflared tags `year.month.patch`, so its
"major" is a year. Staying on it, a tunnel pinned on 2026.10.5 would hear of
every release until December and of none from January on. That would be the
same silence as the floating tag, only postponed. A service marked
`"versioning": "calendar"` in `services_metadata.json` is searched across
years. A new year counts as a minor, not a major, and its drift is counted in
months: one month weighs what a minor does, so five months behind reaches the
workflow's drift threshold. The value is checked against the known ones,
because a misspelt `calender` would fall back to semver without a word.

## 2. Notification

An n8n workflow runs the checker on a schedule and pushes a summary to ntfy.

## 3. Risk assessment

A second pass asks a locally hosted model, through Ollama, to rank the updates
by risk and propose an order.

**This is an aid, not an authority.** It has no access to upstream release
notes and reasons from version numbers alone. It once described a Forgejo patch
release as a routine patch on a day when 15.0.8 and 15.0.9 between them closed
two critical remote code execution holes.

## 4. Decision and application — by a person

Read the actual release notes. Then, per service:

```bash
make backup                                   # an off-site snapshot of everything first
make healthcheck                              # before

docker compose stop <service>                 # stateful services only
# snapshot the data directory, and for a database take a logical dump
# and verify it is restorable rather than assuming it

# bump the version in .env
docker compose pull <service>
docker compose up -d --no-deps <service>

make healthcheck                              # after
```

`--no-deps` keeps the blast radius to the service being touched.

Ollama is in a project of its own: for it, the same commands start with
`docker compose --project-directory . -f stacks/ai/compose.yml` instead of
`docker compose`. See [the AI stack](stacks/ai.md#a-project-of-its-own).

Because tags are pinned, rolling a **container** back is restoring the previous
value in `.env`. Rolling a **database migration** back is not — which is why
the snapshot comes first, and why `make healthcheck` prints a data fingerprint
to compare on both sides.

Order by ascending risk. Stateless first, then services whose migrations are
small, then the ones with a large version gap. Update the notification channel
early, while you are still watching it.

Per-service upgrade notes live with each stack:
[automation](stacks/automation.md) · [git](stacks/git.md) ·
[security](stacks/security.md) · [core](stacks/core.md) ·
[photos](stacks/photos.md#updating) ·
[documents](stacks/documents.md#updating) ·
[business](stacks/business.md#updating)

### Upgrading Docker or containerd restarts every stack

`homelab-compose.service` has `Requires=docker.service`, so when apt restarts
Docker or containerd, systemd restarts the stacks too: `compose down`, then
`compose up -d`. And `compose up` stops at the first container that fails to
start, leaving every service still waiting on a dependency in `created`: one
failure takes half the stack with it, and the unit ends in `failed`, where
`systemctl stop homelab-compose` — what the UPS handler runs before the halt —
does nothing. On 2026-11-02 the failure was a port taken by Tailscale, upgraded
in the same run ([core](stacks/core.md#nginx-proxy-manager)).

So a host upgrade that touches Docker, containerd or Tailscale is an upgrade
of everything: `make backup` first, run it inside `tmux`, and afterwards

```bash
systemctl is-active homelab-compose homelab-ai    # both: active
make healthcheck
```

If something stayed `created`, the journal says why
(`journalctl -u homelab-compose --since -30min`); once fixed,
`sudo systemctl start homelab-compose && sudo systemctl start homelab-ai`
brings the units back to `active`.

### Measure the baseline with the tool you will judge by

Run the verification **before** the upgrade, not only after, and run the same
command both times. Otherwise a fault that was already there becomes evidence
against the change you just made.

Upgrading Nginx Proxy Manager to 2.16.0 is the case that proves it. The
pre-upgrade `certbot renew --dry-run` failed on one of five certificates: a
proxy host pointing at a container that no longer ran, returning 503 to the
HTTP-01 challenge. The release had bumped certbot by two minor versions and
warned that DNS plugins might break. Had that dry-run been run only afterwards,
the obvious reading would have been that certbot was broken, and the obvious
response a rollback that fixed nothing and gave up the security fixes.

Recording the expected result of each check, including the ones expected to
fail, is what makes the post-upgrade output readable.

### Verify through the path the application really uses

When a release changes a tool the service drives — certbot, a database client,
a backup helper — invoking that tool by hand can fail for reasons that are not
the fault being looked for. 2.16.0 also started removing DNS provider
credentials from disk around each certbot run, which would make a hand-run
renewal of a DNS-validated certificate fail while the service's own renewal
works. In the event the credentials stayed on disk and the manual run was
conclusive, but the check was written to be read either way: a gate whose
failure has two possible meanings is not a gate.

### Do not measure immediately after a restart

`make healthcheck` run seconds after `docker compose up -d` reports `HTTP 000`
on services that have not finished binding their port. That is the measurement
being too early, not the service being down. Wait for the health endpoint to
answer, then measure.

## 5. Record it

Bump the versions in `.env.example` too. That file is the source of truth for
what a valid configuration looks like, and `make verify` is only meaningful if
the repository claims what the runtime is actually running.

## 6. The other machines

The firewall, the hypervisor and its guests, and the laptops have packages of
their own. The rule is the same as for the images: read first, then one
machine at a time, each checked before the next. The order: the hypervisor,
then its guests, so each reboots once; the firewall from the LAN, in a quiet
moment; the laptop last, since its reboot ends whatever session you were
running from it.

**A copy of the configuration first.** `scripts/host-config-copy.sh`, from the
laptop, with the machine's profile ([backup](backup.md#other-machines)). A
failed upgrade then costs a reinstall and a restore, not a reconstruction.

**Read what apt will install, not only what it will upgrade.** `apt list
--upgradable` leaves out new packages, and a new kernel series arrives as one.
On 2026-11-03 the hypervisor listed 235 upgrades and no kernel, while the
simulation showed kernel 7.0 being installed beside 6.17. It also shows
removals, and there should be none:

```bash
apt -s full-upgrade 2>/dev/null | grep -E '^Remv|^Inst [^ ]+ \('
```

**Run it inside `tmux`, with `apt full-upgrade`**, never `apt upgrade`, which
holds back anything that needs a new package: on a hypervisor, the kernel.

**A changed configuration file keeps the local version.** The upgrade asks
about the files you edited, `sshd_config` first among them, and the default
answer keeps yours. Before the reboot, `sshd -t` must pass: a configuration
the new sshd refuses locks you out at boot.

**A new kernel on the hypervisor is tested through the power path.** The Power
Manager suspends the hypervisor and wakes it with Wake-on-LAN
([automation](stacks/automation.md#power-manager)), and both go through the
network driver. So the reboot is done where the console can be reached, and
after it:

```bash
ip -br addr show <bridge>          # UP, with its address: the port kept its name
ethtool <port> | grep Wake-on      # g
grep -E 'XHCI|TXHC' /proc/acpi/wakeup   # *disabled: USB wakes nothing
```

Then close every terminal on the hypervisor and run the Power Manager by hand,
`ensure-off` and then `ensure-on`: the hypervisor must suspend, wake, and the
AI node answer. What keeps a new kernel from renaming the port is the
interface names pinned to their MAC addresses, the `.link` files Proxmox VE 9
writes. The previous kernel stays installed: if the new one breaks either
step, `proxmox-boot-tool kernel pin <previous>` boots the old one until there
is a fix. On 2026-11-03, 9.1 with kernel 6.17 to 9.2 with 7.0 passed both.

**Only the network and the power button wake the hypervisor.** On 2026-11-08
a bumped mouse woke it from standby through USB, and that wake left an ACPI
event (GPE 6B, whose handler the firmware lacks) firing about 6,000 times a
second: the hypervisor woke from every suspend, and its journal, at 1.9
million lines a minute, kept only the last few minutes. A reboot cleared it.
The same event fires once on every ordinary wake, so it is not masked:
Wake-on-LAN goes through it. `host/90-no-usb-wake.rules` takes the wake away
from every USB controller instead, whatever port or device, and leaves the
network card's:

```bash
install -m 0644 host/90-no-usb-wake.rules /etc/udev/rules.d/
udevadm verify /etc/udev/rules.d/90-no-usb-wake.rules
udevadm control --reload
for c in 0x0c0330 0x0c0340; do udevadm trigger --action=add --subsystem-match=pci --attr-match=class=$c; done
cat /sys/firmware/acpi/interrupts/gpe6B      # one count per wake, not thousands a second
```

A guest in use keeps the hypervisor awake, so the desktop guest's mouse and
keyboard work as before. Asleep, the hypervisor is woken by Wake-on-LAN or by
a short press of the power button, only while it sleeps: awake, the press
shuts it down.

**The janitor is off for the duration.** The AI node counts as busy only while
`who` lists a session. A detached tmux, a dropped SSH connection or the node's
own reboot ends that, and the janitor stops the guest within five minutes, in
the middle of an upgrade if one is running. The hypervisor counts terminals
instead, so tmux does keep it on. Unpublish the janitor flow before starting
and publish it again at the end. Meanwhile push no raw note and merge no
ingest pull request, since a merge starts the next ingest. The AI node's own
steps (the GPU driver, Ollama, Node) are in the knowledge-genome-orchestrator's
runbook, «Upgrading the compute nodes».

**A vendor's repository is not the distribution.** The packages a vendor's
repository adds, a GPU driver for one, stay held on an ordinary run
(`apt-mark hold`) unless a security bulletin covers the installed version. They
are upgraded in a session of their own, with what they serve tested in it, and
released with `apt-mark unhold`.

**Runtimes stay on their major.** A version manager told to follow `lts`
crosses a major when a new line becomes LTS: Node 26 did on 2026-10-28, and
`lts` would have taken every machine from 24 to 26 at its next upgrade, without
a word. Pin the major instead, `node = "24"` in mise or `nvm alias default 24`.
Crossing it is a decision, as it is for an image (§1).

**The firewall only from the LAN.** Its upgrade ends in a reboot, and if it
does not come back, nothing outside reaches the network again. Keep a copy of
its configuration on the laptop as well as the one above, and upgrade from a
machine on the LAN.

On OPNsense the shell can take the web interface's own path, through configd
and detached from the session, so a dropped SSH connection does not stop an
upgrade halfway. Send the commands to `sh`, because root's login shell may be
the console menu or csh:

```bash
ssh <firewall> sh -s <<'EOF'
configctl firmware check      # one of the three: the "Check for updates" button
EOF
ssh <firewall> tail -f /tmp/pkg_upgrade.progress
```

- `configctl firmware check` writes its answer to `/tmp/pkg_upgrade.json`:
  the versions, the base and kernel sets, `needs_reboot`, and
  `upgrade_major_version` when a new series is offered.
  `configctl firmware running` answers `busy` until it is done;
- `configctl firmware update` installs a minor: packages, then base and
  kernel, then the reboot;
- `configctl firmware upgrade` installs a major: fetched online, then
  installed offline at the next boot, with a second reboot. About thirteen
  minutes of silence, longer than it looks.

**A major is offered only from the last minor of its series**, and a series
gets no fixes once the next one ships. So a firewall left behind is still
exposed after its minors, and catching up takes three steps. On 2026-11-04 it
went 26.1.6 → 26.1.11 → 26.7.7 → 26.7.8, about half an hour without internet
in total. `pkg audit -F` before and after measures what was closed: 32 known
problems in 15 packages before, 2 after.

**Before a major on a UFS root there is nothing to roll back to**: boot
environments (`bectl`) exist only on ZFS. The fallback is a fresh install
with the configuration restored, so prepare it first:
- the installer image, checked against the published checksum;
- written to a USB stick, then compared with the device (`cmp`);
- kept out of the machine during the upgrade, so the boot order cannot pick
  it.

Read what the major moves. In 26.7 the legacy rule pages and outbound NAT
went to the `os-firewall-legacy` plugin: the rules keep working without it,
but cannot be edited.
