# Backup

`scripts/backup.sh` — consistent copies of every database, then
[restic](https://restic.net/) to an off-site, S3-compatible repository. A
workflow runs it every night and reports through ntfy.

| Piece | Role |
|-------|------|
| `scripts/backup.sh` | Dumps, restic, a JSON report; also init, snapshots, restore drill, maintenance, a client's exit |
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
cannot delete, except restic's own lock files. A compromised server cannot
destroy history itself. It could only add snapshots with false dates, so that
the next cleanup keeps those and drops the real ones — a known limit of
append-only restic ([#22057](https://github.com/restic/restic/issues/22057)):
the attacker deletes nothing, the cleanup does. So the cleanup needs a second
key that never touches the disk, shows what it would remove, and removes it
only once a person has looked; and whatever it removes stays in the bucket
for 30 more days as an old version.

**A database file in use is not a backup.** The live files are excluded and
replaced by consistent copies: Postgres through `pg_dump -Fc`, SQLite through
`sqlite3 .backup`, which takes the proper locks while the service keeps
running. Each copy is integrity-checked before it replaces the previous one,
and runs as the owner of the database file: it never leaves a root-owned file
behind in a service's data.

**No sudo.** Everything root-owned is read inside a throwaway container — even
the check that a listed path exists — so the same command sees the same files
as the interactive user and as `n8n-runner`.

**Data, not code.** What goes off-site is a list of paths and databases under
`backup/`. Adding a service's data is one line, not a script change.

**Compartments.** Each backup set has its own repository and its own password.
Losing or leaking one set's password exposes that set only.

**Each set lives as long as its contents must.** The documents the law asks to
keep for ten years and the data a client may ask to have deleted cannot share
one history. The archive keeps ten years; every other set keeps about three
months — enough to undo a mistake, short enough to promise in a contract that
a client's data leaves the backups.

## Backup sets

| Set | `.env` keys | Holds | History |
|-----|-------------|-------|---------|
| `work` | `BACKUP_WORK_REPOSITORY`, `BACKUP_WORK_PASSWORD` | Database copies, Forgejo, the genome vaults, Vaultwarden, NPM and certificates, ntfy, n8n's files, Homepage, Syncthing's configuration, `.env`; the host's own configuration — fstab, RAID, network, SSH, NUT, the Compose unit | About three months |
| `archive` | `BACKUP_ARCHIVE_REPOSITORY`, `BACKUP_ARCHIVE_PASSWORD` | `${MEDIA_ROOT}/archive`: signed contracts, invoices, receipts, filings | Ten years |

A set is a file: `backup/<set>.paths` (and optionally `<set>.exclude`). The
credentials are `BACKUP_<SET>_REPOSITORY` and `BACKUP_<SET>_PASSWORD`, its
history `BACKUP_<SET>_KEEP_*`, with `-` written as `_`. `make backup` picks up
every set it finds.

**The archive** is a plain folder, readable in ten years without any software
of ours. Nothing is deleted from it before its time; its history only covers
mistakes. How documents reach it is decided outside this repository.

**Not backed up, on purpose:** Ollama's models (downloadable again), the Redis
queue, restic's cache, n8n's execution binary data, Vaultwarden's icon cache,
container images; Syncthing's index and Forgejo's queues and search indexes,
rebuilt by the services; Forgejo's sessions, temporary files and download
archives, and the access logs — worthless after a restore.

## Off-site storage

Any S3-compatible store works. This setup uses Hetzner Object Storage: an EU
provider, a base price that includes about 1 TB, free API calls. Object
Storage, not the same provider's Storage Box: that one speaks SFTP, the key
that writes there can also delete, and none of the protections below exist.
One bucket, one prefix per set:

```
BACKUP_WORK_REPOSITORY=s3:https://fsn1.your-objectstorage.com/<bucket>/work
BACKUP_ARCHIVE_REPOSITORY=s3:https://fsn1.your-objectstorage.com/<bucket>/archive
```

### Two keys

| Key | Where it lives | Can |
|-----|----------------|-----|
| Nightly | `.env` (`BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY`) | Read, write and list; delete nothing but restic's lock files |
| Admin | Vaultwarden and the recovery sheet only | Everything, including deleting and pruning |

Keys in a Hetzner project can reach every bucket of that project by default,
so the nightly key is restricted with **deny** statements. Turn on bucket
**versioning** as well: then even an object overwritten with garbage keeps its
previous version, and the nightly key is denied deleting versions.

The policy names every part of a restic repository except `locks/`, instead
of denying everything else with `NotResource`: the provider does not document
`NotResource`, and plain `Resource` patterns work on any S3 implementation.
Starting point, applied with the admin key. The test in
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
      "Resource": ["arn:aws:s3:::<bucket>/*/config",
                   "arn:aws:s3:::<bucket>/*/data/*",
                   "arn:aws:s3:::<bucket>/*/index/*",
                   "arn:aws:s3:::<bucket>/*/keys/*",
                   "arn:aws:s3:::<bucket>/*/snapshots/*"]
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

### Old versions expire after 30 days

Versioning has a cost of its own: an object that `prune` deletes — a client's
data after an exit, say — stays behind as an old version, forever, unless a
lifecycle rule expires it. Thirty days leave time to notice an attack that
overwrites the bucket and to bring the previous versions back, and keep a
deletion real. The nightly key is denied changing the rule.

```json
{
  "Rules": [
    {"ID": "old-versions-expire", "Status": "Enabled", "Prefix": "",
     "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
     "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}},
    {"ID": "lone-delete-markers", "Status": "Enabled", "Prefix": "",
     "Expiration": {"ExpiredObjectDeleteMarker": true}}
  ]
}
```

## First-time setup

Once, in this order. Every step states what it should print. The AWS CLI runs
in a container, and the keys are typed, never written into a file or into the
shell history:

```bash
aws() { docker run --rm -i -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=fsn1 \
          -v "$PWD:/w:ro" -w /w amazon/aws-cli --endpoint-url https://fsn1.your-objectstorage.com "$@"; }
key() { read -rp "Access key id: " AWS_ACCESS_KEY_ID; read -rsp "Secret access key: " AWS_SECRET_ACCESS_KEY
        echo; export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; }
```

1. **Provider**, in the Console: a private bucket with Object Lock **off** —
   it can never be turned off again, and nothing here needs it — and two S3
   credentials, nightly and admin. Each secret is shown only once: put the
   admin key in Vaultwarden straight away.
2. **Versioning, policy and lifecycle rule.** The Console does not offer
   versioning; the S3 API does. Save the two documents above as `policy.json`
   and `lifecycle.json` in the current directory — the project id is the
   number in the Console's address bar — then, with the **admin** key (`key`):

   ```bash
   aws s3api put-bucket-versioning --bucket <bucket> --versioning-configuration Status=Enabled
   aws s3api get-bucket-versioning --bucket <bucket>                # "Status": "Enabled"
   aws s3api put-bucket-policy --bucket <bucket> --policy file://policy.json
   aws s3api put-bucket-lifecycle-configuration --bucket <bucket> --lifecycle-configuration file://lifecycle.json
   aws s3api get-bucket-lifecycle-configuration --bucket <bucket>   # prints the two rules
   ```

3. **The archive's folder**, owned by whoever files the documents:

   ```bash
   docker run --rm --mount type=bind,src=/mnt/raid/homelab-media,dst=/m alpine:3.24 \
     sh -c "mkdir -p /m/archive && chown $(id -u):$(id -g) /m/archive"   # src: your MEDIA_ROOT
   ```

4. **`.env`:** set both `BACKUP_*_REPOSITORY`, the nightly key and both
   `BACKUP_*_PASSWORD` (`openssl rand -hex 32`, one each). `make check-env` →
   aligned.
5. **Recovery sheet** (below), written by hand before going on.
6. `make backup-init` → `created restic repository … at s3:…`, once per set.
7. `make backup` → a JSON report with `"status": "ok"` and both sets.
8. `make backup-restore-test` → `ok:` for every database copy, a line for the
   archive (`nothing to verify` while it is empty), then `restore test passed`.
9. **Prove append-only** on a canary object, never on real data. `canary/data/`
   matches the same `*/data/*` pattern that protects restic's data, outside
   any repository. With the **nightly** key (`key`):

   ```bash
   echo canary | aws s3 cp - s3://<bucket>/canary/data/test.txt   # allowed: upload
   aws s3 rm s3://<bucket>/canary/data/test.txt                    # expected: AccessDenied
   ```

   Then remove the canary with the admin key; its old version leaves with the
   lifecycle rule. If the nightly key could delete it, the policy is not doing
   its job: fix it before relying on the backup. (A maintenance run with the
   nightly key is *not* a test: with few snapshots there may be nothing to
   delete, and it would pass for the wrong reason.)
10. **n8n:** import `workflows/homelab-backup.json`, check that the SSH and ntfy
    credentials resolve, run it once by hand (an ntfy message titled
    `Homelab - Backup OK`), then activate it.
11. `make healthcheck` → `last off-site backup  0 h ago`.
12. `make backup-maintenance` once, with the admin key → `no snapshot to
    remove` for each set, then the checks: the admin path works before the day
    it is needed.

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

**The drill:** `make backup-restore-test` brings every set back from off-site
into a scratch directory, emptied before and after. The set holding the
database copies has every Postgres dump opened with `pg_restore -l` and every
SQLite copy checked with `pragma integrity_check`; every other set is restored
whole, each file verified against the repository (`restic restore --verify`).
Run it at least every quarter.

**One path**, into a scratch directory. The values are typed or pasted, not
read from `.env` by the shell:

```bash
export RESTIC_REPOSITORY=… RESTIC_PASSWORD=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v /tmp/restore:/restore restic/restic:0.19.1 -o s3.region=fsn1 \
  restore latest --target /restore --include /opt/homelab-infra/data/vaultwarden/data
```

Paths inside a snapshot are the real host paths, so the restored tree mirrors
the server's layout under the target.

**The whole server:** install Docker, clone this repository to
`/opt/homelab-infra`, restore `.env` and the data with the command above using
the recovery sheet, put each tree back in place, restore the databases from
their copies, `make up`, `make healthcheck`.

## When a client leaves

Their data — genome, repositories, media — is deleted from the server first.
Every snapshot taken before still holds it, so:

1. `make backup`: a fresh snapshot, without it.
2. `./scripts/backup.sh drop-history work`, and the same for any other set
   that held it. It shows the time of the snapshot it will keep, asks for the
   set name and the admin key, then forgets every older snapshot and prunes.
3. The pruned objects stay in the bucket as old versions for 30 days (the
   lifecycle rule), then they are gone.

The deletion certificate states that date: the session plus 30 days. The
older history of everything else in the set goes too — the price of a
deletion that is real, paid only when a client leaves. The archive is never
part of it: the contract and the invoices are what the law asks to keep.

If step 2 is forgotten, the data still leaves on its own: three months of
history, up to a quarter until the next maintenance, 30 days of old versions —
about seven months.

## Maintenance — the quarterly session

`make backup-maintenance` asks for the admin key and applies each set's
history (`BACKUP_<SET>_KEEP_*`, else `BACKUP_KEEP_*`): `work` keeps 14 daily,
8 weekly and 3 monthly snapshots; `archive` 7 daily, 5 weekly, 12 monthly and
10 yearly — invoices and contracts must be kept ten years. A set's snapshots
form one history whatever paths they hold, so a path added by a release never
starts a history of its own that would never age out.

For each set it first shows what the rules would remove, and asks for the set
name before removing anything. Look at the list before typing it: the nightly
run makes one snapshot per set per night, at the same time, from this host.
Two snapshots in one night, a time far from the nightly run or another host
are snapshots this server did not take in the ordinary way — stop, and find
out why before removing anything. Then it prunes and reads back 10% of the
data with `restic check`. In the same session:

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
