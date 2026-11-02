# Core stack

`stacks/core/compose.yml` — everything the rest of the infrastructure depends
on to be reachable and to report on itself.

| Service | Role |
|---------|------|
| `nginx` | Nginx Proxy Manager: reverse proxy, TLS termination |
| `homepage` | Dashboard and service discovery |
| `cloudflared` | Cloudflare Tunnel |
| `ntfy` | Push notifications |

---

## Nginx Proxy Manager

Publishes 80, 443 and the admin UI on 81. It holds the certificates in
`${DATA_ROOT}/nginx/letsencrypt` and its own configuration in
`${DATA_ROOT}/nginx/data`.

It is classified `critical` in `services_metadata.json`: everything reachable
from outside passes through it, so an upgrade that goes wrong takes every
published service with it.

**On a server where `tailscale serve` also uses 443, publish Nginx's 443 on
the LAN address only:** `NGINX_HTTPS_PORT=<lan-address>:443` in `.env` (the
compose file takes `address:port` there as it is). Since Tailscale 1.104,
`tailscaled` holds a real socket on the tailnet address for every serve port,
and Linux refuses a container that asks for the same port on every address.
Whichever starts first wins. On 2026-11-02 an upgrade restarted both, Tailscale
came back first, and Nginx failed with `address already in use`; `docker
compose up` then interrupted every service still waiting for a database, so
half the stack stayed down and `homelab-compose` ended in `failed`. The same
race runs at every boot, after a blackout too. With the LAN address the two
never meet, and no address changes: the tailnet keeps its 443 for the service
it serves, the LAN keeps Nginx. The rule underneath: a `tailscale serve` port
never equals a port published on every address.

A caveat that matters when checking whether it works: **Nginx answers `200`
from its own frontend even when the service behind it is broken.** That is why
`make healthcheck` asserts on response bodies for the services that expose a
meaningful health endpoint, rather than trusting the status code alone.

## Homepage

Reads `/var/run/docker.sock` read-only to discover containers. It holds no
GPU reservation: one would put the dashboard in the GPU's failure domain, and
with a broken driver it would go down exactly when it is wanted — see
[the AI stack](ai.md).

`HOMEPAGE_ALLOWED_HOSTS` must list the hostnames the dashboard is served on, or
it refuses the request. It defaults to `*` here.

## Cloudflared

Runs `tunnel --no-autoupdate run` with a token from `.env`. The tunnel
establishes an **outbound** connection to Cloudflare, so nothing has to be
opened inbound on the router.

`--no-autoupdate` is deliberate: the image is the unit of version control, and
a binary that updates itself underneath a pinned tag defeats the point. The tag
is pinned in `.env`, like every stateful service's, and the update checker
follows it as a calendar version. On `latest` it was found seven months behind,
on the day Cloudflare asked every tunnel to upgrade. See
[updating](../updating.md).

To upgrade, bump `CLOUDFLARED_VERSION`, then pull and recreate: restarting a
container on the old image changes nothing. The tunnel is down for a few
seconds, and only public traffic notices.

```bash
docker compose pull cloudflared
docker compose up -d --no-deps cloudflared
docker exec cloudflared cloudflared --version
docker logs --since 2m cloudflared 2>&1 | grep -iE "registered|error"   # four connections
```

Cloudflare's dashboard lists every connector with its version, under Networking
→ Tunnels. If a route points to an `https://` origin, its certificate must
validate. Never fix an error there by turning on *No TLS Verify*.

Consequence worth knowing: when the tunnel is down, anything addressed by its
public hostname stops resolving. Internal calls between services use container
names precisely so they do not depend on it.

## ntfy

Push notifications for the update checker, the UPS handler and the n8n
workflows.

It is configured **deny-by-default**: `NTFY_AUTH_DEFAULT_ACCESS=deny-all`, with
an auth database at `/var/lib/ntfy/auth.db`. Anonymous users have no access to
any topic; publishing requires a token. `NTFY_BEHIND_PROXY=true` makes it trust
the forwarded client address for rate limiting.

Only the auth database is persisted. The message cache is in memory, so
notifications are not durable — which is the right trade for alerts that are
only interesting while they are fresh.

**One user per laptop, with only its topics.** A laptop follows its topics
with ntfy's own client (the dotfiles install it, with a user service and the
token read from Vaultwarden). It gets a user of its own and access to the
topics it needs, never the admin's token — so a collaborator's laptop that is
lost is one user to delete:

```bash
docker exec -it ntfy ntfy user add laptop-<who>                  # asks for a password
docker exec ntfy ntfy access laptop-<who> genome-requests rw     # genomes to create; it publishes there too
docker exec ntfy ntfy access laptop-<who> homelab-genome ro      # the pipeline's notifications
docker exec ntfy ntfy token add laptop-<who>                     # the token, into Vaultwarden
```

| Topic | Who publishes | Who reads |
|-------|---------------|-----------|
| `genome-requests` | the owner's laptop (`studio_genomes.py`, [business](business.md)) | the phone, the laptops |
| `homelab-genome` | the orchestrator's flows in n8n | the phone, the laptops |
| `studio` | the hours reminder | the phone |

**Subscriptions only on this server.** In the phone app a topic is added with
*Use another server* and this installation's address; without it the app uses
`ntfy.sh`, where a topic is public — anyone could publish a fake "genome to
create" with a command in it. The same holds for the CLI: without its
`client.yml`, `ntfy publish` goes to `ntfy.sh`. That is why
`studio_genomes.py` reads the server from `client.yml` itself and publishes to
it by full address, or not at all.

**The password of a laptop user is nobody's.** The laptop uses its token, so
the password is set to a random value no one keeps:

```bash
sudo docker exec -e NTFY_PASSWORD="$(head -c 32 /dev/urandom | base64)" ntfy ntfy user change-pass laptop-<who>
```

**Rotating a laptop's token** — for instance after it was printed somewhere,
as happened on 2026-10-31 with `chezmoi apply -v`:

```bash
docker exec ntfy ntfy token remove laptop-<who> <old token>
docker exec ntfy ntfy token add laptop-<who>                     # into the same Vaultwarden item
```

Then, on the laptop, `bw sync` (bw reads a local copy and would hand back the
old token) and the laptop's `client.yml` is rebuilt from Vaultwarden — the
dotfiles README has the blocks. A check that never prints the token:
`curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer …" https://<ntfy>/v1/account`
answers 200 for a valid token, 401 for a removed one.

To check it end-to-end without touching a real topic, grant anonymous access to
a throwaway one, publish, read back, and revoke:

```bash
docker exec ntfy ntfy access '*' healthcheck-tmp rw
curl -d "test" http://127.0.0.1:8091/healthcheck-tmp
curl -s "http://127.0.0.1:8091/healthcheck-tmp/json?poll=1"
docker exec ntfy ntfy access --reset '*' healthcheck-tmp
```

Since v2.28.0 heavy polling draws on the same budget as attachment downloads
(`visitor-attachment-daily-bandwidth-limit`), because a poll without a `since`
cursor replays a topic's whole cache. Not a concern at homelab volumes, but it
is the kind of limit that only shows up under an automated poller.
