# Updating

Image versions are pinned in `.env` and never floated, with three deliberate
exceptions: **Cloudflared** and **Excalidraw**, which hold no state, and
**Ollama**, whose models live in a volume the image does not own. Everything
else is pinned so that "what is running" is answerable from the repository.

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

Because tags are pinned, rolling a **container** back is restoring the previous
value in `.env`. Rolling a **database migration** back is not — which is why
the snapshot comes first, and why `make healthcheck` prints a data fingerprint
to compare on both sides.

Order by ascending risk. Stateless first, then services whose migrations are
small, then the ones with a large version gap. Update the notification channel
early, while you are still watching it.

Per-service upgrade notes live with each stack:
[automation](stacks/automation.md) · [git](stacks/git.md) ·
[security](stacks/security.md) · [core](stacks/core.md)

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
