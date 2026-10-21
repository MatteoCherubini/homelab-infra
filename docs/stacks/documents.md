# Documents stack

`stacks/documents/compose.yml` — Paperless-ngx, where the papers live:
contracts, policies, statements, invoices received, letters. It holds the
documents and what they say; the numbers and their states belong to the
bookkeeping, not here.

| Service | Role |
|---------|------|
| `paperless` | Web UI and API, OCR, the classifier, the scheduled jobs, the exporter |
| `paperless-db` | PostgreSQL, the same image as n8n's |
| `paperless-redis` | Valkey, the task queue, the same image as Immich's |

No Tika and no Gotenberg: documents arrive as PDF or images, never as Office
files or whole emails. No AI on this host — see [AI, later](#ai-later).

**Not a legal archive.** For electronic invoices the tax authority's own
conservation service stays the copy of record; Paperless keeps the working
copy, the one that is searched and read.

---

## Who can reach it

The port is published on `127.0.0.1` only. The way in is `tailscale serve` on
the host, on an HTTPS port of its own beside Immich's:

```bash
sudo tailscale serve --bg --https=8443 8010   # 8010 is PAPERLESS_PORT
tailscale serve status                        # → https://<server>.<tailnet>.ts.net:8443 (tailnet only) → http://127.0.0.1:8010
```

- `PAPERLESS_URL` in `.env` is that address, port included: it sets the
  allowed hosts, CSRF and CORS together. Any other host gets `400`, except
  `localhost`, which the health check uses.
- **No share links to the outside, no `tailscale funnel`.**
- Documents come in by hand for now: uploaded in the web UI, from a phone's
  browser too, or copied into `${MEDIA_ROOT}/paperless/consume`. A dedicated
  mailbox comes later, once it is chosen.

## Folders

| Host path | In the container | What | Backup |
|-----------|------------------|------|--------|
| `${DATA_ROOT}/paperless/postgres` | — | the database, on the SSD | dumped into `work` |
| `${DATA_ROOT}/paperless/data` | `/usr/src/paperless/data` | the search index and the classifier, on the SSD | none, rebuilt |
| `${MEDIA_ROOT}/paperless/media` | `/usr/src/paperless/media` | the originals, archive copies and thumbnails | through the export |
| `${MEDIA_ROOT}/paperless/consume` | `/usr/src/paperless/consume` | a file put here is imported, then removed | none, it is a doorway |
| `${MEDIA_ROOT}/archive/paperless` | `/usr/src/paperless/export` | the export: originals under readable names, and the manifest | `archive`, ten years |

On a new server the folders are created once, owned by the user in `PUID`, as
`archive/` is ([backup](../backup.md#first-time-setup)).

## Settings

Everything is in the compose file and `.env`; nothing is clicked into the web
UI that a rebuild would lose.

| Setting | Value | Why |
|---------|-------|-----|
| `PAPERLESS_OCR_LANGUAGE` | `ita+eng` | Both are in the image. Dates and the search stemmer follow it |
| `PAPERLESS_TASK_WORKERS`, `PAPERLESS_THREADS_PER_WORKER` | 1, 2 | One document at a time, two pages in parallel: the CPU stays with Immich, n8n and the ingests |
| `PAPERLESS_WEBSERVER_WORKERS` | 1 | Each worker loads the whole application; one is plenty for a few users |
| `PAPERLESS_FILENAME_FORMAT` | `{{ created_year }}/{{ document_type }}/{{ correspondent }}/{{ title }}` | The cure for `scan_0231.pdf`: on disk, in the export and in the backup, a name anyone can read without Paperless. `_REMOVE_NONE` drops an empty part rather than writing `none` |
| `PAPERLESS_ARCHIVE_FILE_GENERATION` | `auto`, the default | No PDF/A for a PDF that already has its text — payslips, statements, invoices |
| `PAPERLESS_AI_ENABLED` | `false` | [AI, later](#ai-later) |
| `USERMAP_UID`, `USERMAP_GID` | `PUID`, `PGID` | The files on the host belong to the same user as everything else |

Sign-ups are off by default and stay off: accounts are made by the admin.

## Users

- **admin**, a superuser, for settings, users and the vocabulary. The first
  visit to the web UI asks for it.
- **one account per person** for daily work, not a superuser: a superuser
  sees every document, whatever its permissions.

Work and personal are separated by **owner and permissions**, never by tags: a
tag comes off with a click, a permission protects. Personal documents are
owned by their person and shared with no one. Collaborators, when they come,
join a `work` group, and only work documents are shared with it.

**A document with no owner is visible to every user.** Paperless keeps that
rule for compatibility, and a file uploaded in the web UI belongs to whoever
uploads it — but one that comes in through the consumption folder has no owner.
Found on 2026-10-20, when a test account saw exactly the one document that had
come in that way. A workflow closes it: trigger *Consumption Started*, source
*Consume folder*, action *Assignment*, owner the account that files the
documents. Mail, when it comes, sets its owner in each mail rule. The workflow
lives in the database, so the dump and the export carry it; the vocabulary
script creates it on a new server.

## Vocabulary

A closed vocabulary, written before any automation: every document gets one
type and one correspondent from lists a person keeps, and tags are only
states.

| Field | Says | Examples |
|-------|------|----------|
| Document type | what it is | Contract, Policy, KID, Statement, Payslip, Invoice received, Letter |
| Correspondent | who it comes from or goes to | a bank, an insurer, the accountant, the tax office |
| Tags | what is to be done with it | to read, to pay, paid |
| Custom fields | the numbers | Amount, Due date |

The vocabulary is configuration: a script will create it through the API, so a
new server gets the same one. Until then it is typed in the web UI, and the
script takes over what exists without duplicating it.

**A type's or a correspondent's name becomes a folder name** — on the array,
in the export, and on any disk the export is copied to. So no character
Windows refuses (`< > : " / \ | ? *`) and no trailing dot, which Windows drops:
`Acme Srl`, not `Acme S.r.l.`. Paperless itself turns a `|` into `-`, silently.
Renaming one moves its documents' files, a little later.

## Backup and restore

Two copies, for two different losses:

- **The database**, in `backup/postgres.list`: `pg_dump -Fc` right before every
  backup, in the `work` set. With the media folder still on the array, it
  brings Paperless back exactly as it was — the fast path when the SSD dies.
- **The export**, right before every backup too: `document_exporter` writes
  into `${MEDIA_ROOT}/archive/paperless`, which the `archive` set keeps ten
  years. Every document's original under its readable name, plus a manifest
  that any later Paperless imports. The path when the array dies, and the way
  out of Paperless altogether.

The export runs with `--delete --use-filename-format --use-folder-prefix
--no-archive --no-thumbnail`: incremental, the originals under
`originals/`, without the copies Paperless makes again. Without a passphrase,
the few secrets Paperless keeps (a mailbox's password, once there is one) are
in the manifest in plain text — inside the archive repository, which is
encrypted.

`make backup-restore-test` restores the archive whole and checks the export as
an import needs it: the manifest opens, and every document it lists has its
original.

**From the export**, into a completely empty Paperless — database and folders —
of the same version as the export: upstream says an older export may work,
and matching versions is what it recommends:

```bash
# the export restored into ${MEDIA_ROOT}/archive/paperless, then:
docker compose up -d paperless
docker compose exec -T paperless document_importer /usr/src/paperless/export
```

**From the database**, when only the SSD was lost:

```bash
docker compose up -d paperless-db               # an empty database, the same version as the dump
docker compose exec -T paperless-db pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner < paperless-db.dump
docker compose up -d paperless
docker compose exec -T paperless document_index reindex
docker compose exec -T paperless document_create_classifier
```

`$DB_USER` and `$DB_NAME` are the values of `PAPERLESS_DB_USER` and
`PAPERLESS_DB_NAME`, set by hand: `.env` is never sourced.

## Tested

On 2026-10-19 and 20, with 3.3.2:

- **Reach:** the tailnet address answered 200; port 8010 was refused on the LAN
  and on the Tailscale address.
- **OCR and names:** a phone photo of a printed Italian page was found by a word
  that was only in the photo. On disk the files followed the format,
  `2026/Prova/Prova/<title>.jpg`; a document with no type and no correspondent
  went to `2026/<title>.pdf`, with no `none/` in its path.
- **Users:** a second account with the same permissions saw none of the other
  account's documents, and a direct link answered 404 — except one document,
  which had come in through the consumption folder with no owner. Hence the
  workflow in [Users](#users); with it, every document has an owner.
- **Export and import:** the export, imported into an empty Paperless (SQLite,
  a Valkey of its own, a copy of the export), gave back the same 4 documents
  with the same checksums, the originals under the same paths. A throwaway
  Paperless needs a `PAPERLESS_SECRET_KEY` of its own: 3.x refuses to start
  without one. Its SQLite database is in WAL mode, so it opens only from a
  writable folder.
- **Backup:** the first night dumped `paperless-db` and exported;
  `make backup-restore-test` opened the dump and the export's manifest. That
  export held no documents yet, as they were added the morning after.
- **Failures:** Paperless stopped: its two lines red, the other 47 green. Its
  database stopped: three lines red, Paperless's page answering 500; when the
  database came back, Paperless reconnected by itself.
- **Memory:** at rest, 459 MiB of the processes' own memory (`anon` in the
  container's `memory.stat`), 625 MiB counting cache. During the OCR of a
  six-page PDF made of photos, 596 MiB at most. The container's counter touched
  the 2 GiB limit only at the first start, compiling Python and building the
  index — page cache the kernel gave back — and nothing was ever killed
  (`oom_kill 0`).

## AI, later

Not in this version. When it comes, after some weeks of real documents have
trained the classifier:

- the model runs on the AI node, at night, never on this host;
- a new document gets a tag for the AI and is classified at once without it,
  so nothing waits for a sleeping machine;
- *create missing elements* stays off: the AI picks from the vocabulary and
  never adds to it.

## Updating

Paperless runs its database migrations at start: read the release notes
first, and take the latest patch that has gone a week without a fix.
`paperless-db` follows n8n's PostgreSQL: a new major version means a dump and a
restore, never a new tag on the old data.

**Two pairs share an image:** `paperless-db` with `n8n-db`, `paperless-redis`
with `immich-redis`. A pull for one moves the tag for both, and the other keeps
running the old image, now nameless: `make verify` shows it as a bare
`sha256:` and a mismatch. Recreate the other one afterwards — `docker compose
up -d n8n-db` — or pull and start everything with `make up`. Within a major
version the data needs nothing. Seen on 2026-10-19, at Paperless's first pull.

## Memory

| Service | Limit |
|---------|-------|
| `paperless` | 2 GiB |
| `paperless-db` | 512 MiB |
| `paperless-redis` | 128 MiB |

Ceilings, not reservations. Measured in [Tested](#tested): the OCR of six
pages stays under 600 MiB of the processes' own memory, so 2 GiB leaves room
for a long scan and for the page cache.
