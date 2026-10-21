#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "══════════════════════════════════════════"
echo "  Homelab — Initialisation"
echo "══════════════════════════════════════════"

# ── .env ──────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    # Every secret lives here: readable by its owner and the docker group —
    # n8n-runner reads it through that group for the nightly jobs — and by no
    # one else on the host.
    chmod 640 .env && chgrp docker .env 2>/dev/null \
        || echo "⚠️  set .env to group docker and mode 640 by hand (docs/backup.md)"
    echo "✅ .env created from .env.example"
    echo "⚠️  Set every password before starting!"
else
    echo "ℹ️  .env already present"
fi

# The .env is NOT sourced — same reader as backup.sh and healthcheck.sh: it
# is a data file, and a value with spaces or a `$(...)` would run as a command.
env_get() {
    local key=$1 def=${2:-} val
    val=$(sed -n "s/^[[:space:]]*${key}=//p" .env | tail -1 | tr -d '"'\''\r' | xargs 2>/dev/null)
    printf '%s' "${val:-$def}"
}

DATA=$(env_get DATA_ROOT ./data)
MEDIA=$(env_get MEDIA_ROOT ./media)
GENOME_MEDIA=$(env_get GENOME_MEDIA_ROOT "$MEDIA/genomes")
PERSONAL=$(env_get PHOTO_PERSONAL_ROOT "$MEDIA/personal")

echo ""
echo "📁 DATA_ROOT: $DATA"
echo "📁 MEDIA_ROOT: $MEDIA"

# ── Data directories (enabled services only) ──────────────────
dirs=(
    # Core
    "$DATA/nginx/data" "$DATA/nginx/letsencrypt"
    "$DATA/homepage/config"
    # AI
    "$DATA/ollama/data"
    # Automation
    "$DATA/n8n/db" "$DATA/n8n/data" "$DATA/n8n/redis"
    # Photos: the database and the thumbnails on the SSD
    "$DATA/immich/postgres" "$DATA/immich/thumbs"
    # Documents: the database, the search index and the classifier on the SSD
    "$DATA/paperless/postgres" "$DATA/paperless/data"
    # Business: Grist's users and documents, SQLite files on the SSD
    "$DATA/grist"
    # Media (RAID)
    "$MEDIA/forgejo/data"
    "$MEDIA/immich" "$GENOME_MEDIA" "$PERSONAL"
    "$MEDIA/paperless/media" "$MEDIA/paperless/consume" "$MEDIA/archive/paperless"
)

for d in "${dirs[@]}"; do
    mkdir -p "$d"
done
echo "✅ Directories created"

# ── Permissions ───────────────────────────────────────────────
echo ""
echo "🔑 Fixing permissions..."

PUID=$(env_get PUID 1000)
PGID=$(env_get PGID 1000)

# n8n and Grist run as the UID from .env (default 1000)
chown -R "$PUID:$PGID" "$DATA/n8n/data" "$DATA/grist" 2>/dev/null || true

echo "✅ Permissions applied"

# ── Kernel tuning (Redis n8n) ─────────────────────────────────
echo ""
echo "🔧 Kernel tuning..."

if [ "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)" != "1" ]; then
    echo "  ⚠️  Redis warning fix — run as root:"
    echo "     echo 'vm.overcommit_memory=1' | sudo tee -a /etc/sysctl.conf"
    echo "     sudo sysctl -p"
else
    echo "  ✅ vm.overcommit_memory already set"
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  Initialisation complete"
echo "══════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. \$EDITOR .env          → set passwords and paths"
echo "  2. make check             → validate the configuration"
echo "  3. make up                → start everything"
echo "══════════════════════════════════════════"
