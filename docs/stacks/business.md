# Business stack

`stacks/business/compose.yml` — Grist, where the numbers and their states
live: tables of contracts, policies, payslips, investments, deadlines, and
later the bookkeeping. The papers themselves stay in
[Paperless](documents.md); a row here points to its document there.

| Service | Role |
|---------|------|
| `grist` | Web UI and API, the Python formulas in a gVisor sandbox, the home database |

One container. The users, the sites and the list of documents are one SQLite
file, and each document is another: a single server needs neither Postgres
nor Redis. The image is `grist-oss`, only the free code — the Community
edition, with no update check and no telemetry.

**Not the books of record.** Invoices go through the tax authority's own
service; Grist keeps the working numbers, the ones that are read and summed.

---

## Who can reach it

The port is published on `127.0.0.1` only. The way in is `tailscale serve` on
the host, on the next HTTPS port beside Paperless's:

```bash
sudo tailscale serve --bg --https=10000 8484   # 8484 is GRIST_PORT
tailscale serve status                         # → https://<server>.<tailnet>.ts.net:10000 (tailnet only) → http://127.0.0.1:8484
```

`GRIST_URL` in `.env` is that address, port included. No public form until
[Access](#later) arrives, and **no `tailscale funnel` on any machine of the
tailnet, ever** — [why](#what-the-devices-identity-means); `make healthcheck`
checks it.

### Who you are: a header Grist believes

There is no password in Grist. On every request `tailscale serve` writes
`Tailscale-User-Login` — the tailnet account of the device asking — and Grist
takes it as the user (`GRIST_FORWARD_AUTH_HEADER`, with `GRIST_IGNORE_SESSION`:
on every request, never from a cookie). `tailscale serve` removes that header
from what the client sends and writes it itself; a tagged device gets none,
and with `GRIST_FORCE_LOGIN` nobody without one gets in.

Grist trusts whatever the header says, so **nothing may reach the port except
`tailscale serve`**:

- the port is on `127.0.0.1`, never on the LAN;
- Grist sits on a Docker network of its own, `business`, that no other
  container joins: on the shared network any container could send the header
  itself. n8n joins it on purpose when a flow needs Grist's API, and uses an
  API key, which Grist checks before the header;
- on the host itself, anything that can reach `127.0.0.1:8484` can claim any
  user. On this server that is root and the `docker` group, who can read the
  files anyway.

*Sign out* in the menu leads back to the home page, still signed in: the
identity is the device's, not a session's.

### What the device's identity means

- **Anything running on one of your devices is you in Grist**: the browser,
  a script, an extension, the phone. There is no password to type, so there
  is none to steal either; the device is the key.
- **A page from the internet cannot act for you.** The header reaches every
  request from your browser, a cross-site one too — so Grist accepts a change
  sent this way only with `Content-Type: application/json` or
  `X-Requested-With`, which a foreign page can send only after asking the
  browser's permission (CORS), and Grist grants that, and opens its
  websockets, only to pages of its own domain.
- **Its own domain is the whole tailnet**: `*.<tailnet>.ts.net`, any port —
  Immich and Paperless included. A flaw in one of them could reach Grist,
  and **no machine of this tailnet may ever run `tailscale funnel`**: a public
  page there would be a page Grist trusts.

### Logins that are not emails

On a tailnet signed in with GitHub the login is `<user>@github`, not an email
address. Grist takes it as it is for signing in and for the admin
(`GRIST_ADMIN_LOGIN` in `.env`, read with `tailscale status --json | jq -r
'.User[].LoginName'`). What does **not** work is sharing a document or a site
with such a login: Grist checks the email format there, and answers *Invalid
email address included*. A collaborator comes with Access and a real address
— see [Later](#later).

Renaming the account on the tailnet changes the login: Grist sees a new user,
and the documents stay with the old one.

## Sites

- **Each user gets a personal site** at the first visit
  (`GRIST_PERSONAL_ORGS`). The personal sheets — contracts, policies,
  payslips, investments — live there, and are shared with no one. That is a
  rule kept by people, as in Paperless, not a limit of the plan.
- **Grist keeps four users of its own** — anonymous, preview, everyone,
  support — and the support user has a personal site too. They are not
  people, and they sign in nowhere.
- **Team sites are made by the admin only** (`GRIST_ORG_CREATION_ANYONE`):
  the work goes in one, made when the first work document comes, and it is
  the one collaborators will join.

## Folders

| Host path | In the container | What | Backup |
|-----------|------------------|------|--------|
| `${DATA_ROOT}/grist/home.sqlite3` | `/persist/home.sqlite3` | users, sites, workspaces, the list of documents, API keys | copied into `work` |
| `${DATA_ROOT}/grist/docs/<id>.grist` | `/persist/docs` | one SQLite file per document, named by the document's id | copied into `work` |
| `${DATA_ROOT}/grist/grist-sessions.db` | `/persist/grist-sessions.db` | the sessions, which carry no identity here | none |

On the SSD: they are databases. Grist runs as `PUID:PGID`, so the files belong
to the same user as everything else. Started as root — the image's default —
it would hand `/persist` to its own `grist` user, 1001, and on this server
1001 is the account n8n runs commands as: seen on 2026-10-21, with 0.9.0. The
folder must exist and belong to that user before the first start: `make
init` creates it. gVisor runs unprivileged either way.

From 0.9.0, once, with Grist stopped:

```bash
docker run --rm -v "$GRIST_DIR:/p" alpine chown -R "$PUID:$PGID" /p
```

The variables are set by hand, as in [Backup and restore](#backup-and-restore).

## Settings

Everything is in the compose file and `.env`.

| Setting | Value | Why |
|---------|-------|-----|
| `GRIST_IN_SERVICE` | `true` | No *Quick setup* page and no boot key in the log: what it would ask is set here |
| `GRIST_FORWARD_AUTH_HEADER`, `GRIST_IGNORE_SESSION`, `GRIST_FORCE_LOGIN` | `Tailscale-User-Login`, `true`, `true` | [Who you are](#who-you-are-a-header-grist-believes) |
| `GRIST_ADMIN_EMAIL` | `GRIST_ADMIN_LOGIN` | The admin panel, `/admin`. Not `GRIST_DEFAULT_EMAIL`: that one also signs in as itself whoever comes with no identity, should the header ever be switched off |
| `GRIST_ORG_CREATION_ANYONE`, `GRIST_PERSONAL_ORGS` | `false`, `true` | [Sites](#sites). The first alone would also switch personal sites off, and the admin would arrive at an empty Grist |
| `GRIST_DEFAULT_PRODUCT` | `Free` | The plan with no limits, for every new site. Without it a personal site gets the hosted service's free plan — 5,000 rows a document, and after a grace period a document past it can only be deleted from — and a team site a stub that waits for a subscription. **A site keeps the plan it was created with:** this is set before the first sign-in |
| `GRIST_SANDBOX_FLAVOR` | `gvisor` | [The sandbox](#the-sandbox) |
| `GRIST_SESSION_SECRET` | from `.env` | Sessions carry no identity here; set so that the built-in default is never used |
| `GRIST_TELEMETRY_LEVEL`, `GRIST_ALLOW_AUTOMATIC_VERSION_CHECKING` | `off`, `false` | Already the defaults of `grist-oss`; written down so that nothing depends on the image. Releases are followed by `make check-updates` |

## The sandbox

A formula in Grist is Python, written by whoever edits the document — or by
whoever made a document imported from elsewhere. It runs in gVisor, which is
in the image. If gVisor cannot start, Grist does not start either: the log
says *gvisor check failed*, and the container restarts in a loop rather than
running formulas unsandboxed.

The check that it holds: in any document, a formula column with
`glob.glob('/etc/*')` returns an empty list. The admin panel, `/admin`, shows
the sandbox among its checks.

## Paperless and Grist

The two speak through n8n, not to each other, and only from the next phase:

- **one vocabulary:** Paperless's custom fields carry the names of Grist's
  columns, plus a field with the link to the row;
- a Paperless workflow calls an n8n webhook when a document of a chosen type
  arrives; n8n reads the fields and creates a **draft** row in Grist, with the
  link to the document. A person confirms it;
- a form in Grist writes rows; a row becomes a document from a template,
  signed, and goes into Paperless with the link back.

The schema of the tables comes from the documents already in Paperless.

## Backup and restore

Two lines in `backup/sqlite.list`, copied online with `sqlite3 .backup` before
every backup, into the `work` set:

```
grist-home   ${DATA_ROOT}/grist/home.sqlite3
grist-doc    ${DATA_ROOT}/grist/docs/*.grist
```

The second copies every document to `grist-doc-<id>.sqlite3`, and removes the
copy of a document that is no longer there — deleted in Grist and emptied
from its trash. `make backup-restore-test` checks every copy with `pragma
integrity_check`.

**A document's id is its file name**: Grist finds a document only under the
name `home.sqlite3` lists for it. To bring everything back, with Grist
stopped, both from the same night:

```bash
docker compose stop grist
# the copies restored from the work set into /tmp/restore (docs/backup.md), then:
docker run --rm -v "$GRIST_DIR:/persist" -v /tmp/restore:/r alpine sh -c '
  rm -f /persist/home.sqlite3-wal /persist/home.sqlite3-shm /persist/home.sqlite3-journal
  cp /r/grist-home.sqlite3 /persist/home.sqlite3
  for f in /r/grist-doc-*.sqlite3; do
    id=${f#/r/grist-doc-}; cp "$f" "/persist/docs/${id%.sqlite3}.grist"
  done
  chown -R "$1" /persist' sh "$PUID:$PGID"
docker compose up -d grist
```

`$GRIST_DIR` is `${DATA_ROOT}/grist`, `$PUID` and `$PGID` the values in
`.env`, all set by hand: `.env` is never sourced. The `chown` matters: copied
as root, the files would be Grist's to read and not to write.

**One document only**, without touching the others: rename its copy to
`<anything>.grist` and import it in the web UI (*Add New → Import document*).
It becomes a new document with a new id; the old one, if it is still there, is
untouched. The same file opens in Grist Desktop, with no server at all.

## Updating

Grist migrates `home.sqlite3` at start, and each document when it is first
opened. Read the release notes first, and take the latest patch that has gone
a week without a fix. The image's tags have no `v`: `1.7.21`.

## Memory

| Service | Limit |
|---------|-------|
| `grist` | 1 GiB |

A ceiling, not a reservation: Node, plus one Python sandbox per open document,
closed half a minute after its last client leaves.

## Tested

On 2026-10-21 and 22, with 1.7.21:

- **Identity:** the tailnet login came in with no password and was the
  installation admin; every site was on the `Free` plan. A forged
  `Tailscale-User-Login` sent from another machine changed nothing:
  `tailscale serve` throws it away and writes its own.
- **Reach:** port 8484 answered only on `127.0.0.1`. A container on the shared
  network reached Grist neither by name, nor by address, nor through the host.
- **Sandbox:** `gvisor check ok` in the log; a formula listing `/etc` gave
  `[]`, `/persist` was empty, and there was no network. Run as `PUID:PGID`,
  the files belong to the host's user and gVisor starts all the same.
- **Failure:** Grist stopped, only its two lines of the health check red.
- **Memory:** 282 MiB with a document open.
- **Backup and restore:** the first night copied `home.sqlite3` and both
  documents (`grist-doc-* (2 files)`), and `make backup-restore-test` brought
  them back from off-site with `integrity_check` passing. The same night's
  copies, put back as in [Backup and restore](#backup-and-restore) into a
  throwaway Grist — the same image and settings, a temporary folder, another
  port on `127.0.0.1`, the identity header sent with curl from the host —
  opened with every table, as many rows as the live documents, and no formula
  in error.

## Later

- **Cloudflare Access**, with the first person who has no Tailscale, or with
  the first public form: the header becomes
  `Cf-Access-Authenticated-User-Email`, the tunnel gets a route, and logins
  are real email addresses, so sharing works.
- **The work site and its schema**, from a private repository, created through
  the API so that a new server gets the same.
