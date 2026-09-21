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
    echo "✅ .env created from .env.example"
    echo "⚠️  Set every password before starting!"
else
    echo "ℹ️  .env already present"
fi

source .env

DATA="${DATA_ROOT:-./data}"
MEDIA="${MEDIA_ROOT:-./media}"

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
    # Media (RAID)
    "$MEDIA/forgejo/data"
)

for d in "${dirs[@]}"; do
    mkdir -p "$d"
done
echo "✅ Directories created"

# ── Permissions ───────────────────────────────────────────────
echo ""
echo "🔑 Fixing permissions..."

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# n8n runs as the UID from .env (default 1000)
chown -R "$PUID:$PGID" "$DATA/n8n/data" 2>/dev/null || true

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
