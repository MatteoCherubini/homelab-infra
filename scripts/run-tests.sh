#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  run-tests.sh — checks that never touch the infrastructure   ║
# ╚══════════════════════════════════════════════════════════════╝
#
# This suite runs OFFLINE and without Docker: no network calls, no containers,
# no .env required. That is what lets it run on a freshly cloned laptop and in
# CI, and lets it run BEFORE touching the server rather than after.
#
# Verifying the running system is a different job and lives elsewhere:
#   make healthcheck   → queries the live services
#   make verify        → declared image tags vs running containers
#   make check-env     → drift between .env and .env.example
#
# Exits 0 when everything passes, 1 otherwise.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0; FAIL=0; SKIP=0
ok()    { printf "  \033[32m✔\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()   { printf "  \033[31m✘\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()  { printf "  \033[33m•\033[0m %s\n" "$1"; SKIP=$((SKIP+1)); }
title() { printf "\n\033[1m%s\033[0m\n" "$1"; }

SHELL_FILES=(scripts/*.sh host/*)
PY_FILES=(scripts/*.py)

# ── 1. Shell syntax ──────────────────────────────────────────────────────
title "Shell script syntax"
for f in "${SHELL_FILES[@]}"; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f — syntax error"; fi
done

# ── 2. shellcheck ────────────────────────────────────────────────────────
# At `warning` severity: the defects that change behaviour (a `cd` that can
# fail without stopping the script, an unquoted variable that splits on
# spaces). Style notes stay out, because a gate that reports everything stops
# being read.
title "shellcheck (severity: warning)"
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${SHELL_FILES[@]}"; do
    [ -f "$f" ] || continue
    if out=$(shellcheck -S warning "$f" 2>&1); then
      ok "$f"
    else
      bad "$f"; printf '%s\n' "$out" | sed 's/^/      /'
    fi
  done
else
  skip "shellcheck not installed (apt install shellcheck)"
fi

# ── 3. Python ────────────────────────────────────────────────────────────
title "Python syntax"
for f in "${PY_FILES[@]}"; do
  [ -f "$f" ] || continue
  if python3 -m py_compile "$f" 2>/dev/null; then ok "$f"; else bad "$f — syntax error"; fi
done
rm -rf scripts/__pycache__

# ── 4. JSON ──────────────────────────────────────────────────────────────
# services_metadata.json drives the update checker and the files under
# workflows/ are n8n exports: broken JSON here surfaces at the next import,
# which is exactly when it is needed.
title "JSON files parse"
for f in services_metadata.json workflows/*.json; do
  [ -f "$f" ] || continue
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    ok "$f"
  else
    bad "$f — invalid JSON"
  fi
done

# ── 5. Compose consistency ───────────────────────────────────────────────
# Without Docker the configuration cannot be resolved, but every file can
# still be checked for valid YAML, and every stack the root file includes can
# be checked to exist: a wrong include path breaks EVERY compose command, not
# just that stack.
title "Compose: valid YAML and resolvable includes"
# PyYAML is checked ONCE, up front. Checking it inside the loop and exiting 0
# when it is missing would print an OK for every file without anything having
# been verified: a test that passes without running is worse than no test,
# because it removes the reason to look elsewhere.
if python3 -c "import yaml" 2>/dev/null; then
  for f in docker-compose.yml stacks/*/compose.yml; do
    [ -f "$f" ] || continue
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null; then
      ok "$f"
    else
      bad "$f - invalid YAML"
    fi
  done
else
  skip "PyYAML not installed: YAML validation skipped (pip install pyyaml)"
fi

while read -r inc; do
  [ -z "$inc" ] && continue
  if [ -f "$inc" ]; then ok "include -> $inc"; else bad "include -> $inc (file missing)"; fi
done < <(grep -E '^\s*-\s+stacks/.*\.yml\s*$' docker-compose.yml | sed -E 's/^\s*-\s+//; s/\s*$//')

# ── 6. Documentation links ───────────────────────────────────────────────
# Relative links between documents are the first thing to rot when a file is
# renamed or moved, and nothing else notices until a reader follows one.
title "Documentation links resolve"
if out=$(python3 - <<'PY' 2>&1
import os, re, glob, sys
bad = 0
for f in sorted(glob.glob('*.md') + glob.glob('docs/**/*.md', recursive=True)):
    base = os.path.dirname(f)
    for text, target in re.findall(r'\[([^\]]+)\]\(([^)]+)\)',
                                   open(f, encoding='utf-8').read()):
        if target.startswith(('http://', 'https://', '#', 'mailto:')):
            continue
        path = os.path.normpath(os.path.join(base, target.split('#')[0]))
        if not os.path.exists(path):
            print(f"{f}: [{text}]({target}) -> {path} does not exist")
            bad += 1
sys.exit(1 if bad else 0)
PY
); then
  ok "every relative link in the Markdown files resolves"
else
  bad "broken links"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# ── 7. No committed secrets ──────────────────────────────────────────────
# The check that matters before making the repository public. It looks only at
# TRACKED files: ignored ones (.env and friends) can and should hold real
# credentials.
title "No secrets in tracked files"
leaks=0
while read -r f; do
  [ -f "$f" ] || continue
  case "$f" in *.example) continue ;; esac
  if grep -qE 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|eyJ[A-Za-z0-9_-]{30,}\.' "$f" 2>/dev/null; then
    bad "$f contains what looks like a key or a token"; leaks=1
  fi
done < <(git ls-files 2>/dev/null)
[ "$leaks" -eq 0 ] && ok "no private key or JWT in tracked files"

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  bad ".env IS TRACKED BY GIT"
else
  ok ".env is not tracked"
fi

# ── 8. Unit tests ────────────────────────────────────────────────────────
title "Unit tests"
if out=$(python3 -m unittest discover -s tests 2>&1); then
  n=$(printf '%s' "$out" | grep -oE 'Ran [0-9]+ test' | grep -oE '[0-9]+')
  ok "${n:-?} tests passed"
else
  bad "tests failed"
  printf '%s\n' "$out" | tail -30 | sed 's/^/      /'
fi

printf "\n\033[1mResult:\033[0m %d passed, %d failed, %d skipped\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
