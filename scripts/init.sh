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

DATA="${DATA_ROOT:-./data}"
MEDIA="${MEDIA_ROOT:-./media}"

echo ""
echo "📁 DATA_ROOT: $DATA"
echo "📁 MEDIA_ROOT: $MEDIA"

# ── Directory dati (solo servizi attivi) ──────────────────────
dirs=(
    # Core
    "$DATA/nginx/data" "$DATA/nginx/letsencrypt"
    "$DATA/homepage/config"
    # AI
    "$DATA/ollama/data"
    # Automation
    "$DATA/n8n/db" "$DATA/n8n/data" "$DATA/n8n/redis"
    # UPS (preparato ma non attivo — futuro, via n8n)
    "$DATA/nut/etc"
    # Media (RAID)
    "$MEDIA/forgejo/data"
)

for d in "${dirs[@]}"; do
    mkdir -p "$d"
done
echo "✅ Directory create"

# ── Permessi ──────────────────────────────────────────────────
echo ""
echo "🔑 Fix permessi..."

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# n8n gira come UID del .env (default 1000)
chown -R "$PUID:$PGID" "$DATA/n8n/data" 2>/dev/null || true

echo "✅ Permessi applicati"

# ── Kernel tuning (Redis n8n) ─────────────────────────────────
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
echo "══════════════════════════════════════════"
