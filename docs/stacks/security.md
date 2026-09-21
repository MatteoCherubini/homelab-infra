# Security stack

`stacks/security/compose.yml` — Vaultwarden, a Bitwarden-compatible password
server.

| Service | Role |
|---------|------|
| `vaultwarden` | Vault, web vault UI, WebAuthn, SMTP for invitations |

---

## Domain, and why it is not editable later

`DOMAIN` comes from `VAULTWARDEN_DOMAIN` in `.env`. It is required for HTTPS
and WebAuthn to work at all.

**WebAuthn binds passkeys to this exact value.** Changing it invalidates every
security key already registered — so it is not a setting to adjust casually
after the vault is in use. Decide it before the first registration.

## The admin panel is off, on purpose

`ADMIN_TOKEN` is set to `${VAULTWARDEN_ADMIN_TOKEN:-}`, and the variable is
left commented out in `.env.example`. With no token Vaultwarden disables the
admin panel: `/admin` serves a page saying so, and `/admin/users`,
`/admin/config` and `/admin/diagnostics` return 404.

The empty default is written explicitly rather than left implicit. Without the
`:-`, Compose emits a warning on every single command about a variable that was
deliberately not set, and `make check-env` fails on a `.env.example` entry the
real `.env` correctly does not have. A check that is always red stops being
read.

To enable it temporarily: set the variable to an **Argon2 hash** produced by
`vaultwarden hash` — never plaintext, which Vaultwarden itself warns about in
its logs — recreate the container, and comment it out again afterwards.

## Registration and invitations

`SIGNUPS_ALLOWED=false` keeps it closed; `INVITATIONS_ALLOWED=true` lets an
existing user invite others. SMTP is configured so those invitations can
actually be delivered.

> The SMTP password is one of the reasons `.env` must never be `source`d by a
> shell script: provider app passwords contain spaces, and an unquoted value
> with spaces makes the shell try to execute its second word as a command. See
> [configuration](../configuration.md).

## Brute-force protection

Login attempts are rate limited at 5 per 300 seconds, admin attempts at 3 per
300 seconds. These are set in the compose file rather than left at defaults
because this service is reachable from outside.

## Storage and upgrading

The SQLite database and attachments live in `${DATA_ROOT}/vaultwarden/data`,
which is root-owned. Reading it without `sudo` means going through a container
running as root.

Vaultwarden applies schema migrations on startup, so snapshot first. To inspect
the database while the service is running, open it in immutable mode — a plain
read-only mount still makes SQLite block on the lock:

```bash
sqlite3 "file:/data/db.sqlite3?immutable=1" "pragma integrity_check"
sqlite3 "file:/data/db.sqlite3?immutable=1" "select count(*) from users"
```

Comparing `integrity_check` plus the row counts before and after an upgrade is
what tells you a migration did not lose anything.

Client compatibility is a real upgrade driver here, not just security: release
1.37.2 was required for clients from version 2026.8.0 onwards. Falling behind
on this service breaks phones, not just patches.
