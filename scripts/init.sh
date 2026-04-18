#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "🏠 Homelab – Inizializzazione"
echo "════════════════════════════════════════"

# ── .env ──────────────────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env
  echo "✅ .env creato da .env.example"
  echo "⚠️  MODIFICA le password nel file .env prima di avviare!"
else
  echo "ℹ️  .env già presente, non sovrascritto"
fi

# ── Directory dati ────────────────────────────────────────────
source .env

DATA="${DATA_ROOT:-.\/data}"
MEDIA="${MEDIA_ROOT:-.\/media}"

echo ""
echo "📁 Creazione directory dati in: $DATA"
echo "📁 Creazione directory media in: $MEDIA"

dirs=(
  "$DATA/nginx/data" "$DATA/nginx/letsencrypt"
  "$DATA/headscale/config" "$DATA/headscale/data"
  "$DATA/portainer"
  "$DATA/homepage/config"
  "$DATA/nextcloud/db"
  "$DATA/paperless/db" "$DATA/paperless/data"
  "$DATA/immich/db" "$DATA/immich/ml-cache"
  "$DATA/n8n/db" "$DATA/n8n/data"
  "$DATA/vaultwarden/data"
  "$DATA/garage/meta"
  "$DATA/kopia/config" "$DATA/kopia/cache"
  "$DATA/ollama/data"
  "$DATA/open-webui/data"
  "$DATA/netdata/config" "$DATA/netdata/lib" "$DATA/netdata/cache"
  "$DATA/grafana/data"
  "$DATA/loki/data"
  "$DATA/promtail/config"
  "$DATA/ntfy/data"
  "$MEDIA/nextcloud/data"
  "$MEDIA/paperless/media" "$MEDIA/paperless/export" "$MEDIA/paperless/consume"
  "$MEDIA/immich/upload"
  "$MEDIA/forgejo/data"
  "$MEDIA/garage/data"
  "$MEDIA/pingvin/data"
)

for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

echo "✅ Directory create"
echo ""
echo "════════════════════════════════════════"
echo "Prossimi passi:"
echo "  1. nano .env         → configura password e path"
echo "  2. make check        → verifica configurazione"
echo "  3. make up           → avvia tutto"
echo "════════════════════════════════════════"
