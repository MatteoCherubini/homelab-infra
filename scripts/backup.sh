#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  backup.sh — consistent dumps, then restic off-site          ║
# ╚══════════════════════════════════════════════════════════════╝
#
# What is backed up, where, with which keys, and how to restore it:
# docs/backup.md. What goes into each backup set is data, not code: see the
# files under backup/.
#
# Usage:
#   ./scripts/backup.sh run [set]           # dumps, then every set (or one)
#   ./scripts/backup.sh init [set]          # create the repositories, once
#   ./scripts/backup.sh snapshots [set]     # list the snapshots
#   ./scripts/backup.sh restore-test [set]  # restore the latest snapshots, verify them
#   ./scripts/backup.sh maintenance [set]   # forget + prune + check, ADMIN key
#   ./scripts/backup.sh drop-history <set>  # keep only the latest snapshot, ADMIN key
#
# `run` prints exactly one JSON document on stdout, which the n8n workflow
# parses, and its progress on stderr. It exits 0 only when every step worked.
#
# Nothing here needs sudo. Every read of root-owned data and every write into
# the backup directories happens inside a throwaway container, so the script
# runs the same as the interactive user and as n8n-runner.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_DIR=$(pwd)
SETS_DIR="$REPO_DIR/backup"

# The .env is NOT sourced — same reader as healthcheck.sh, and for the same
# reason: it is a data file, and a value with spaces would become a command.
env_get() {
  local key=$1 def=${2:-} val
  [ -f .env ] || { printf '%s' "$def"; return; }
  val=$(sed -n "s/^[[:space:]]*${key}=//p" .env | tail -1 | tr -d '"'\''\r' | xargs 2>/dev/null)
  printf '%s' "${val:-$def}"
}

# Docker bind mounts need absolute paths; DATA_ROOT may be relative.
absolute() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$REPO_DIR" "${1#./}" ;; esac; }

DATA_ROOT=$(absolute "$(env_get DATA_ROOT ./data)")
MEDIA_ROOT=$(absolute "$(env_get MEDIA_ROOT ./media)")
GENOME_VAULTS_ROOT=$(env_get GENOME_VAULTS_ROOT /srv/genome-vaults)
GENOME_MEDIA_ROOT=$(absolute "$(env_get GENOME_MEDIA_ROOT "$MEDIA_ROOT/genomes")")
PHOTO_PERSONAL_ROOT=$(absolute "$(env_get PHOTO_PERSONAL_ROOT "$MEDIA_ROOT/personal")")
RESTIC_IMG="$(env_get RESTIC_IMAGE restic/restic):$(env_get RESTIC_VERSION latest)"
TOOLS_IMG="$(env_get BACKUP_TOOLS_IMAGE alpine):$(env_get BACKUP_TOOLS_VERSION latest)"
# pg_restore for the restore drill: the same image the database runs on.
PG_IMG="$(env_get N8N_DB_IMAGE postgres):$(env_get N8N_DB_VERSION 18-alpine)"
S3_REGION=$(env_get BACKUP_S3_REGION)
HOST_TAG=$(hostname -s)

STATE_DIR="$DATA_ROOT/backup"          # restic cache and the last-success stamp
DUMP_DIR="$MEDIA_ROOT/backup/dumps"    # consistent copies, refreshed before each run
HOST_DIR="$MEDIA_ROOT/host-configs"    # other machines' configuration, host-config-copy.sh
SCRATCH="$STATE_DIR/restore-test"      # the restore drill's, emptied before and after

ERRORS=()
DUMPED=()
SET_RESULTS=()
RESTIC_MOUNTS=()
TMP_FILES=()
trap 'rm -f "${TMP_FILES[@]}"' EXIT

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { log "ERROR: $*"; ERRORS+=("$*"); }
die()  { log "ERROR: $*"; exit 1; }

# Comments and blank lines are ignored in every list under backup/.
read_list() { sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' "$1"; }

# Placeholders allowed in backup/*: a fixed set, substituted literally, never
# evaluated — a list file must not be able to run anything.
# shellcheck disable=SC2016  # the single-quoted patterns are meant literally
expand() {
  local s=$1
  s=${s//'${DATA_ROOT}'/$DATA_ROOT}
  s=${s//'${MEDIA_ROOT}'/$MEDIA_ROOT}
  s=${s//'${GENOME_VAULTS_ROOT}'/$GENOME_VAULTS_ROOT}
  s=${s//'${GENOME_MEDIA_ROOT}'/$GENOME_MEDIA_ROOT}
  s=${s//'${PHOTO_PERSONAL_ROOT}'/$PHOTO_PERSONAL_ROOT}
  s=${s//'${REPO_DIR}'/$REPO_DIR}
  printf '%s' "$s"
}

json_strings() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -cs .; fi; }
json_objects() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -cs .; fi; }

# Set names come from the files: backup/<set>.paths defines a set.
all_sets() { local f; for f in "$SETS_DIR"/*.paths; do [ -e "$f" ] && basename "$f" .paths; done; }

# A single flock on a directory every account can read: no lock file to own.
take_lock() {
  exec 9<"$SETS_DIR" || die "cannot open $SETS_DIR for locking"
  flock -n 9 || die "another backup operation is running"
}

# A set's keys in .env start with BACKUP_<SET>_, `-` becoming `_`.
set_prefix() { printf 'BACKUP_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }

# BACKUP_<SET>_REPOSITORY and BACKUP_<SET>_PASSWORD.
set_credentials() {
  local pre
  pre=$(set_prefix "$1")
  RESTIC_REPOSITORY=$(env_get "${pre}_REPOSITORY")
  RESTIC_PASSWORD=$(env_get "${pre}_PASSWORD")
  export RESTIC_REPOSITORY RESTIC_PASSWORD
  [ -n "$RESTIC_REPOSITORY" ] && [ -n "$RESTIC_PASSWORD" ] \
    && [[ $RESTIC_REPOSITORY != *CHANGE_ME* ]] && [[ $RESTIC_PASSWORD != CHANGE_ME* ]]
}

nightly_key() {
  AWS_ACCESS_KEY_ID=$(env_get BACKUP_S3_ACCESS_KEY_ID)
  AWS_SECRET_ACCESS_KEY=$(env_get BACKUP_S3_SECRET_ACCESS_KEY)
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  [ -n "$AWS_ACCESS_KEY_ID" ] && [[ $AWS_ACCESS_KEY_ID != CHANGE_ME* ]] \
    && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [[ $AWS_SECRET_ACCESS_KEY != CHANGE_ME* ]]
}

# Secrets reach the container by NAME (-e VAR), never on the command line,
# where any user could read them in the process list.
restic_cmd() {
  local opts=()
  [ -n "$S3_REGION" ] && opts+=(-o "s3.region=$S3_REGION")
  docker run --rm --hostname "$HOST_TAG" \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    --mount "type=bind,src=$STATE_DIR/cache,dst=/cache" "${RESTIC_MOUNTS[@]}" \
    "$RESTIC_IMG" --cache-dir /cache "${opts[@]}" "$@"
}

prepare_dirs() {
  docker run --rm --mount "type=bind,src=$DATA_ROOT,dst=/d" --mount "type=bind,src=$MEDIA_ROOT,dst=/m" \
    "$TOOLS_IMG" sh -c 'mkdir -p /d/backup/cache /m/backup/dumps && chmod 700 /m/backup/dumps' \
    || die "cannot create $STATE_DIR or $DUMP_DIR"
}

# ── Consistent copies ─────────────────────────────────────────
# A database file copied while it is being written is not a backup. Postgres
# is dumped, SQLite is copied with its own online backup API.

dump_postgres() {
  local line svc user_key db_key user db lines=()
  mapfile -t lines < <(read_list "$SETS_DIR/postgres.list")
  for line in "${lines[@]}"; do
    read -r svc user_key db_key <<<"$line"
    user=$(env_get "$user_key"); db=$(env_get "$db_key")
    log "pg_dump $svc ($db)"
    # </dev/null: `compose exec` would otherwise read stdin it does not need.
    if docker compose exec -T "$svc" pg_dump -U "$user" -d "$db" -Fc </dev/null \
      | docker run --rm -i --mount "type=bind,src=$DUMP_DIR,dst=/out" "$TOOLS_IMG" \
          sh -c "cat > /out/$svc.dump.part && mv /out/$svc.dump.part /out/$svc.dump"; then
      DUMPED+=("$svc.dump")
    else
      fail "pg_dump of $svc failed"
    fi
  done
}

# One container per database: a missing or broken one fails alone.
# `--mount` (not -v) refuses a missing source instead of creating it as root.
dump_sqlite() {
  local line name path lines=()
  mapfile -t lines < <(read_list "$SETS_DIR/sqlite.list")
  for line in "${lines[@]}"; do
    read -r name path <<<"$line"
    path=$(expand "$path")
    log "sqlite .backup $name"
    # The directory is mounted read-write on purpose: a WAL database cannot be
    # opened without its -shm file. sqlite3 takes the proper locks, so the
    # service keeps running while the copy is made.
    # The copy runs as the owner of the file. With the service stopped,
    # sqlite3 creates -wal and -shm itself; a root-owned pair left behind by an
    # interrupted copy would lock the service out of its own database.
    if docker run --rm --mount "type=bind,src=$(dirname "$path"),dst=/db" \
        --mount "type=bind,src=$DUMP_DIR,dst=/out" "$TOOLS_IMG" sh -c '
          apk add --no-cache sqlite su-exec >/dev/null || exit 2
          # Without this, sqlite3 would create an empty database and back it up.
          [ -f "/db/$1" ] || { echo "missing: $1" >&2; exit 3; }
          su-exec "$(stat -c %u:%g "/db/$1")" sqlite3 "/db/$1" ".backup /tmp/copy" || exit 1
          [ "$(sqlite3 /tmp/copy "pragma integrity_check")" = ok ] || exit 1
          cp /tmp/copy "/out/$2.sqlite3.part" && mv "/out/$2.sqlite3.part" "/out/$2.sqlite3"' \
        sh "$(basename "$path")" "$name"; then
      DUMPED+=("$name.sqlite3")
    else
      fail "SQLite copy of $name failed ($path)"
    fi
  done
}

# ── Paperless's own export ────────────────────────────────────
# The database dump brings Paperless back as it was; the export outlives it:
# the originals under readable names, and a manifest that any later version
# imports. It lands in ${MEDIA_ROOT}/archive/paperless, which the `archive` set
# keeps ten years. Incremental: only new and changed files are written, and
# --delete drops what was deleted in Paperless — the history keeps it.
# Without archive copies and thumbnails, which Paperless makes again and which
# would only grow a deduplicated backup. docs/stacks/documents.md
export_paperless() {
  docker compose config --services 2>/dev/null | grep -qx paperless || return 0
  log "paperless document_exporter"
  # stdout is the JSON report's: the exporter's own lines go to stderr.
  if docker compose exec -T paperless document_exporter /usr/src/paperless/export \
       --delete --use-filename-format --use-folder-prefix --no-archive --no-thumbnail \
       --no-progress-bar </dev/null >&2; then
    DUMPED+=("paperless-export")
  else
    fail "Paperless export failed"
  fi
}

# ── One backup set ────────────────────────────────────────────

# Prints which of the given paths exist, looked up as root inside a
# container: the account running the backup may not be allowed to look inside
# some of them (/var/lib/nut, another user's home), and a path it cannot see
# would otherwise be skipped as absent, silently.
present_paths() {
  [ $# -gt 0 ] || return 0
  docker run --rm --mount "type=bind,src=/,dst=/host,readonly" "$TOOLS_IMG" \
    sh -c 'for p; do [ -e "/host$p" ] && printf "%s\n" "$p"; done; exit 0' sh "$@"
}

backup_set() {
  local set=$1 p i listing raw=() candidates=() present=() paths=() excl summary rc
  local -A seen=()
  set_credentials "$set" || { fail "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"; return; }
  RESTIC_MOUNTS=()
  mapfile -t raw < <(read_list "$SETS_DIR/$set.paths")
  for p in "${raw[@]}"; do candidates+=("$(expand "${p#\?}")"); done
  listing=$(present_paths "${candidates[@]}") || { fail "$set: cannot check which paths exist"; return; }
  mapfile -t present <<<"$listing"
  for p in "${present[@]}"; do [ -n "$p" ] && seen[$p]=1; done
  for i in "${!raw[@]}"; do
    p=${candidates[$i]}
    if [ -z "$p" ] || [ -z "${seen[$p]:-}" ]; then
      [[ ${raw[$i]} == '?'* ]] && { log "$set: skipped, absent: $p"; continue; }
      fail "$set: path not found: $p"; return
    fi
    # Same path inside and outside: a restore lands where the data lived.
    paths+=("$p"); RESTIC_MOUNTS+=(--mount "type=bind,src=$p,dst=$p,readonly")
  done
  excl=$(mktemp); TMP_FILES+=("$excl")
  if [ -f "$SETS_DIR/$set.exclude" ]; then
    while IFS= read -r p; do expand "$p"; echo; done < <(read_list "$SETS_DIR/$set.exclude") >"$excl"
  fi
  RESTIC_MOUNTS+=(--mount "type=bind,src=$excl,dst=/excludes,readonly")

  log "$set: restic backup of ${#paths[@]} paths"
  # pipefail makes $? carry restic's exit code through jq and tail.
  summary=$(restic_cmd backup --json --tag nightly --exclude-file /excludes "${paths[@]}" \
            | jq -c 'select(.message_type == "summary")' | tail -1)
  rc=$?
  # restic exit 3: the snapshot exists but some files could not be read.
  if [ "$rc" -ne 0 ] || [ -z "$summary" ]; then
    fail "$set: restic backup exited $rc"
    SET_RESULTS+=("$(jq -cn --arg n "$set" --argjson rc "$rc" '{name:$n,status:"error",restic_exit:$rc}')")
    return
  fi
  SET_RESULTS+=("$(jq -c --arg n "$set" '{name:$n, status:"ok", snapshot:.snapshot_id,
    files_new:.files_new, files_changed:.files_changed, data_added:.data_added,
    duration_s:(.total_duration | floor)}' <<<"$summary")")
  log "$set: ok"
}

# ── Commands ──────────────────────────────────────────────────

cmd_run() {
  local run_at status=ok sets=() set
  run_at=$(date -u +%FT%TZ)
  if [ $# -gt 0 ]; then sets=("$@"); else mapfile -t sets < <(all_sets); fi
  take_lock
  [ ${#sets[@]} -gt 0 ] || fail "no backup set: backup/*.paths is empty"
  [ -f .env ] || fail ".env not found"
  command -v jq >/dev/null || fail "jq is not installed"
  nightly_key || fail "BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY not set"

  if [ ${#ERRORS[@]} -eq 0 ]; then
    prepare_dirs
    dump_postgres
    dump_sqlite
    export_paperless
    # A failed dump does not stop the run: the previous copy and every other
    # path still go off-site, and the run is reported as an error anyway.
    for set in "${sets[@]}"; do backup_set "$set"; done
  fi

  if [ ${#ERRORS[@]} -eq 0 ]; then
    docker run --rm --mount "type=bind,src=$STATE_DIR,dst=/s" "$TOOLS_IMG" \
      sh -c 'date +%s > /s/last-success' || fail "cannot write $STATE_DIR/last-success"
  fi
  [ ${#ERRORS[@]} -gt 0 ] && status=error

  jq -n --arg run_at "$run_at" --arg status "$status" --arg host "$HOST_TAG" \
    --argjson sets "$(json_objects "${SET_RESULTS[@]}")" \
    --argjson dumps "$(json_strings "${DUMPED[@]}")" \
    --argjson errors "$(json_strings "${ERRORS[@]}")" \
    '{run_at:$run_at, status:$status, host:$host, sets:$sets, dumps:$dumps, errors:$errors}'
  [ "$status" = ok ]
}

cmd_init() {
  local sets=() set
  if [ $# -gt 0 ]; then sets=("$@"); else mapfile -t sets < <(all_sets); fi
  take_lock
  nightly_key || die "BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY not set"
  prepare_dirs
  for set in "${sets[@]}"; do
    set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
    log "$set: restic init"
    restic_cmd init || die "$set: init failed"
  done
}

cmd_snapshots() {
  local sets=() set
  if [ $# -gt 0 ]; then sets=("$@"); else mapfile -t sets < <(all_sets); fi
  nightly_key || die "BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY not set"
  for set in "${sets[@]}"; do
    set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
    echo "── $set"
    restic_cmd snapshots
  done
}

# The drill that the rest of the tooling cannot do: bring each set back from
# off-site into a scratch directory and prove it opens. The set holding the
# database copies gets the database check; every other set is restored whole,
# each file verified against the repository. The set holding the other
# machines' configuration also gets each copy checked against its checksum.
cmd_restore_test() {
  local sets=() set ok=1
  if [ $# -gt 0 ]; then sets=("$@"); else mapfile -t sets < <(all_sets); fi
  take_lock
  nightly_key || die "BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY not set"
  prepare_dirs
  for set in "${sets[@]}"; do
    set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
    clear_scratch
    if holds "$set" "$DUMP_DIR"; then restore_dumps "$set" || ok=0
    else restore_whole "$set" || ok=0; fi
    if holds "$set" "$MEDIA_ROOT/archive"; then check_paperless_export "$set" || ok=0; fi
    if holds "$set" "$HOST_DIR"; then restore_host_configs "$set" || ok=0; fi
  done
  clear_scratch
  [ "$ok" -eq 1 ] || die "restore test FAILED"
  log "restore test passed"
}

clear_scratch() {
  docker run --rm --mount "type=bind,src=$STATE_DIR,dst=/s" "$TOOLS_IMG" rm -rf /s/restore-test
}

# True when the set's list names the directory: holds <set> <directory>.
holds() {
  local p
  while IFS= read -r p; do
    [ "$(expand "${p#\?}")" = "$2" ] && return 0
  done < <(read_list "$SETS_DIR/$1.paths")
  return 1
}

# Every file of the latest snapshot, read back and checked — up to
# BACKUP_RESTORE_WHOLE_MAX_MB. Past it, a random sample of
# BACKUP_RESTORE_SAMPLE_FILES files, different every time: a set of
# photographs restored whole would fill the disk the restore lands on. An
# empty archive is legitimate at the start, so it is reported, not failed.
RESTORED_WHOLE=0
restore_whole() {
  local set=$1 n size max files=() includes=() f
  RESTORED_WHOLE=0
  RESTIC_MOUNTS=(--mount "type=bind,src=$STATE_DIR,dst=$STATE_DIR")
  max=$(( $(env_get BACKUP_RESTORE_WHOLE_MAX_MB 2048) * 1024 * 1024 ))
  size=$(restic_cmd stats latest --json | jq -r '.total_size')
  [[ $size =~ ^[0-9]+$ ]] || { log "ERROR: $set: cannot read the size of the latest snapshot"; return 1; }
  if [ "$size" -le "$max" ]; then
    log "$set: restoring the latest snapshot whole, every file verified"
    RESTORED_WHOLE=1
  else
    mapfile -t files < <(restic_cmd ls latest --json | jq -r 'select(.type == "file") | .path' \
                           | shuf -n "$(env_get BACKUP_RESTORE_SAMPLE_FILES 25)")
    [ "${#files[@]}" -gt 0 ] || { log "ERROR: $set: cannot list the latest snapshot"; return 1; }
    for f in "${files[@]}"; do includes+=(--include "$f"); done
    log "$set: $(( size / 1048576 )) MB, past BACKUP_RESTORE_WHOLE_MAX_MB: restoring ${#files[@]} files at random, each verified"
  fi
  restic_cmd restore latest --target "$SCRATCH" --verify "${includes[@]}" \
    || { log "ERROR: $set: restore failed"; return 1; }
  n=$(docker run --rm --mount "type=bind,src=$SCRATCH,dst=/r,readonly" "$TOOLS_IMG" \
        sh -c 'find /r -type f | wc -l') || { log "ERROR: $set: cannot count the restored files"; return 1; }
  if [ "$n" -gt 0 ]; then log "$set: ok, $n files restored and verified"
  else log "$set: the latest snapshot holds no files yet, nothing to verify"; fi
}

# Paperless's export, as an import into a new Paperless would need it: the
# manifest opens, and every document it lists has its original beside it.
# Only after a whole restore: a sample of files says nothing about the pairs.
check_paperless_export() {
  local set=$1
  [ "$RESTORED_WHOLE" -eq 1 ] || { log "$set: restored as a sample, the Paperless export is not checked"; return 0; }
  docker run --rm --mount "type=bind,src=$SCRATCH,dst=/r,readonly" "$TOOLS_IMG" sh -c '
    d="/r$1"
    [ -e "$d/manifest.json" ] || { echo "no Paperless export yet, nothing to check" >&2; exit 0; }
    apk add --no-cache jq >/dev/null || exit 2
    # First, or a manifest that does not open would count as zero documents.
    jq -e "type == \"array\"" "$d/manifest.json" >/dev/null \
      || { echo "FAILED: the Paperless manifest does not open" >&2; exit 1; }
    list() { jq -r ".[] | select(.model == \"documents.document\") | .__exported_file_name__" "$d/manifest.json"; }
    n=$(list | wc -l)
    missing=$(list | while IFS= read -r f; do [ -f "$d/$f" ] || echo "$f"; done)
    [ -z "$missing" ] || { echo "FAILED: originals missing from the Paperless export:" >&2; echo "$missing" >&2; exit 1; }
    echo "ok: Paperless export, $n documents, every original present" >&2' sh "$MEDIA_ROOT/archive/paperless"
}

# Postgres dumps opened with pg_restore -l, SQLite copies with integrity_check.
restore_dumps() {
  local set=$1 restored="$SCRATCH$DUMP_DIR" ok=1
  RESTIC_MOUNTS=(--mount "type=bind,src=$STATE_DIR,dst=$STATE_DIR")
  log "$set: restoring $DUMP_DIR from the latest snapshot"
  restic_cmd restore latest --target "$SCRATCH" --include "$DUMP_DIR" \
    || { log "ERROR: $set: restore failed"; return 1; }

  docker run --rm --mount "type=bind,src=$restored,dst=/r,readonly" "$PG_IMG" sh -c '
    n=0; for f in /r/*.dump; do [ -e "$f" ] || continue
      pg_restore -l "$f" >/dev/null || { echo "FAILED: $f" >&2; exit 1; }
      echo "ok: $(basename "$f")" >&2; n=$((n+1)); done
    [ "$n" -gt 0 ] || { echo "no Postgres dump restored" >&2; exit 1; }' || ok=0
  docker run --rm --mount "type=bind,src=$restored,dst=/r,readonly" "$TOOLS_IMG" sh -c '
    apk add --no-cache sqlite >/dev/null || exit 2
    n=0; for f in /r/*.sqlite3; do [ -e "$f" ] || continue
      [ "$(sqlite3 "file:$f?immutable=1" "pragma integrity_check")" = ok ] \
        || { echo "FAILED: $f" >&2; exit 1; }
      echo "ok: $(basename "$f")" >&2; n=$((n+1)); done
    [ "$n" -gt 0 ] || { echo "no SQLite copy restored" >&2; exit 1; }' || ok=0
  [ "$ok" -eq 1 ]
}

# Every copy taken by host-config-copy.sh: it must match the checksum written
# when it reached this server, and open. Before the first copy there is
# nothing to check, and that is reported, not failed.
restore_host_configs() {
  local set=$1
  RESTIC_MOUNTS=(--mount "type=bind,src=$STATE_DIR,dst=$STATE_DIR")
  log "$set: restoring $HOST_DIR from the latest snapshot"
  restic_cmd restore latest --target "$SCRATCH" --include "$HOST_DIR" \
    || { log "ERROR: $set: restore failed"; return 1; }
  docker run --rm --mount "type=bind,src=$SCRATCH,dst=/r,readonly" "$TOOLS_IMG" sh -c '
    d="/r$1"
    [ -d "$d" ] || { echo "no other machine copied yet, nothing to verify" >&2; exit 0; }
    n=0; for f in $(find "$d" -type f -name "*.tar.gz"); do
      [ -f "$f.sha256" ] || { echo "FAILED: no checksum for ${f#$d/}" >&2; exit 1; }
      ( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null ) \
        || { echo "FAILED: checksum of ${f#$d/}" >&2; exit 1; }
      tar -tzf "$f" >/dev/null || { echo "FAILED: cannot open ${f#$d/}" >&2; exit 1; }
      echo "ok: ${f#$d/}" >&2; n=$((n+1)); done
    echo "$n copies of other machines verified" >&2' sh "$HOST_DIR"
}

# Retention and pruning need delete rights, which the nightly key does not
# have by design. The admin key is asked for here and never written to disk.
admin_key() {
  if [ -z "${BACKUP_ADMIN_ACCESS_KEY_ID:-}" ]; then
    read -rp "Admin access key id: " BACKUP_ADMIN_ACCESS_KEY_ID
  fi
  if [ -z "${BACKUP_ADMIN_SECRET_ACCESS_KEY:-}" ]; then
    read -rsp "Admin secret access key: " BACKUP_ADMIN_SECRET_ACCESS_KEY; echo >&2
  fi
  AWS_ACCESS_KEY_ID=$BACKUP_ADMIN_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY=$BACKUP_ADMIN_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

# Each set keeps its own history, because the sets do not live equally long:
# ten years for the archive, a few months for anything a client may ask to
# have deleted. BACKUP_<SET>_KEEP_<RULE>, else BACKUP_KEEP_<RULE>, else the
# defaults below; a rule at 0 is left out. Fills KEEP_ARGS.
# No grouping: each set has its own repository, and restic's default (host
# and paths) would start a separate history, one the rules never age out,
# every time a release adds a path to a set.
retention_for() {
  local pre rule def n
  pre=$(set_prefix "$1")
  KEEP_ARGS=(--group-by '')
  for rule in DAILY:14 WEEKLY:8 MONTHLY:3 YEARLY:0; do
    def=${rule#*:}; rule=${rule%%:*}
    n=$(env_get "${pre}_KEEP_${rule}" "$(env_get "BACKUP_KEEP_${rule}" "$def")")
    [[ $n =~ ^[0-9]+$ ]] || die "$1: the ${rule,,} retention is not a number: $n"
    if [ "$n" -gt 0 ]; then KEEP_ARGS+=("--keep-${rule,,}" "$n"); fi
  done
  [ ${#KEEP_ARGS[@]} -gt 2 ] || die "$1: every retention rule is 0, nothing would be kept"
}

# The nightly key cannot delete, but a compromised server could still add
# snapshots with false dates, so that these rules keep them and drop the real
# ones (restic issue #22057): the attacker deletes nothing, this command does.
# So it shows what it would remove, and removes it only once a person has
# looked and typed the set name.
cmd_maintenance() {
  local sets=() set plan n answer
  if [ $# -gt 0 ]; then sets=("$@"); else mapfile -t sets < <(all_sets); fi
  take_lock
  # Every set's settings are checked before the admin key is asked for.
  for set in "${sets[@]}"; do
    set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
    retention_for "$set"
  done
  admin_key
  prepare_dirs
  for set in "${sets[@]}"; do
    set_credentials "$set"
    retention_for "$set"
    plan=$(restic_cmd forget --dry-run --json "${KEEP_ARGS[@]}") || die "$set: forget --dry-run failed"
    n=$(jq '[.[].remove // [] | length] | add // 0' <<<"$plan") || die "$set: unreadable forget plan"
    if [ "$n" -gt 0 ]; then
      log "$set: the history rules (${KEEP_ARGS[*]:2}) would remove $n snapshots:"
      restic_cmd forget --dry-run "${KEEP_ARGS[@]}" >&2
      log "$set: look for snapshots this server did not take — two in one night, a time far"
      log "$set: from the nightly run, another host — before confirming. docs/backup.md"
      read -rp "Type the set name to remove them: " answer
      [ "$answer" = "$set" ] || die "$set: not confirmed, nothing removed"
      restic_cmd forget --prune "${KEEP_ARGS[@]}" || die "$set: forget/prune failed"
    else
      log "$set: no snapshot to remove"
    fi
    # A percentage picks packs at random: "1/10" would be the same tenth
    # every quarter, and the other nine would never be read back.
    log "$set: check (a random 10% of the data read back)"
    restic_cmd check --read-data-subset=10% || die "$set: check failed"
  done
}

# When a client leaves (docs/backup.md): once their data is gone from the
# server and a fresh backup has run, every older snapshot of the set still
# holds it. Keep only the latest, prune the rest; the pruned objects then
# leave the bucket with its lifecycle rule. ADMIN key, and a typed
# confirmation, because nothing of the older history comes back.
cmd_drop_history() {
  local set=${1:-} latest answer
  if [ -z "$set" ] || [ ! -f "$SETS_DIR/$set.paths" ]; then
    die "usage: backup.sh drop-history <set>, with a set defined under backup/"
  fi
  take_lock
  nightly_key || die "BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY not set"
  set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
  prepare_dirs
  latest=$(restic_cmd snapshots latest --json | jq -r '.[0].time // empty' | cut -c1-16)
  [ -n "$latest" ] || die "$set: no snapshot to keep"
  log "$set: only the snapshot of $latest (UTC) will be kept, every older one deleted."
  log "$set: if the data was deleted after that time, stop here and run \`make backup\` first."
  read -rp "Type the set name to confirm: " answer
  [ "$answer" = "$set" ] || die "not confirmed, nothing deleted"
  admin_key
  restic_cmd forget --group-by '' --keep-last 1 --prune || die "$set: forget/prune failed"
  log "$set: history dropped, the snapshot of $latest kept"
}

cmd=${1:-run}
[ $# -gt 0 ] && shift
case "$cmd" in
  run)          cmd_run "$@" ;;
  init)         cmd_init "$@" ;;
  snapshots)    cmd_snapshots "$@" ;;
  restore-test) cmd_restore_test "$@" ;;
  maintenance)  cmd_maintenance "$@" ;;
  drop-history) cmd_drop_history "$@" ;;
  *) sed -n '10,16p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
