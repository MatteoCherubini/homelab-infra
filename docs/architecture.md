# Architecture

A single Ubuntu Server host running thirteen services in six Docker Compose
stacks, plus a UPS subsystem that deliberately runs on the host rather than in
a container.

---

## Stacks

`docker-compose.yml` at the root does three things: it includes the stacks, it
declares the shared network, and it names the one shared volume. Each stack is
a directory under `stacks/` containing a single `compose.yml`.

```yaml
include:
  - stacks/core/compose.yml
  - stacks/ai/compose.yml
  - stacks/automation/compose.yml
  - stacks/git/compose.yml
  - stacks/tools/compose.yml
  - stacks/security/compose.yml
```

Disabling a stack is commenting out one line. Stacks are grouped by
responsibility, not by dependency, so a stack can be removed without unpicking
the others.

| Stack | Services | Doc |
|-------|----------|-----|
| `core` | nginx, homepage, cloudflared, ntfy | [core](stacks/core.md) |
| `ai` | ollama | [ai](stacks/ai.md) |
| `automation` | n8n, n8n-worker, n8n-db, n8n-redis, syncthing | [automation](stacks/automation.md) |
| `git` | forgejo | [git](stacks/git.md) |
| `security` | vaultwarden | [security](stacks/security.md) |
| `tools` | excalidraw | [tools](stacks/tools.md) |

Because the network is declared at the root and inherited through the merge,
included files must not redeclare it.

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

The server has **one** interface, `enp37s0`, addressed statically in
`/etc/netplan/50-cloud-init.yaml`:

| | |
|---|---|
| Server | `10.0.10.20/24` on `enp37s0` |
| Gateway and DNS | `10.0.10.1` — OPNsense, running on a ZimaBoard |
| Workstation (`torre`) | `10.0.10.10` |

Static rather than DHCP, because the address is a dependency: the UPS handler
reaches the workstation by address through an SSH forced command, and a lease
that moves breaks it silently. See [UPS orchestration](stacks/ups.md).

The segment is carried by a TP-Link Easy Smart switch with 802.1Q VLANs:

| VLAN | Name | Untagged ports | Carries |
|------|------|----------------|---------|
| 1 | Default | 7, 8 | — |
| **10** | **TRUSTED** | 2, 3, 4 | `10.0.10.0/24` — server, workstation |
| 20 | IOT | 5, 6 | isolated devices |

Port 1 is the trunk to the router, tagged on 10 and 20 and untagged on 1. The
switch's own management page answers over HTTP on the TRUSTED VLAN and has no
SSH; its address comes from DHCP, so it moves.

The consequence worth carrying: **moving a machine to a port outside its VLAN
puts it in a different broadcast domain**, where it is unreachable however
correct its addressing is, because ARP does not cross a VLAN boundary. A cable
that lands in the wrong port during a move looks exactly like a dead host.

## External access

Two paths in, both terminating at the same place:

- **Nginx Proxy Manager** handles TLS and routes by hostname.
- **Cloudflare Tunnel** reaches Cloudflare over an *outbound* connection, so
  nothing has to be opened inbound on the router.

Only the services that need to be reachable from outside are published. Admin
surfaces are bound to loopback — Syncthing's GUI and API are on
`127.0.0.1:8384` and are not exposed on the LAN at all.

## Storage

| Path | Holds |
|------|-------|
| `${DATA_ROOT}` | Per-service state: databases, configuration, Ollama models |
| `${MEDIA_ROOT}` | Forgejo repositories, on the RAID array |

Nothing stateful is tracked in git. Both roots live outside the repository
directory in intent, and `data/` is gitignored regardless.

The split is deliberate: the root disk is fast and expendable, the array holds
the one dataset — git repositories — whose loss cannot be recovered from an
image.

## GPU

One NVIDIA GPU, shared by declaration rather than by contention: Ollama
reserves it with the `gpu` capability for inference, Homepage reserves it with
only `utility` to read telemetry for the dashboard.

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
