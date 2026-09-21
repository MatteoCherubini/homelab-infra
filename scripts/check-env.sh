#!/usr/bin/env bash

set -euo pipefail

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

if [[ ! -f "$EXAMPLE_FILE" ]]; then
    echo "❌ $EXAMPLE_FILE not found"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ $ENV_FILE not found"
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

echo "🔍 Checking for missing variables..."

while read -r var; do
    if ! grep -qx "$var" <<< "$env_vars"; then
        echo "❌ Missing in .env: $var"
        missing=1
    fi
done <<< "$example_vars"

echo ""
echo "🔍 Checking for extra variables..."

while read -r var; do
    if ! grep -qx "$var" <<< "$example_vars"; then
        echo "⚠️  Present in .env but not in the template: $var"
    fi
done <<< "$env_vars"

echo ""

if [[ "$missing" -eq 1 ]]; then
    echo "❌ .env is NOT aligned with .env.example"
    exit 1
fi

echo "✅ .env is aligned with .env.example"
