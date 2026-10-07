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
#   ./scripts/backup.sh restore-test [set]  # restore the latest dumps, verify them
#   ./scripts/backup.sh maintenance [set]   # forget + prune + check, ADMIN key
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
RESTIC_IMG="$(env_get RESTIC_IMAGE restic/restic):$(env_get RESTIC_VERSION latest)"
TOOLS_IMG="$(env_get BACKUP_TOOLS_IMAGE alpine):$(env_get BACKUP_TOOLS_VERSION latest)"
# pg_restore for the restore drill: the same image the database runs on.
PG_IMG="$(env_get N8N_DB_IMAGE postgres):$(env_get N8N_DB_VERSION 18-alpine)"
S3_REGION=$(env_get BACKUP_S3_REGION)
HOST_TAG=$(hostname -s)

STATE_DIR="$DATA_ROOT/backup"          # restic cache and the last-success stamp
DUMP_DIR="$MEDIA_ROOT/backup/dumps"    # consistent copies, refreshed before each run

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

# BACKUP_<SET>_REPOSITORY and BACKUP_<SET>_PASSWORD, `-` becoming `_`.
set_credentials() {
  local up
  up=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
  RESTIC_REPOSITORY=$(env_get "BACKUP_${up}_REPOSITORY")
  RESTIC_PASSWORD=$(env_get "BACKUP_${up}_PASSWORD")
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
    if docker run --rm --mount "type=bind,src=$(dirname "$path"),dst=/db" \
        --mount "type=bind,src=$DUMP_DIR,dst=/out" "$TOOLS_IMG" sh -c '
          apk add --no-cache sqlite >/dev/null || exit 2
          # Without this, sqlite3 would create an empty database and back it up.
          [ -f "/db/$1" ] || { echo "missing: $1" >&2; exit 3; }
          sqlite3 "/db/$1" ".backup /out/$2.sqlite3.part" || exit 1
          [ "$(sqlite3 "/out/$2.sqlite3.part" "pragma integrity_check")" = ok ] || exit 1
          mv "/out/$2.sqlite3.part" "/out/$2.sqlite3"' sh "$(basename "$path")" "$name"; then
      DUMPED+=("$name.sqlite3")
    else
      fail "SQLite copy of $name failed ($path)"
    fi
  done
}

# ── One backup set ────────────────────────────────────────────

backup_set() {
  local set=$1 p raw=() paths=() excl summary rc
  set_credentials "$set" || { fail "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"; return; }
  RESTIC_MOUNTS=()
  mapfile -t raw < <(read_list "$SETS_DIR/$set.paths")
  for p in "${raw[@]}"; do
    local optional=0
    [[ $p == '?'* ]] && { optional=1; p=${p#\?}; }
    p=$(expand "$p")
    if [ ! -e "$p" ]; then
      [ "$optional" -eq 1 ] && { log "$set: skipped, absent: $p"; continue; }
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

# The drill that the rest of the tooling cannot do: bring the latest dumps
# back from off-site and prove they open. Postgres with pg_restore -l, SQLite
# with integrity_check. Everything happens in a scratch directory.
cmd_restore_test() {
  local set=${1:-work} scratch="$STATE_DIR/restore-test" restored
  take_lock
  nightly_key || die "BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY not set"
  set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
  prepare_dirs
  restored="$scratch$DUMP_DIR"
  RESTIC_MOUNTS=(--mount "type=bind,src=$STATE_DIR,dst=$STATE_DIR")
  log "$set: restoring $DUMP_DIR from the latest snapshot"
  restic_cmd restore latest --target "$scratch" --include "$DUMP_DIR" || die "restore failed"

  local ok=1
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

  docker run --rm --mount "type=bind,src=$STATE_DIR,dst=/s" "$TOOLS_IMG" rm -rf /s/restore-test
  [ "$ok" -eq 1 ] || die "restore test FAILED"
  log "restore test passed"
}

# Retention and pruning need delete rights, which the nightly key does not
# have by design. The admin key is asked for here and never written to disk.
cmd_maintenance() {
  local sets=() set
  if [ $# -gt 0 ]; then sets=("$@"); else mapfile -t sets < <(all_sets); fi
  take_lock
  if [ -z "${BACKUP_ADMIN_ACCESS_KEY_ID:-}" ]; then
    read -rp "Admin access key id: " BACKUP_ADMIN_ACCESS_KEY_ID
  fi
  if [ -z "${BACKUP_ADMIN_SECRET_ACCESS_KEY:-}" ]; then
    read -rsp "Admin secret access key: " BACKUP_ADMIN_SECRET_ACCESS_KEY; echo >&2
  fi
  AWS_ACCESS_KEY_ID=$BACKUP_ADMIN_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY=$BACKUP_ADMIN_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  prepare_dirs
  for set in "${sets[@]}"; do
    set_credentials "$set" || die "$set: BACKUP_*_REPOSITORY or _PASSWORD not set"
    log "$set: forget + prune"
    restic_cmd forget --prune \
      --keep-daily "$(env_get BACKUP_KEEP_DAILY 7)" \
      --keep-weekly "$(env_get BACKUP_KEEP_WEEKLY 5)" \
      --keep-monthly "$(env_get BACKUP_KEEP_MONTHLY 12)" \
      --keep-yearly "$(env_get BACKUP_KEEP_YEARLY 10)" || die "$set: forget/prune failed"
    log "$set: check (10% of the data read back)"
    restic_cmd check --read-data-subset=1/10 || die "$set: check failed"
  done
}

cmd=${1:-run}
[ $# -gt 0 ] && shift
case "$cmd" in
  run)          cmd_run "$@" ;;
  init)         cmd_init "$@" ;;
  snapshots)    cmd_snapshots "$@" ;;
  restore-test) cmd_restore_test "$@" ;;
  maintenance)  cmd_maintenance "$@" ;;
  *) sed -n '10,15p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
