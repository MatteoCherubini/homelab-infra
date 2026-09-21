#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  run-tests.sh — controlli che non toccano l'infrastruttura   ║
# ╚══════════════════════════════════════════════════════════════╝
#
# Questa suite gira OFFLINE e senza Docker: nessuna chiamata di rete, nessun
# container, nessun .env necessario. Serve a poterla eseguire su un laptop
# appena clonato il repository e in CI, e a poterla eseguire PRIMA di toccare
# il server invece che dopo.
#
# La verifica del sistema in esecuzione è un'altra cosa e sta altrove:
#   make healthcheck   → interroga i servizi vivi
#   make verify        → confronta tag dichiarati e immagini attive
#   make check-env     → deriva fra .env e .env.example
#
# Exit 0 se tutto passa, 1 altrimenti.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0; FAIL=0; SKIP=0
ok()    { printf "  \033[32m✔\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()   { printf "  \033[31m✘\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()  { printf "  \033[33m•\033[0m %s\n" "$1"; SKIP=$((SKIP+1)); }
title() { printf "\n\033[1m%s\033[0m\n" "$1"; }

SHELL_FILES=(scripts/*.sh UPS/kg-ups-handler)
PY_FILES=(scripts/*.py)

# ── 1. Sintassi shell ────────────────────────────────────────────────────
title "Sintassi degli script shell"
for f in "${SHELL_FILES[@]}"; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f — errore di sintassi"; fi
done

# ── 2. shellcheck ────────────────────────────────────────────────────────
# A severità `warning`: sono i difetti che cambiano il comportamento (un `cd`
# che può fallire senza fermare lo script, una variabile non quotata che si
# spezza sugli spazi). Le note di stile restano fuori, perché un gate che
# segnala di tutto smette di essere letto.
title "shellcheck (severità: warning)"
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
  skip "shellcheck non installato (apt install shellcheck)"
fi

# ── 3. Python ────────────────────────────────────────────────────────────
title "Sintassi Python"
for f in "${PY_FILES[@]}"; do
  [ -f "$f" ] || continue
  if python3 -m py_compile "$f" 2>/dev/null; then ok "$f"; else bad "$f — errore di sintassi"; fi
done
rm -rf scripts/__pycache__

# ── 4. JSON ──────────────────────────────────────────────────────────────
# services_metadata.json guida il checker degli aggiornamenti e i file in
# workflows/ sono export di n8n: un JSON rotto qui si scopre al prossimo
# import, cioè quando serve.
title "Validità dei file JSON"
for f in services_metadata.json workflows/*.json; do
  [ -f "$f" ] || continue
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    ok "$f"
  else
    bad "$f — JSON non valido"
  fi
done

# ── 5. Coerenza dei compose file ─────────────────────────────────────────
# Senza Docker non si può risolvere la configurazione, ma si può comunque
# verificare che ogni file sia YAML valido e che ogni stack incluso dal file
# di root esista davvero: un include verso un percorso sbagliato rompe OGNI
# comando compose, non solo quello stack.
title "Compose: YAML valido e include risolvibili"
# PyYAML si verifica UNA volta sola e in anticipo. Controllarlo dentro al
# ciclo, uscendo 0 quando manca, stamperebbe un OK per ogni file senza che
# nulla sia stato verificato: un test che passa senza girare e' peggio di un
# test assente, perche' toglie la voglia di cercare altrove.
if python3 -c "import yaml" 2>/dev/null; then
  for f in docker-compose.yml stacks/*/compose.yml; do
    [ -f "$f" ] || continue
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null; then
      ok "$f"
    else
      bad "$f - YAML non valido"
    fi
  done
else
  skip "PyYAML non installato: validazione YAML saltata (pip install pyyaml)"
fi

missing=0
while read -r inc; do
  [ -z "$inc" ] && continue
  if [ -f "$inc" ]; then ok "include -> $inc"; else bad "include -> $inc (file assente)"; missing=1; fi
done < <(grep -E '^\s*-\s+stacks/.*\.yml\s*$' docker-compose.yml | sed -E 's/^\s*-\s+//; s/\s*$//')
[ "$missing" -eq 0 ] || true

# ── 6. Nessun segreto committato ─────────────────────────────────────────
# Il controllo che conta prima di rendere pubblico il repository. Guarda solo
# i file TRACCIATI: quelli ignorati (.env e simili) possono e devono contenere
# segreti veri.
title "Nessun segreto nei file tracciati"
leaks=0
while read -r f; do
  [ -f "$f" ] || continue
  case "$f" in *.example) continue ;; esac
  if grep -qE 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|eyJ[A-Za-z0-9_-]{30,}\.' "$f" 2>/dev/null; then
    bad "$f contiene quella che sembra una chiave o un token"; leaks=1
  fi
done < <(git ls-files 2>/dev/null)
[ "$leaks" -eq 0 ] && ok "nessuna chiave privata o JWT nei file tracciati"

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  bad ".env RISULTA TRACCIATO DA GIT"
else
  ok ".env non è tracciato"
fi

# ── 7. Test unitari ──────────────────────────────────────────────────────
title "Test unitari"
if out=$(python3 -m unittest discover -s tests 2>&1); then
  n=$(printf '%s' "$out" | grep -oE 'Ran [0-9]+ test' | grep -oE '[0-9]+')
  ok "${n:-?} test superati"
else
  bad "test falliti"
  printf '%s\n' "$out" | tail -30 | sed 's/^/      /'
fi

printf "\n\033[1mRisultato:\033[0m %d superati, %d falliti, %d saltati\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
