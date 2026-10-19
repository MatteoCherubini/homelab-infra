# Architecture

A single Ubuntu Server host running nineteen services in eight stacks, run as
two Docker Compose projects, plus a UPS subsystem that deliberately runs on the host rather than in
a container.

---

## Stacks

`docker-compose.yml` at the root does four things: it fixes the project name,
it includes the stacks, it declares the shared network, and it names the one
shared volume. Each stack is a directory under `stacks/` containing a single
`compose.yml`.

```yaml
name: homelab-infra
include:
  - stacks/core/compose.yml
  - stacks/automation/compose.yml
  - stacks/git/compose.yml
  - stacks/tools/compose.yml
  - stacks/security/compose.yml
  - stacks/photos/compose.yml
  - stacks/documents/compose.yml
```

Disabling a stack is commenting out one line. Stacks are grouped by
responsibility, not by dependency, so a stack can be removed without unpicking
the others.

| Stack | Services | Doc |
|-------|----------|-----|
| `core` | nginx, homepage, cloudflared, ntfy | [core](stacks/core.md) |
| `ai` (own project) | ollama | [ai](stacks/ai.md) |
| `automation` | n8n, n8n-worker, n8n-db, n8n-redis, syncthing | [automation](stacks/automation.md) |
| `git` | forgejo | [git](stacks/git.md) |
| `security` | vaultwarden | [security](stacks/security.md) |
| `tools` | excalidraw | [tools](stacks/tools.md) |
| `photos` | immich-server, immich-db, immich-redis | [photos](stacks/photos.md) |
| `documents` | paperless, paperless-db, paperless-redis | [documents](stacks/documents.md) |

Because the network is declared at the root and inherited through the merge,
included files must not redeclare it.

**The `ai` stack is the exception:** it holds the GPU, so it runs as a project
of its own, `homelab-ai`, under its own systemd unit, and joins the network as
`external` (`homelab-infra_homelab`, a name the fixed project name keeps
stable). A broken NVIDIA driver then stops Ollama and nothing else. See
[the AI stack](stacks/ai.md#a-project-of-its-own).

---

## Networking

Every service sits on one Docker bridge network, `homelab`, and addresses the
others by service name. The subnet comes from `HOMELAB_SUBNET`.

Internal calls use container addresses and internal ports, never public
hostnames: n8n reaches Forgejo at `http://forgejo:3000`, not through the proxy.
This keeps working when the tunnel is down, never leaves the machine, and
avoids a round trip out and back in.

n8n's SSRF protection stays enabled, with an explicit hostname allowlist
(`N8N_SSRF_ALLOWED_HOSTNAMES`) rather than being switched off. A service that
n8n needs to call must be added there, or the request is blocked.

## Host network and physical topology

The Docker network above sits on a physical layout described nowhere else. It
cost an afternoon to reconstruct from switch screenshots after a house move,
which is the only argument this section needs.

The server has **one** interface, addressed statically in
`/etc/netplan/50-cloud-init.yaml`:

| | |
|---|---|
| Server | `<server-address>/24` on its one interface |
| Gateway and DNS | `<gateway>` — an OPNsense firewall on a small board |
| Hypervisor | `<hypervisor-address>` |

Static rather than DHCP, because the addresses are dependencies: the UPS
handler and the workflows reach the hypervisor through SSH forced commands,
and a lease that moves breaks them silently. Each address is written in one
place on the server — `n8n-runner`'s SSH aliases, `/etc/nut/kg-ups.env` —
never in this repository. See [UPS orchestration](stacks/ups.md) and
[the automation stack](stacks/automation.md#reaching-the-other-machines-roles-aliases-forced-commands).

The segment is carried by a TP-Link Easy Smart switch with 802.1Q VLANs:

| VLAN | Name | Untagged ports | Carries |
|------|------|----------------|---------|
| 1 | Default | 7, 8 | — |
| **10** | **TRUSTED** | 2, 3, 4 | the trusted subnet — server, hypervisor |
| 20 | IOT | 5, 6 | isolated devices |

Port 1 is the trunk to the router, tagged on 10 and 20 and untagged on 1. The
switch's own management page answers over HTTP on the TRUSTED VLAN and has no
SSH; its address comes from DHCP, so it moves.

The consequence worth carrying: **moving a machine to a port outside its VLAN
puts it in a different broadcast domain**, where it is unreachable however
correct its addressing is, because ARP does not cross a VLAN boundary. A cable
that lands in the wrong port during a move looks exactly like a dead host.

## External access

**Nothing comes in.** The whole setup moves between places during the year,
so the upstream router is never configured: no port forward, no exposed host,
no dynamic DNS. Every path from outside is a connection the server opens
itself:

- **Cloudflare Tunnel** for the public services, over an outbound connection.
- **Tailscale** for administration, reaching the server only; the other
  machines are reached through it by SSH (`ProxyJump`), with the laptop's keys.

The firewall's WAN is a DHCP client with no inbound rule, which works behind
any router, carrier-grade NAT included. Its internal subnets must not overlap
the upstream router's, and common modem ranges are best avoided.

Inside, **Nginx Proxy Manager** terminates TLS and routes by hostname; the
firewall's DNS resolves the same hostnames to the server.

Only the services that need to be reachable from outside are published. Admin
surfaces and unauthenticated APIs are bound to loopback — Syncthing's GUI and
API on `127.0.0.1:8384`, Ollama on `127.0.0.1:11434` — and are not exposed on
the LAN at all.

## Storage

| Path | Holds |
|------|-------|
| `${DATA_ROOT}` | Per-service state: databases, configuration, Ollama models, Immich's thumbnails, Paperless's search index |
| `${MEDIA_ROOT}` | Forgejo repositories, on the RAID array |
| `${MEDIA_ROOT}/backup/dumps` | Consistent database copies, refreshed before every off-site backup |
| `${MEDIA_ROOT}/archive` | Documents kept ten years — contracts, invoices, filings, and Paperless's export — backed up as a set of their own |
| `${MEDIA_ROOT}/host-configs` | The firewall's, the hypervisor's and the guests' configuration, copied from the laptop — see [backup](backup.md#other-machines) |
| `${MEDIA_ROOT}/immich` | Immich's own files: the phone app's uploads, profile pictures, converted videos — see [photos](stacks/photos.md#folders) |
| `${MEDIA_ROOT}/paperless` | Paperless's originals and its consumption folder; its export lives in `archive/paperless` — see [documents](stacks/documents.md#folders) |
| `${GENOME_MEDIA_ROOT}` | One folder per genome, `media/` catalogued by Immich read-only, `sorgenti/` (RAW) and `inbox/` beside it |
| `${PHOTO_PERSONAL_ROOT}` | One folder per personal project, the same shape; backed up as the `personal` set |
| Off-site (S3) | restic repositories, one per backup set, encrypted on this host — see [backup](backup.md) |

Nothing stateful is tracked in git. Both roots live outside the repository
directory in intent, and `data/` is gitignored regardless.

The split is deliberate: the root disk is fast and expendable, the array holds
the one dataset — git repositories — whose loss cannot be recovered from an
image.

## GPU

One NVIDIA GPU, reserved by one container: Ollama, with the `gpu` capability.
It is the one part of the host an unattended update can take away under a
running container, so everything that reserves it lives in the `ai` project
and nowhere else.

---

## Design decisions

**Compose rather than Kubernetes.** The workload is a single host with a GPU.
Kubernetes would add an orchestration layer whose failure modes are harder to
debug than the problems it would solve here.

**Pinned tags, with three exceptions.** Cloudflared and Excalidraw hold no
state; Ollama's models live in a volume the image does not own. Everything else
is pinned so that "what is running" is answerable from the repository. See
[updating](updating.md).

**Configuration is data, not shell.** `.env` is parsed key by key rather than
sourced. See [configuration](configuration.md).

**Verification is a first-class artefact.** `docker compose ps` reports that a
process is alive, which is not the same as the service working. See
[testing](testing.md).

**Host-level pieces are visible.** Anything installed outside a container lives
in `host/` rather than being described only in prose, so the boundary between
what Compose manages and what it does not is explicit.
