#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  healthcheck.sh — check that the stack actually responds     ║
# ╚══════════════════════════════════════════════════════════════╝
#
# Meant to be run BEFORE and AFTER every upgrade: `docker compose ps` only
# reports that a process is alive, not that the service works. This queries
# each service's health endpoint and counts rows in the databases, so a
# before/after comparison shows whether a migration lost anything.
#
# Usage:
#   ./scripts/healthcheck.sh              # everything
#   ./scripts/healthcheck.sh n8n forgejo  # selected services only
#
# Every check runs before anything is reported — a comparison is only useful
# whole — and the exit code is 0 when they all passed, 1 otherwise, so an
# upgrade script can use it as a rollback condition.

set -uo pipefail

# Everything below (.env, docker compose) is relative to the repository root:
# if the cd failed, the checks would run somewhere else and report meaningless
# results instead of failing.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# The .env is NOT sourced: it is a data file, not a script. A legitimate
# value containing spaces (an email provider app password, say) would make the
# shell execute its second word as a command. Only the keys needed here are
# read, one at a time.
env_get() {
  local key=$1 def=${2:-} val
  [ -f .env ] || { printf '%s' "$def"; return; }
  val=$(sed -n "s/^[[:space:]]*${key}=//p" .env | tail -1 | tr -d '"'\''\r' | xargs 2>/dev/null)
  printf '%s' "${val:-$def}"
}

NGINX_ADMIN_PORT=$(env_get NGINX_ADMIN_PORT 81)
HOMEPAGE_PORT=$(env_get HOMEPAGE_PORT 3000)
FORGEJO_HTTP_PORT=$(env_get FORGEJO_HTTP_PORT 3001)
N8N_PORT=$(env_get N8N_PORT 5678)
OLLAMA_PORT=$(env_get OLLAMA_PORT 11434)
NTFY_PORT=$(env_get NTFY_PORT 8091)
EXCALIDRAW_PORT=$(env_get EXCALIDRAW_PORT 8092)
VAULTWARDEN_PORT=$(env_get VAULTWARDEN_PORT 8096)
SYNCTHING_GUI_PORT=$(env_get SYNCTHING_GUI_PORT 8384)
N8N_DB_USER=$(env_get N8N_DB_USER n8n)
N8N_DB_NAME=$(env_get N8N_DB_NAME n8n)

PASS=0
FAIL=0
ok()    { printf "  \033[32m✔\033[0m %-34s %s\n" "$1" "${2:-}"; PASS=$((PASS+1)); }
bad()   { printf "  \033[31m✘\033[0m %-34s %s\n" "$1" "${2:-}"; FAIL=$((FAIL+1)); }
title() { printf "\n\033[1m%s\033[0m\n" "$1"; }

SEL=("$@")
# True when no filter was given, or when this service is among those asked for.
want() {
  [ "${#SEL[@]}" -eq 0 ] && return 0
  local a; for a in "${SEL[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# http <label> <url> [expected-code] [regex the body must contain]
# The body check exists because several services answer 200 from a frontend
# even when the backend behind it is broken.
http() {
  local label=$1 url=$2 want_code=${3:-200} pat=${4:-} body code
  body=$(curl -s -m 8 -w $'\n%{http_code}' "$url" 2>/dev/null)
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  if [ "$code" != "$want_code" ]; then bad "$label" "HTTP $code (expected $want_code)"; return 1; fi
  if [ -n "$pat" ] && ! grep -qE "$pat" <<<"$body"; then
    bad "$label" "HTTP $code but the body does not contain /$pat/"; return 1
  fi
  ok "$label" "HTTP $code"
}

# Container id of a compose service, without assuming the project prefix.
# `-a` matters: without it `ps -q` lists only RUNNING containers, so a stopped
# or created one is reported as "no container" — the least useful thing to say
# at exactly the moment someone is diagnosing why a service is down.
cid() { docker compose ps -qa "$1" 2>/dev/null | head -1; }

# state <service> — running, and healthy when the service declares a healthcheck.
state() {
  local svc=$1 id st
  id=$(cid "$svc")
  if [ -z "$id" ]; then bad "$svc" "no container declared"; return 1; fi
  st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null)
  case "$st" in
    running|running/healthy) ok "$svc" "$st" ;;
    *)                       bad "$svc" "$st" ;;
  esac
}

title "Containers"
for s in nginx homepage cloudflared ntfy forgejo n8n n8n-worker n8n-db n8n-redis \
         syncthing ollama excalidraw vaultwarden; do
  want "$s" && state "$s"
done

title "Health endpoints"
want nginx       && http "nginx (admin)"     "http://127.0.0.1:${NGINX_ADMIN_PORT}/"                  200
want homepage    && http "homepage"          "http://127.0.0.1:${HOMEPAGE_PORT}/"                   200
want forgejo     && http "forgejo"           "http://127.0.0.1:${FORGEJO_HTTP_PORT}/api/healthz"    200 '"status": *"pass"'
want n8n         && http "n8n liveness"      "http://127.0.0.1:${N8N_PORT}/healthz"                 200 '"status":"ok"'
want n8n         && http "n8n readiness"     "http://127.0.0.1:${N8N_PORT}/healthz/readiness"       200
want ollama      && http "ollama"            "http://127.0.0.1:${OLLAMA_PORT}/api/tags"            200 'models'
want ntfy        && http "ntfy"              "http://127.0.0.1:${NTFY_PORT}/v1/health"              200 '"healthy":true'
want excalidraw  && http "excalidraw"        "http://127.0.0.1:${EXCALIDRAW_PORT}/"                 200
want vaultwarden && http "vaultwarden"       "http://127.0.0.1:${VAULTWARDEN_PORT}/alive"           200
want syncthing   && http "syncthing"         "http://127.0.0.1:${SYNCTHING_GUI_PORT}/rest/noauth/health" 200 '"status": *"OK"'

title "Persistence"
if want n8n-db; then
  if docker compose exec -T n8n-db pg_isready -U "${N8N_DB_USER}" >/dev/null 2>&1; then
    ok "postgres accepting connections"
  else bad "postgres accepting connections"; fi
fi
if want n8n-redis; then
  if [ "$(docker compose exec -T n8n-redis redis-cli ping 2>/dev/null | tr -d '\r')" = "PONG" ]; then
    ok "redis responding"
  else bad "redis responding"; fi
fi

# These numbers are not a health check but a fingerprint: comparing them
# before and after an upgrade is the most direct way to notice that a
# migration lost something.
if want n8n; then
  title "n8n data fingerprint (compare before/after an upgrade)"
  q() { docker compose exec -T n8n-db psql -U "${N8N_DB_USER}" -d "${N8N_DB_NAME}" -tAc "$1" 2>/dev/null | tr -d '\r'; }
  WF=$(q "select count(*) from workflow_entity")
  if [ -n "$WF" ]; then
    ok "workflows"           "$WF"
    ok "active workflows"      "$(q "select count(*) from workflow_entity where active")"
    ok "credentials"         "$(q "select count(*) from credentials_entity")"
    ok "migrations applied"  "$(q "select count(*) from migrations")"
  else
    bad "reading the n8n database" "no response"
  fi
fi

printf "\n\033[1mResult:\033[0m %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
