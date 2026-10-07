# Backup

`scripts/backup.sh` — consistent copies of every database, then
[restic](https://restic.net/) to an off-site, S3-compatible repository. A
workflow runs it every night and reports through ntfy.

| Piece | Role |
|-------|------|
| `scripts/backup.sh` | Dumps, restic, a JSON report; also init, snapshots, restore drill, maintenance |
| `backup/<set>.paths`, `backup/<set>.exclude` | What each backup set contains |
| `backup/postgres.list`, `backup/sqlite.list` | Databases copied consistently before every run |
| `workflows/homelab-backup.json` | The nightly schedule and the notification |
| `make healthcheck` | Fails when the last successful run is older than `BACKUP_MAX_AGE_HOURS` |

---

## Why it is shaped like this

**Before 0.6.0 nothing left the machine.** RAID1 survives a disk, not a
deletion, ransomware, a fire or a theft, and `${DATA_ROOT}` — the vault, the
n8n database, the certificates — sits on a single SSD.

**Encrypted before it leaves.** restic encrypts on this host; the provider
only ever stores ciphertext. The repository password lives in `.env` and on a
paper recovery sheet, never with the provider.

**Append-only in practice.** The key used every night can write and read but
cannot delete, except restic's own lock files. A compromised server can add
snapshots; it cannot destroy history. Retention needs a second key that never
touches the disk: `make backup-maintenance` asks for it.

**A database file in use is not a backup.** The live files are excluded and
replaced by consistent copies: Postgres through `pg_dump -Fc`, SQLite through
`sqlite3 .backup`, which takes the proper locks while the service keeps
running. Each copy is integrity-checked before it replaces the previous one.

**No sudo.** Everything root-owned is read inside a throwaway container, so the
same command works for the interactive user and for `n8n-runner`.

**Data, not code.** What goes off-site is a list of paths and databases under
`backup/`. Adding a service's data is one line, not a script change.

**Compartments.** Each backup set has its own repository and its own password.
Losing or leaking one set's password exposes that set only.

## Backup sets

| Set | `.env` keys | Holds |
|-----|-------------|-------|
| `work` | `BACKUP_WORK_REPOSITORY`, `BACKUP_WORK_PASSWORD` | Database copies, Forgejo, the genome vaults, Vaultwarden, NPM and certificates, ntfy, n8n's files, Homepage, Syncthing, `.env` |

A set is a file: `backup/<set>.paths` (and optionally `<set>.exclude`). The
credentials are `BACKUP_<SET>_REPOSITORY` and `BACKUP_<SET>_PASSWORD`, with
`-` written as `_`. `make backup` picks up every set it finds.

**Not backed up, on purpose:** Ollama's models (downloadable again), the Redis
queue, restic's cache, n8n's execution binary data, Vaultwarden's icon cache,
container images.

## Off-site storage

Any S3-compatible store works. This setup uses Hetzner Object Storage: an EU
provider, a base price that includes about 1 TB, free API calls. One bucket,
one prefix per set:

```
BACKUP_WORK_REPOSITORY=s3:https://fsn1.your-objectstorage.com/<bucket>/work
```

### Two keys

| Key | Where it lives | Can |
|-----|----------------|-----|
| Nightly | `.env` (`BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY`) | Read, write and list; delete only `*/locks/*` |
| Admin | Vaultwarden and the recovery sheet only | Everything, including deleting and pruning |

Keys in a Hetzner project can reach every bucket of that project by default,
so the nightly key is restricted with **deny** statements. Turn on bucket
**versioning** as well: then even an object overwritten with garbage keeps its
previous version, and the nightly key is denied deleting versions.

Starting point for the bucket policy, applied with the admin key. The test in
[first-time setup](#first-time-setup) is what proves it works on the provider.
Do not trust the policy until that test has passed.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NightlyKeyCannotDeleteHistory",
      "Effect": "Deny",
      "Principal": {"AWS": ["arn:aws:iam:::user/p<project-id>:<nightly-access-key>"]},
      "Action": ["s3:DeleteObject", "s3:DeleteObjectVersion"],
      "NotResource": ["arn:aws:s3:::<bucket>/*/locks/*"]
    },
    {
      "Sid": "NightlyKeyCannotChangeTheBucket",
      "Effect": "Deny",
      "Principal": {"AWS": ["arn:aws:iam:::user/p<project-id>:<nightly-access-key>"]},
      "Action": ["s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning",
                 "s3:PutLifecycleConfiguration", "s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::<bucket>"]
    }
  ]
}
```

## First-time setup

Once, in this order. Every step states what it should print.

1. **Provider:** create a private bucket, enable versioning, create two S3
   credentials (nightly and admin). Put the admin key in Vaultwarden.
2. **Policy:** apply the policy above with the admin key, for example:

   ```bash
   docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -v "$PWD/policy.json:/p.json:ro" \
     amazon/aws-cli s3api put-bucket-policy --endpoint-url https://fsn1.your-objectstorage.com \
     --bucket <bucket> --policy file:///p.json
   ```

3. **`.env`:** set `BACKUP_WORK_REPOSITORY`, the nightly key and
   `BACKUP_WORK_PASSWORD` (`openssl rand -hex 32`). `make check-env` → aligned.
4. **Recovery sheet** (below), written by hand before going on.
5. `make backup-init` → `created restic repository … at s3:…`.
6. `make backup` → a JSON report with `"status": "ok"` and a snapshot id.
7. `make backup-restore-test` → `ok:` per dump, then `restore test passed`.
8. **Prove append-only** on a canary object, never on real data. With the
   **nightly** key exported:

   ```bash
   aws() { docker run --rm -i -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY amazon/aws-cli \
             --endpoint-url https://fsn1.your-objectstorage.com "$@"; }
   echo canary | aws s3 cp - s3://<bucket>/work/canary.txt   # allowed: upload
   aws s3 rm s3://<bucket>/work/canary.txt                   # expected: AccessDenied
   ```

   Then remove the canary with the admin key. If the nightly key could delete
   it, the policy is not doing its job: fix it before relying on the backup.
   (A maintenance run with the nightly key is *not* a test: with few snapshots
   there may be nothing to delete, and it would pass for the wrong reason.)
9. **n8n:** import `workflows/homelab-backup.json`, check that the SSH and ntfy
   credentials resolve, run it once by hand (an ntfy message titled
   `Homelab - Backup OK`), then activate it.
10. `make healthcheck` → `last off-site backup  0 h ago`.

## Every night

The workflow runs at 02:30: `ssh n8n-runner@server 'cd /opt/homelab-infra &&
make backup'`, the same path the release checker uses. A successful run is
announced at minimum priority, a failed or unreadable one as urgent. A night
that never ran at all is caught by `make healthcheck`, which reads the stamp
the script writes after a fully successful run.

The JSON report on stdout is the contract with the workflow:

```json
{"run_at": "…", "status": "ok|error", "host": "server",
 "sets": [{"name": "work", "status": "ok", "snapshot": "…", "data_added": 0, "duration_s": 0}],
 "dumps": ["n8n-db.dump", "vaultwarden.sqlite3"], "errors": []}
```

A failed dump does not stop the run: the previous copy and every other path
still go off-site, and the run is reported as an error.

## Restore

**The drill:** `make backup-restore-test` brings the latest database copies
back from off-site into a scratch directory, opens every Postgres dump with
`pg_restore -l` and every SQLite copy with `pragma integrity_check`, then
deletes the scratch directory. Run it at least every quarter.

**One path**, into a scratch directory. The values are typed or pasted, not
read from `.env` by the shell:

```bash
export RESTIC_REPOSITORY=… RESTIC_PASSWORD=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v /tmp/restore:/restore restic/restic:0.19.1 \
  restore latest --target /restore --include /opt/homelab-infra/data/vaultwarden/data
```

Paths inside a snapshot are the real host paths, so the restored tree mirrors
the server's layout under the target.

**The whole server:** install Docker, clone this repository to
`/opt/homelab-infra`, restore `.env` and the data with the command above using
the recovery sheet, put each tree back in place, restore the databases from
their copies, `make up`, `make healthcheck`.

## Maintenance — the quarterly session

`make backup-maintenance` asks for the admin key, applies the retention in
`.env` (`BACKUP_KEEP_*`: 7 daily, 5 weekly, 12 monthly, 10 yearly — invoices
must be kept ten years), prunes, and reads back 10% of the data with
`restic check`. In the same session:

- run `make backup-restore-test`;
- check restic's and Alpine's releases: they run through `docker run`, not
  Compose, so the release checker does not see them;
- confirm the recovery sheet still matches `.env`.

## The recovery sheet

Vaultwarden is itself backed up by this repository, so its contents cannot be
the only place where the way back is written. Keep on paper, somewhere other
than next to the server, and in the offline copy of Bitwarden on a phone and a
laptop:

- each `BACKUP_<SET>_REPOSITORY` URL and `BACKUP_<SET>_PASSWORD`;
- the admin key id and secret;
- the provider account and how to log in to it;
- this file's path in the repository.
