#!/usr/bin/env bash

set -euo pipefail

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

if [[ ! -f "$EXAMPLE_FILE" ]]; then
    echo "❌ File $EXAMPLE_FILE non trovato"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ File $ENV_FILE non trovato"
    exit 1
fi

extract_vars() {
    grep -v '^\s*#' "$1" \
    | grep '=' \
    | sed 's/=.*//' \
    | sed 's/^\s*//' \
    | sed 's/\s*$//' \
    | sort -u
}

example_vars=$(extract_vars "$EXAMPLE_FILE")
env_vars=$(extract_vars "$ENV_FILE")

missing=0

echo "🔍 Controllo variabili mancanti..."

while read -r var; do
    if ! grep -qx "$var" <<< "$env_vars"; then
        echo "❌ Variabile mancante in .env: $var"
        missing=1
    fi
done <<< "$example_vars"

echo ""
echo "🔍 Controllo variabili extra..."

while read -r var; do
    if ! grep -qx "$var" <<< "$example_vars"; then
        echo "⚠️  Variabile extra presente in .env: $var"
    fi
done <<< "$env_vars"

echo ""

if [[ "$missing" -eq 1 ]]; then
    echo "❌ .env NON allineato a .env.example"
    exit 1
fi

echo "✅ .env allineato a .env.example"
