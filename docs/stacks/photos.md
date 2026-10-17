# Photos stack

`stacks/photos/compose.yml` — Immich, the workshop where media are catalogued
and their lighter versions made. It is never the shop window: no site links to
it, and nothing outside the tailnet reaches it.

| Service | Role |
|---------|------|
| `immich-server` | API and web UI, thumbnails and previews, video conversion, the scheduled jobs |
| `immich-db` | Immich's own PostgreSQL build, with the VectorChord extension the server requires |
| `immich-redis` | Valkey, the job queue |

There is no machine-learning container: see [No machine learning](#no-machine-learning).

---

## Who can reach it

The port is published on `127.0.0.1` only. The way in is `tailscale serve` on
the host, which gives HTTPS with a `*.ts.net` certificate and answers only
inside the tailnet:

```bash
sudo tailscale serve --bg 2283        # 2283 is IMMICH_PORT
tailscale serve status                # → https://<server>.<tailnet>.ts.net (tailnet only) → http://127.0.0.1:2283
```

- The tailnet needs MagicDNS and HTTPS certificates turned on, in the admin
  console (*DNS*). A certificate puts the machine's name in the public
  Certificate Transparency logs; the tailnet's own name is random.
- The phone app and the browser use that one address, at home and away. A
  device without Tailscale reaches nothing, on the LAN either.
- **Never `tailscale funnel`**: that publishes the service on the internet.
- The serve configuration lives in tailscaled's state, not in this
  repository: on a rebuilt server, run the command again.

## Folders

| Host path | In the container | What | Backup |
|-----------|------------------|------|--------|
| `${MEDIA_ROOT}/immich` | `/data` | `upload/` (the phone app), `profile/`, `encoded-video/`, `backups/` (Immich's own database dumps) | `upload/` → `personal`; `profile/` → `work`; the rest is regenerated or local |
| `${DATA_ROOT}/immich/thumbs` | `/data/thumbs` | thumbnails and previews, on the SSD so the timeline is fast | none, regenerated |
| `${DATA_ROOT}/immich/postgres` | — | the database, on the SSD: upstream warns against slower or networked storage | dumped into `work` |
| `${GENOME_MEDIA_ROOT}` | `/libraries/genomes`, read-only | one folder per genome | `work`, without `sorgenti/` |
| `${PHOTO_PERSONAL_ROOT}` | `/libraries/personal`, read-only | one folder per project | `personal` |

One shape for every folder of media:

```
<genome or project>/
  media/      catalogued: what Immich shows, read-only
  sorgenti/   the shoot's RAW: kept and backed up, not catalogued
  inbox/      genomes only: what the client sent, moved into media/ by a person
```

Work never arrives through the phone app: it goes into these folders, and
Immich reads them as external libraries. The originals are never touched;
everything Immich makes from them lives in its own folders.

## Settings: `immich-config.json`

`IMMICH_CONFIG_FILE` points at `stacks/photos/immich-config.json`, mounted
read-only. The file decides, and the web UI can no longer change a setting.

The file is partial on purpose: every key it does not name keeps upstream's
default for the running release. Immich merges it key by key. An **unknown
key** is logged as `Unknown keys found` and ignored; an **invalid value** stops
the server with `Invalid system config`. After every upgrade, read the log for
both.

| Key | Value | Why |
|-----|-------|-----|
| `machineLearning.enabled` and each of its features | `false` | [No machine learning](#no-machine-learning); faces stay off anyway: biometric data, GDPR art. 9 |
| `metadata.faces.import`, `nightlyTasks.clusterNewFaces` | `false` | No faces, not even those written into a file's metadata |
| `map.enabled` | `false` | The map tiles come from an outside server |
| `reverseGeocoding.enabled` | `true` | Place names from coordinates, computed locally |
| `newVersionCheck.enabled` | `false` | Releases are followed by the update checker, not by the app |
| `server.publicUsers` | `false` | The list of users, with their emails, is for the admin only: the work and personal accounts do not see each other |
| `image.extractEmbedded` | `true` | A RAW's preview comes from the JPEG embedded in it: far less CPU, quality as good as the camera made it |
| `image.thumbnail`, `image.preview` | WebP, 250 and 1440 px, quality 80 | The lighter steps for the pages; see [Derivatives](#derivatives-through-the-api) |
| `ffmpeg.accel`, `ffmpeg.transcode` | `disabled`, `required` | Conversion on the CPU, and only for videos a browser cannot play |
| `job.*.concurrency` | 2, video 1 | Leaves the CPU to n8n and the ingests |
| `library.scan`, `library.watch` | every night at 00:00, off | A scan at night, or on demand through the API; no watching the disk |
| `backup.database` | 02:00, keep 7 | Immich's own dumps, local only; the off-site copy is ours ([Backup](#backup-and-restore)) |
| `storageTemplate.enabled` | `false` | Uploads keep Immich's own layout; nothing is renamed |
| `trash` | 30 days | |

The nightly jobs (00:00) and Immich's dump (02:00) stay clear of the update
checker (22:00) and of the backup (02:30, second attempt 04:30).

## No machine learning

The folders are organised by client and project, so search by content is left
out of the base version. Without it, Immich still imports, makes thumbnails
and previews, reads EXIF, and searches by name, date, camera, lens and place,
by album and by folder. What is missing: search by what is in the picture, and
duplicate detection, which uses the same embeddings.

Adding it later: the `immich-machine-learning` service in this file (on the
CPU, the image without a suffix), `machineLearning.enabled` and `clip.enabled`
set to `true`, then the *Smart Search* job run on *Missing* for what is
already there.

## Users

Three accounts:

- **admin**, with no photos of its own: settings, users, libraries, API keys;
- **work**, the owner of every genome's library. A library's owner is fixed
  when it is created and cannot be changed;
- **personal**, the owner of the personal library and of the phone's uploads.

Each account sees only its own assets, the albums shared with it and its
partners'. Whoever administers the server can read every file on disk anyway.

The first sign-up creates the admin, and it needs `IMMICH_ALLOW_SETUP=true`.
Once the admin exists, set it back to `false` and recreate the container:

```bash
docker compose up -d --no-deps immich-server    # after IMMICH_ALLOW_SETUP=false in .env
```

`false` also turns off restoring a database from the web UI
(`/admin/database-backups/start-restore`): a restore goes through the command
line, below.

## Libraries

A library per genome, owned by **work**, and one personal library, owned by
**personal**. Created through the API with an admin key that has the
`library.*` permissions. The key is typed, never written into a file or the
shell history:

```bash
read -rsp "Admin API key: " KEY; echo
api() { curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' "http://127.0.0.1:2283/api$@"; }
api /admin/users | jq -r '.[] | "\(.id) \(.email)"'          # the owners' ids

OWNER=<the work account's id>; GENOME=<genome>
api /libraries -d '{"ownerId":"'"$OWNER"'","name":"genome '"$GENOME"'","importPaths":["/libraries/genomes/'"$GENOME"'/media"]}'
api /libraries/<library id>/scan -X POST                       # or wait for the night

OWNER=<the personal account's id>
api /libraries -d '{"ownerId":"'"$OWNER"'","name":"personal","importPaths":["/libraries/personal"],"exclusionPatterns":["**/sorgenti/**"]}'
```

A file deleted from the folder goes to Immich's trash at the next scan.

## Derivatives through the API

What the sites will use, in the light-to-heavy order of the pages:

- `thumbhash`, a field of every asset: a blurred placeholder of a few dozen
  bytes, drawn before anything loads;
- `GET /api/assets/{id}/thumbnail?size=thumbnail`: WebP, 250 px;
- `GET /api/assets/{id}/thumbnail?size=preview`: WebP, 1440 px;
- the original, which stays the file in `media/`.

A key with only `asset.read` and `asset.view` reads them, and lists a
library's assets with `POST /api/search/metadata` and `{"libraryId": "…"}`.
Immich makes these sizes and no others: anything else a site needs is built
from the original at publication, not asked of Immich. Artists' works are
never converted.

## Backup and restore

- **The database** is in `backup/postgres.list`: `pg_dump -Fc` right before
  every backup, in the `work` set, and the restore drill lists it with
  `pg_restore -l`. Immich's own dumps stay local, in `/data/backups`.
- **`work`** also holds `profile/` and `${GENOME_MEDIA_ROOT}`, without the
  genomes' `sorgenti/`: where their RAW go off-site is decided before the
  first client.
- **`personal`** holds `${PHOTO_PERSONAL_ROOT}` whole, RAW included, and
  `upload/`. Its restore drill restores a random sample once the set passes
  `BACKUP_RESTORE_WHOLE_MAX_MB` ([backup](../backup.md#backup-sets)).
- **Not backed up:** thumbnails, previews and converted videos, which Immich
  makes again.

Restoring the database on an empty server, from the latest dump:

```bash
docker compose up -d immich-db                 # an empty database, same version as the dump
docker compose exec -T immich-db pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner < immich-db.dump
docker compose up -d immich-server             # then the libraries' scan, and the missing thumbnails
```

`$DB_USER` and `$DB_NAME` are the values of `IMMICH_DB_USER` and
`IMMICH_DB_NAME`, set by hand: `.env` is never sourced.

## Updating

`immich-server` and `immich-db` follow upstream's `docker-compose.yml` for the
same release: read it at every upgrade. The database image changes rarely, and
only with upstream's notes. The update checker tracks the server and stays on
the current major. Take the latest patch that has gone a week without a fix,
and afterwards read the log for `Unknown keys found` and `Invalid system config`.

## Memory

| Service | Limit |
|---------|-------|
| `immich-server` | 2560 MiB |
| `immich-db` | 2 GiB |
| `immich-redis` | 256 MiB |

Without machine learning, about 5 GiB at most, against 12 GiB available with
everything else running and a model loaded in Ollama.
