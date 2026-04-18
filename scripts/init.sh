#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "══════════════════════════════════════════"
echo "  Homelab — Inizializzazione"
echo "══════════════════════════════════════════"

# ── .env ──────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    echo "✅ .env creato da .env.example"
    echo "⚠️  MODIFICA le password prima di avviare!"
else
    echo "ℹ️  .env già presente"
fi

source .env

DATA="${DATA_ROOT:-.\/data}"
MEDIA="${MEDIA_ROOT:-.\/media}"

echo ""
echo "📁 DATA_ROOT: $DATA"
echo "📁 MEDIA_ROOT: $MEDIA"

# ── Directory dati ────────────────────────────────────────────
dirs=(
    # Core
    "$DATA/nginx/data" "$DATA/nginx/letsencrypt"
    "$DATA/headscale/config" "$DATA/headscale/data"
    "$DATA/portainer"
    "$DATA/homepage/config"
    # Cloud
    "$DATA/nextcloud/db"
    # Photos
    "$DATA/immich/db" "$DATA/immich/ml-cache"
    # Docs
    "$DATA/paperless/db" "$DATA/paperless/data"
    # AI
    "$DATA/ollama/data"
    "$DATA/open-webui/data"
    # Automation
    "$DATA/n8n/db" "$DATA/n8n/data" "$DATA/n8n/redis"
    # Security
    "$DATA/vaultwarden/data"
    # Storage
    "$DATA/garage/meta" "$DATA/garage/config"
    "$DATA/kopia/config" "$DATA/kopia/cache"
    # Monitoring
    "$DATA/netdata/config" "$DATA/netdata/lib" "$DATA/netdata/cache"
    "$DATA/grafana/data"
    "$DATA/loki/data" "$DATA/loki/config"
    "$DATA/promtail/config"
    # Tools
    "$DATA/ntfy/data"
    # UPS (preparato ma non attivo)
    "$DATA/nut/etc"
    # Media directories
    "$MEDIA/nextcloud/data"
    "$MEDIA/paperless/media" "$MEDIA/paperless/export" "$MEDIA/paperless/consume"
    "$MEDIA/immich/upload"
    "$MEDIA/forgejo/data"
    "$MEDIA/garage/data"
)

for d in "${dirs[@]}"; do
    mkdir -p "$d"
done
echo "✅ Directory create"

# ── Config files ──────────────────────────────────────────────
echo ""
echo "📄 Copia config template..."

copy_if_missing() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        echo "  ✅ $(basename "$dst")"
    else
        echo "  ℹ️  $(basename "$dst") già presente"
    fi
}

copy_if_missing "$ROOT_DIR/configs/headscale/config.yaml" "$DATA/headscale/config/config.yaml"
copy_if_missing "$ROOT_DIR/configs/loki/loki.yml" "$DATA/loki/config/loki.yml"
copy_if_missing "$ROOT_DIR/configs/promtail/config.yml" "$DATA/promtail/config/config.yml"
copy_if_missing "$ROOT_DIR/configs/garage/garage.toml" "$DATA/garage/config/garage.toml"

# ── Permessi ──────────────────────────────────────────────────
echo ""
echo "🔑 Fix permessi..."

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# n8n gira come UID del .env (default 1000)
chown -R "$PUID:$PGID" "$DATA/n8n/data" 2>/dev/null || true

# Loki gira come UID 10001 nel container
sudo chown -R 10001:10001 "$DATA/loki/data" 2>/dev/null || \
    chown -R 10001:10001 "$DATA/loki/data" 2>/dev/null || \
    echo "  ⚠️  Loki: esegui manualmente: sudo chown -R 10001:10001 $DATA/loki/data"

# Grafana gira come PUID
chown -R "$PUID:$PGID" "$DATA/grafana/data" 2>/dev/null || true

echo "✅ Permessi applicati"

# ── Kernel tuning (Redis) ─────────────────────────────────────
echo ""
echo "🔧 Kernel tuning..."

if [ "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)" != "1" ]; then
    echo "  ⚠️  Redis warning fix: esegui come root:"
    echo "     echo 'vm.overcommit_memory=1' | sudo tee -a /etc/sysctl.conf"
    echo "     sudo sysctl -p"
else
    echo "  ✅ vm.overcommit_memory già configurato"
fi

# ── Riepilogo ─────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  Inizializzazione completata!"
echo "══════════════════════════════════════════"
echo ""
echo "Prossimi passi:"
echo "  1. nano .env              → configura password e path"
echo "  2. make check             → verifica config"
echo "  3. make up                → avvia tutto"
echo ""
echo "  Se è il primo avvio, controlla anche:"
echo "  - Headscale: modifica server_url in"
echo "    $DATA/headscale/config/config.yaml"
echo "  - Garage: dopo l'avvio, inizializza il nodo"
echo "    (vedi commenti in configs/garage/garage.toml)"
echo "══════════════════════════════════════════"
