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

A caveat that matters when checking whether it works: **Nginx answers `200`
from its own frontend even when the service behind it is broken.** That is why
`make healthcheck` asserts on response bodies for the services that expose a
meaningful health endpoint, rather than trusting the status code alone.

## Homepage

Reads `/var/run/docker.sock` read-only to discover containers. It also holds an
NVIDIA device reservation with `utility` capability, which gives it GPU
telemetry without claiming compute — see [the AI stack](ai.md).

`HOMEPAGE_ALLOWED_HOSTS` must list the hostnames the dashboard is served on, or
it refuses the request. It defaults to `*` here.

## Cloudflared

Runs `tunnel --no-autoupdate run` with a token from `.env`. The tunnel
establishes an **outbound** connection to Cloudflare, so nothing has to be
opened inbound on the router.

`--no-autoupdate` is deliberate: the image is the unit of version control, and
a binary that updates itself underneath a pinned tag defeats the point. This is
one of the three services tracked on `latest` — see
[updating](../updating.md).

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
