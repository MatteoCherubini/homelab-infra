# Configuration

Everything environment-specific lives in `.env`, which is never committed.
`.env.example` is the template and the single source of truth for what a valid
configuration contains.

No image tag, published port or public hostname is written into a compose file.
They are variable references, with a default where one makes sense:

```yaml
image: ${FORGEJO_IMAGE}:${FORGEJO_VERSION}
ports: ["${FORGEJO_HTTP_PORT:-3001}:3000"]
FORGEJO__server__DOMAIN: "${FORGEJO_DOMAIN}"
```

This is what makes the stacks reusable by someone else. It is also checked
rather than assumed — see [operations](operations.md) for `make check-env` and
`make verify`.

---

## `.env` is data, not a script

**Never `source` it.** A legitimate value containing spaces — an email provider
app password, for instance — makes the shell execute its second word as a
command. Compose does not use a shell to parse `.env`, so it never notices;
a shell script does.

`scripts/healthcheck.sh` reads the handful of keys it needs one at a time for
exactly this reason.

> `scripts/init.sh` still does `source .env` and carries the same latent
> defect. Known, not yet fixed.

## Secrets

Every password and token in `.env.example` is a placeholder. `make check`
reports how many `CHANGE_ME` values are still in place.

`.gitignore` covers `.env*` and explicitly re-admits `.env.example`. The rule is
deliberately broad: a narrower pattern once missed `.env.backup` and
`.env.save`, two files written by hand during maintenance that sat in the
working tree holding real credentials, untracked but one `git add -A` away from
being committed.

`make test` fails if `.env` is ever tracked, or if a private key or JWT appears
in any tracked file. See [testing](testing.md).

Secrets that a service reads from a file rather than the environment stay out
of `.env` entirely — the UPS handler's ntfy token lives in `/etc/nut/kg-ups.env`
at mode 0600, owned by root.

---

## Public hostnames

`FORGEJO_DOMAIN` and `VAULTWARDEN_DOMAIN` set the externally reachable names.
Both have a property worth knowing before the first start rather than after:

- **`FORGEJO_DOMAIN`** — changing it after the first run breaks already
  configured git remotes and webhook URLs.
- **`VAULTWARDEN_DOMAIN`** — WebAuthn binds passkeys to this exact value.
  Changing it invalidates every security key already registered.

Public hostnames are for people. Services address each other by container name
on the internal network, which keeps working when the tunnel is down and never
leaves the machine. [automation](stacks/automation.md) covers the
`FORGEJO_URL` / `FORGEJO_WEB_BASE` split that makes this explicit.

---

## Variables the workflows read as `$env`

The `KG_*` block feeds the n8n workflows. Two things about it are not obvious:

**They must be present on both `n8n` and `n8n-worker`.** In queue mode the
worker executes the nodes, and the executing process is the one that resolves
`{{ $env.X }}`. A value set on only one of them produces a workflow that looks
correct in the editor and resolves to an empty string at run time. The
`x-kg-env` anchor in `stacks/automation/compose.yml` makes that state
unrepresentable; `.env` supplies the values.

**Some of them fail closed on purpose.** `KG_ALLOWED_SENDERS` lists the forge
accounts whose merge may start a phase. Empty means every sender is refused —
an automation that runs for anyone is worse than one that runs for no one.

Full detail in [the automation stack doc](stacks/automation.md).

---

## Local-only services

Services that should run on one machine without entering the repository — a
separate project, or something being trialled — go in a gitignored
`docker-compose.override.yml`. `docker-compose.override.yml.example` is the
template.

This is preferable to a dedicated branch. On a branch, switching away leaves
the container running with nothing declaring it; Docker then treats it as an
orphan of the project and `make up`, which passes `--remove-orphans`, deletes
it. That is not hypothetical: a container here ran for three weeks with its
bind mounts empty and the compose file that defined it gone from disk, so it
could no longer be recreated.

Three things that catch people out:

- Paths inside an included file resolve relative to **that file's** directory,
  not the repository root.
- The `homelab` network is declared once in `docker-compose.yml` and inherited
  through the merge. An included file must not redeclare it.
- **Every user who runs a compose command here must be able to read the
  included file**, and that includes automation accounts. An include pointing
  into a home directory broke the scheduled update checker on this host:
  `/home/<user>` is mode 750, the automation runs as a different account, and
  `docker compose config` failed with `permission denied` — taking the entire
  manifest down rather than one service.

That last one marks the boundary of what an override is for. A project with
its own repository and its own lifecycle belongs in its own compose project,
attaching to this stack's network as `external`. Orphan detection is
per-project, so `--remove-orphans` here has no claim on it, and nothing has to
read across a directory boundary. The override is for the smaller case: a
compose file that belongs to this machine and is simply kept out of the
repository.

Variables the local service needs go in that machine's `.env`. `make check-env`
reports them as extra compared to `.env.example` — expected and correct, since
they are not repository configuration.

> `git clean -x` or `-X` in this repository would delete `.env`,
> `docker-compose.override.yml` and `data/`. `git clean` also reads the
> `.gitignore` **currently checked out**, not the one on `main`, so run it
> after switching branches, not before.

---

## Versions

Image versions are pinned in `.env` and never floated, with three deliberate
exceptions. [updating](updating.md) covers the policy and the checker.
