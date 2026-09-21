#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  healthcheck.sh — verifica che lo stack risponda davvero     ║
# ╚══════════════════════════════════════════════════════════════╝
#
# Pensato per essere eseguito PRIMA e DOPO ogni aggiornamento: `docker compose
# ps` dice solo che un processo è vivo, non che il servizio funziona. Qui si
# interroga l'endpoint di salute di ognuno e si contano le righe nei database,
# così un confronto prima/dopo mostra se un dato è sparito durante una
# migrazione.
#
# Uso:
#   ./scripts/healthcheck.sh              # tutto
#   ./scripts/healthcheck.sh n8n forgejo  # solo alcuni servizi
#
# Exit 0 se ogni controllo passa, 1 altrimenti (utilizzabile in uno script di
# aggiornamento come condizione di rollback).

set -uo pipefail

# Tutti i percorsi sotto (.env, docker compose) sono relativi alla root del
# repository: se il cd fallisse, i controlli girerebbero altrove e
# riporterebbero risultati privi di senso invece di fallire.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Il .env NON viene sourcato: è un file di dati, non uno script. Un valore
# legittimo con spazi dentro (una app-password Gmail, per dire) farebbe
# eseguire alla shell la seconda parola come comando. Qui si leggono solo le
# chiavi che servono, e solo se il valore ha la forma attesa.
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
# Vero se non è stato passato alcun filtro, o se il servizio è fra quelli chiesti.
want() {
  [ "${#SEL[@]}" -eq 0 ] && return 0
  local a; for a in "${SEL[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# http <etichetta> <url> [codice-atteso] [regex-che-il-body-deve-contenere]
# Il controllo sul body esiste perché diversi servizi rispondono 200 da un
# frontend anche quando il backend dietro è rotto.
http() {
  local label=$1 url=$2 want_code=${3:-200} pat=${4:-} body code
  body=$(curl -s -m 8 -w $'\n%{http_code}' "$url" 2>/dev/null)
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  if [ "$code" != "$want_code" ]; then bad "$label" "HTTP $code (atteso $want_code)"; return 1; fi
  if [ -n "$pat" ] && ! grep -qE "$pat" <<<"$body"; then
    bad "$label" "HTTP $code ma il body non contiene /$pat/"; return 1
  fi
  ok "$label" "HTTP $code"
}

# Nome del container di un servizio compose, senza assumere il prefisso di progetto.
cid() { docker compose ps -q "$1" 2>/dev/null | head -1; }

# state <servizio> — running, e healthy se il servizio dichiara una healthcheck.
state() {
  local svc=$1 id st
  id=$(cid "$svc")
  if [ -z "$id" ]; then bad "$svc" "nessun container"; return 1; fi
  st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null)
  case "$st" in
    running|running/healthy) ok "$svc" "$st" ;;
    *)                       bad "$svc" "$st" ;;
  esac
}

title "Container"
for s in nginx homepage cloudflared ntfy forgejo n8n n8n-worker n8n-db n8n-redis \
         syncthing ollama excalidraw vaultwarden; do
  want "$s" && state "$s"
done

title "Endpoint di salute"
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

title "Persistenza"
if want n8n-db; then
  if docker compose exec -T n8n-db pg_isready -U "${N8N_DB_USER}" >/dev/null 2>&1; then
    ok "postgres accetta connessioni"
  else bad "postgres accetta connessioni"; fi
fi
if want n8n-redis; then
  if [ "$(docker compose exec -T n8n-redis redis-cli ping 2>/dev/null | tr -d '\r')" = "PONG" ]; then
    ok "redis risponde"
  else bad "redis risponde"; fi
fi

# Questi numeri non sono un controllo di salute ma un'impronta: confrontarli
# prima e dopo un aggiornamento è il modo più diretto per accorgersi che una
# migrazione ha perso qualcosa.
if want n8n; then
  title "Impronta dati n8n (confrontare prima/dopo l'aggiornamento)"
  q() { docker compose exec -T n8n-db psql -U "${N8N_DB_USER}" -d "${N8N_DB_NAME}" -tAc "$1" 2>/dev/null | tr -d '\r'; }
  WF=$(q "select count(*) from workflow_entity")
  if [ -n "$WF" ]; then
    ok "workflow"            "$WF"
    ok "workflow attivi"     "$(q "select count(*) from workflow_entity where active")"
    ok "credenziali"         "$(q "select count(*) from credentials_entity")"
    ok "migrazioni applicate" "$(q "select count(*) from migrations")"
  else
    bad "lettura del database n8n" "nessuna risposta"
  fi
fi

printf "\n\033[1mRisultato:\033[0m %d superati, %d falliti\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
